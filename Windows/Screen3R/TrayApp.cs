//
//  TrayApp.cs
//  Screen3R for Windows
//
//  Notification-area icon and menu (the Windows counterpart of the Mac host's menu bar item):
//  finds viewers on the local network, connects, pairs, and streams the chosen display.
//

using System.Diagnostics;
using Screen3R.Capture;

namespace Screen3R;

sealed class TrayApp : ApplicationContext
{
    public static Icon AppIcon { get; } = LoadIcon();

    static Icon LoadIcon()
    {
        using var stream = typeof(TrayApp).Assembly.GetManifestResourceStream("Screen3R.ico");
        return stream != null ? new Icon(stream) : SystemIcons.Application;
    }

    enum Phase { Idle, Connecting, Streaming }

    readonly SynchronizationContext _ui;
    readonly NotifyIcon _tray;
    readonly ContextMenuStrip _menu = new();
    readonly Settings _settings = Settings.Load();
    readonly PairingStore _pairings = new();
    readonly Discovery _discovery = new();
    readonly Form _owner;            // invisible, top-most: owner of message boxes

    Phase _phase = Phase.Idle;
    string _peerName = "";
    PeerConnection? _peer;
    ViewerHello? _hello;
    int _streamWidth, _streamHeight;
    Streamer? _streamer;
    CursorTracker? _cursor;
    InputInjector? _injector;
    PairingDialog? _pairingDialog;
    string? _statsText, _decoderText, _lastError;
    bool _cryPending;

    public TrayApp()
    {
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _owner = new Form { ShowInTaskbar = false, TopMost = true, FormBorderStyle = FormBorderStyle.None, Size = new Size(1, 1),
                            StartPosition = FormStartPosition.CenterScreen, Opacity = 0 };
        _tray = new NotifyIcon { Icon = AppIcon, Text = "Screen3R", ContextMenuStrip = _menu, Visible = true };
        _menu.Opening += (_, e) => { BuildMenu(); e.Cancel = false; };
        _tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
                typeof(NotifyIcon).GetMethod("ShowContextMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                                  ?.Invoke(_tray, null);
        };
        _discovery.Start();
        Log.Write($"Screen3R {Application.ProductVersion} started");
        if (!File.Exists(Path.Combine(Log.Folder, "welcomed")))
        {
            _tray.ShowBalloonTip(8000, "Screen3R is running",
                "Click the Screen3R icon in the notification area to send this screen to an old Mac.", ToolTipIcon.Info);
            try { Directory.CreateDirectory(Log.Folder); File.WriteAllText(Path.Combine(Log.Folder, "welcomed"), ""); }
            catch (IOException) { }
        }
    }

    void OnUi(Action action) => _ui.Post(_ => action(), null);

    // MARK: - Menu

    void BuildMenu()
    {
        _menu.Items.Clear();
        switch (_phase)
        {
            case Phase.Idle: Disabled("Not connected"); break;
            case Phase.Connecting: Disabled($"Connecting to {_peerName}…"); break;
            case Phase.Streaming:
                Disabled($"Streaming to {_peerName} — {_streamWidth}×{_streamHeight}");
                if (_statsText != null) Disabled(_statsText);
                if (_decoderText != null) Disabled(_decoderText);
                if (InputStatusText() is string input) Disabled(input);
                break;
        }
        if (_lastError != null && _phase == Phase.Idle) Disabled("⚠ " + Shorten(_lastError), _lastError);
        _menu.Items.Add(new ToolStripSeparator());

        if (_phase == Phase.Idle)
        {
            var viewers = _discovery.Viewers;
            Disabled(viewers.Count == 0 ? "Searching for screens…" : "Available screens:");
            foreach (var v in viewers)
                Item("    " + v.Name.Replace("&", "&&"), () => Connect(v.Address.ToString(), v.Port, v.Name));
            Item("Connect to IP Address…", ConnectManually);
        }
        else
        {
            Item("Disconnect", () => Disconnect(null));
        }
        _menu.Items.Add(new ToolStripSeparator());

        var displayMenu = new ToolStripMenuItem("Display to Send");
        List<DisplayInfo> displays;
        try { displays = Displays.All(); }
        catch (Exception e) { displays = []; Log.Write($"Listing displays failed: {e.Message}"); }
        string current = CurrentDisplay(displays)?.DeviceName ?? "";
        foreach (var d in displays)
        {
            var item = new ToolStripMenuItem(d.Title.Replace("&", "&&")) { Checked = d.DeviceName == current };
            item.Click += (_, _) => ChooseDisplay(d);
            displayMenu.DropDownItems.Add(item);
        }
        if (displays.Count == 0) displayMenu.DropDownItems.Add(new ToolStripMenuItem("No display found") { Enabled = false });
        displayMenu.DropDownItems.Add(new ToolStripSeparator());
        displayMenu.DropDownItems.Add(new ToolStripMenuItem("To extend the desktop, add a virtual display (see README)") { Enabled = false });
        _menu.Items.Add(displayMenu);

        var inputItem = Item("Use Old Mac's Keyboard && Mouse", ToggleInput);
        inputItem.Checked = _settings.AllowInput;
        inputItem.ToolTipText = "The keyboard and mouse of the old Mac control this PC. Needs Encrypt Stream.";
        var keys = new ToolStripMenuItem("Mac Keyboard");
        var bootCamp = new ToolStripMenuItem("⌘ Command = Windows Key, ⌃ Control = Ctrl") { Checked = !_settings.CommandAsControl };
        bootCamp.Click += (_, _) => SetCommandAsControl(false);
        var macStyle = new ToolStripMenuItem("⌘ Command = Ctrl, ⌃ Control = Windows Key") { Checked = _settings.CommandAsControl };
        macStyle.Click += (_, _) => SetCommandAsControl(true);
        keys.DropDownItems.Add(bootCamp);
        keys.DropDownItems.Add(macStyle);
        keys.DropDownItems.Add(new ToolStripSeparator());
        keys.DropDownItems.Add(new ToolStripMenuItem("Right ⌥ Option = AltGr") { Enabled = false });
        _menu.Items.Add(keys);

        var quality = new ToolStripMenuItem("Quality");
        foreach (Quality q in Enum.GetValues<Quality>())
        {
            var item = new ToolStripMenuItem(q.Title()) { Checked = q == _settings.Quality };
            item.Click += (_, _) =>
            {
                _settings.Quality = q;
                _settings.Save();
                _streamer?.SetQuality(q);
            };
            quality.DropDownItems.Add(item);
        }
        _menu.Items.Add(quality);

        var security = new ToolStripMenuItem("Security");
        var encrypt = new ToolStripMenuItem("Encrypt Stream") { Checked = _settings.Encrypt, ToolTipText = "Applies from the next connection." };
        encrypt.Click += (_, _) => { _settings.Encrypt = !_settings.Encrypt; _settings.Save(); };
        security.DropDownItems.Add(encrypt);
        var forget = new ToolStripMenuItem("Forget Paired Screens…");
        forget.Click += (_, _) => ForgetPairings();
        security.DropDownItems.Add(forget);
        _menu.Items.Add(security);

        Item("Open Log", () =>
        {
            try { Process.Start(new ProcessStartInfo(Log.FilePath) { UseShellExecute = true }); }
            catch (Exception e) { Log.Write(e.Message); }
        });
        _menu.Items.Add(new ToolStripSeparator());
        Item("Quit Screen3R", Quit);
    }

    static string Shorten(string s) => s.Length > 80 ? s[..77] + "…" : s;

    void Disabled(string text, string? tooltip = null) =>
        _menu.Items.Add(new ToolStripMenuItem(text.Replace("&", "&&")) { Enabled = false, ToolTipText = tooltip });

    ToolStripMenuItem Item(string text, Action action)
    {
        var item = new ToolStripMenuItem(text);
        item.Click += (_, _) => action();
        _menu.Items.Add(item);
        return item;
    }

    DisplayInfo? CurrentDisplay(List<DisplayInfo> displays) =>
        displays.FirstOrDefault(d => d.DeviceName == _settings.Display) ?? displays.FirstOrDefault();

    void ChooseDisplay(DisplayInfo display)
    {
        _settings.Display = display.DeviceName;
        _settings.Save();
        if (_phase == Phase.Streaming && _hello != null && _peer != null) RestartStreaming();
    }

    void SetCommandAsControl(bool value)
    {
        _settings.CommandAsControl = value;
        _settings.Save();
        if (_phase == Phase.Streaming) RestartStreaming();   // the injector takes the setting at creation
    }

    void ToggleInput()
    {
        _settings.AllowInput = !_settings.AllowInput;
        _settings.Save();
        UpdateInput();
    }

    void UpdateInput()
    {
        if (_phase != Phase.Streaming || _peer == null || _hello == null) return;
        _peer.SetInputEnabled(_settings.AllowInput && _peer.Encrypt && _hello.Has("input"));
    }

    string? InputStatusText()
    {
        if (!_settings.AllowInput || _phase != Phase.Streaming || _peer == null || _hello == null) return null;
        if (!_hello.Has("input")) return "Keyboard & mouse: update Screen3R Viewer on the old Mac";
        if (!_peer.Encrypt) return "Keyboard & mouse: turn on Security › Encrypt Stream, then reconnect";
        return "Keyboard & mouse: the old Mac's are in use";
    }

    void ForgetPairings()
    {
        if (MessageBox.Show(_owner, "Next time you connect, you will have to pair again by comparing the code shown on both screens.",
                            "Forget all paired screens?", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK)
            _pairings.RemoveAll();
    }

    void ConnectManually()
    {
        using var form = new Form
        {
            Text = "Connect to a viewer", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
            StartPosition = FormStartPosition.CenterScreen, TopMost = true, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(12), Icon = AppIcon, AutoScaleMode = AutoScaleMode.Dpi,
        };
        var layout = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Dock = DockStyle.Fill };
        layout.Controls.Add(new Label { Text = "Enter the IP address shown on the iMac screen.", AutoSize = true });
        var field = new TextBox { Text = _settings.LastManualAddress, PlaceholderText = "192.168.1.20", Width = 260 };
        layout.Controls.Add(field);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        var ok = new Button { Text = "Connect", DialogResult = DialogResult.OK, AutoSize = true };
        buttons.Controls.Add(cancel);
        buttons.Controls.Add(ok);
        layout.Controls.Add(buttons);
        form.Controls.Add(layout);
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        if (form.ShowDialog() != DialogResult.OK) return;

        string text = field.Text.Trim();
        if (text.Length == 0) return;
        _settings.LastManualAddress = text;
        _settings.Save();
        string host = text;
        int port = RD.Port;
        // Accept "host:port" (IPv4 or name).
        int colon = text.LastIndexOf(':');
        if (colon > 0 && text.Count(c => c == ':') == 1 && int.TryParse(text[(colon + 1)..], out int p) && p is > 0 and < 65536)
        {
            host = text[..colon];
            port = p;
        }
        Connect(host, port, host);
    }

    // MARK: - Session

    void Connect(string host, int port, string name)
    {
        Teardown();
        _lastError = null;

        var peer = new PeerConnection(host, port, name, _settings.Encrypt, _settings.HostId, LocalName(), _pairings);
        peer.OnReady = hello => OnUi(() => { if (_peer == peer) StartStreaming(hello); });
        // Now and then the old iMac lets you know how it feels about it (the iMac chooses how
        // often). Shown before authentication starts: the session goes on after OK.
        peer.OnHelloGate = (hello, resume) => OnUi(() =>
        {
            if (_peer != peer) return;
            int countdown = _settings.CueCountdown;
            bool cry = EasterEgg.ShouldFire(hello.Cry, ref countdown, Random.Shared);
            if (countdown != _settings.CueCountdown)
            {
                _settings.CueCountdown = countdown;
                _settings.Save();
            }
            if (cry)
            {
                _owner.Show();
                MessageBox.Show(_owner, EasterEgg.Text, "Screen3R", MessageBoxButtons.OK, MessageBoxIcon.Information);
                _owner.Hide();
                if (_peer != peer) return;   // disconnected meanwhile
                _cryPending = true;
            }
            resume();
        });
        peer.OnClosed = reason => OnUi(() => { if (_peer == peer) Disconnect(reason); });
        peer.OnStats = stats => OnUi(() =>
        {
            if (_peer != peer) return;
            _statsText = $"{stats.Fps} fps · {stats.Mbps:0.0} Mbit/s · {stats.RttMs:0} ms" + (stats.Encrypted ? " · encrypted" : " · not encrypted");
            if (stats.Viewer is { } v)
                _decoderText = $"Viewer decoder: {(v.Hw == true ? "hardware" : v.Hw == false ? "software" : "?")} · {v.DecodeMs ?? 0:0.0} ms/frame";
            _tray.Text = Shorten($"Screen3R — {_peerName}");
        });
        peer.OnPairingCode = (code, viewerName, decide) => OnUi(() =>
        {
            if (_peer != peer) { decide(false); return; }
            _pairingDialog?.Abandon();
            _pairingDialog = new PairingDialog(viewerName, code, decide);
            _pairingDialog.FormClosed += (_, _) => _pairingDialog = null;
            _pairingDialog.Show();
        });
        _peer = peer;
        _peerName = name;
        _phase = Phase.Connecting;
        Log.Write($"Connecting to {name} ({host}:{port}), encrypt = {_settings.Encrypt}");
        peer.Start();
    }

    static string LocalName()
    {
        string name = Environment.MachineName;
        return name.Length > 0 ? name : "Windows PC";
    }

    void StartStreaming(ViewerHello hello)
    {
        if (_peer == null) return;
        _hello = hello;
        _pairingDialog?.Abandon();
        if (!hello.Has("cursor"))
        {
            Disconnect("Update Screen3R Viewer on the old Mac (it must draw the mouse pointer itself).");
            return;
        }
        // Even sizes, within what the viewer and H.264 level 5.2 handle (as on the Mac).
        _streamWidth = Math.Clamp(hello.Width & ~1, 640, 4096);
        _streamHeight = Math.Clamp(hello.Height & ~1, 480, 2304);
        _peerName = Wire.SanitizedName(hello.Name);
        _phase = Phase.Streaming;
        Native.SetThreadExecutionState(Native.ES_CONTINUOUS | Native.ES_SYSTEM_REQUIRED | Native.ES_DISPLAY_REQUIRED);
        if (!StartPipeline()) return;
        if (_cryPending)
        {
            _cryPending = false;
            _peer.SendCue(EasterEgg.CryCue);
        }
    }

    bool StartPipeline()
    {
        PeerConnection peer = _peer!;
        ViewerHello hello = _hello!;
        List<DisplayInfo> displays;
        try { displays = Displays.All(); }
        catch (Exception e) { Disconnect($"No display to capture: {e.Message}"); return false; }
        DisplayInfo? display = CurrentDisplay(displays);
        if (display == null) { Disconnect("No display to capture."); return false; }

        Streamer streamer;
        try
        {
            streamer = new Streamer(display, _streamWidth, _streamHeight, _settings.Quality);
        }
        catch (Exception e)
        {
            Log.Write($"Could not start capture: {e}");
            Disconnect($"Could not start screen capture: {e.Message}");
            return false;
        }
        streamer.CanSend = peer.CanSendFrame;
        streamer.OnFormat = (sets, nal) => peer.SendFormat(sets, nal);
        streamer.OnFrame = (data, key) => peer.SendFrame(data, key);
        streamer.OnError = message => OnUi(() => { if (_streamer == streamer) Disconnect(message); });
        peer.OnKeyframeRequest = streamer.RequestKeyframe;
        _streamer = streamer;

        var cursor = new CursorTracker(streamer.Mapping);
        cursor.OnPosition = (x, y, visible, seq) => peer.SendCursorPosition(x, y, visible, seq);
        cursor.OnImage = (w, h, hx, hy, pw, ph, pixels) => peer.SendCursorImage(w, h, hx, hy, pw, ph, pixels);
        _cursor = cursor;

        var injector = new InputInjector(streamer.Mapping, KeyMap.ParseLayout(hello.KeyboardLayout), _settings.CommandAsControl);
        injector.OnMoved = cursor.Injected;
        peer.OnInput = injector.Handle;
        _injector = injector;

        streamer.Start();
        cursor.Start();
        UpdateInput();
        return true;
    }

    /// Display or keyboard setting changed during a session: rebuild capture and input.
    void RestartStreaming()
    {
        StopPipeline();
        StartPipeline();
    }

    void StopPipeline()
    {
        if (_peer != null)
        {
            _peer.OnInput = null;
            _peer.OnKeyframeRequest = null;
        }
        _injector?.ReleaseAll();   // before anything else: no key may stay pressed
        _injector = null;
        _cursor?.Dispose();
        _cursor = null;
        _streamer?.Dispose();
        _streamer = null;
    }

    void Disconnect(string? reason)
    {
        Teardown();
        if (reason != null)
        {
            _lastError = reason;
            Log.Write(reason);
            _tray.ShowBalloonTip(5000, "Screen3R", reason, ToolTipIcon.Warning);
        }
    }

    void Teardown()
    {
        _pairingDialog?.Abandon();
        _pairingDialog = null;
        StopPipeline();
        if (_peer != null)
        {
            _peer.OnClosed = null;
            _peer.OnReady = null;
            _peer.OnStats = null;
            _peer.Cancel();
        }
        _peer = null;
        _hello = null;
        _statsText = _decoderText = null;
        _phase = Phase.Idle;
        _cryPending = false;
        _tray.Text = "Screen3R";
        Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
    }

    void Quit()
    {
        Teardown();
        _discovery.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        _owner.Dispose();
        ExitThread();
    }
}
