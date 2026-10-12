//
//  PeerConnection.cs
//  Screen3R for Windows
//
//  TCP connection to one viewer: framing, keep-alive, acknowledgements, stats and the
//  security handshake of protocol 2 — the same state machine as Host/Sources/PeerConnection.swift:
//
//    host                                   viewer
//    HELLO {id, nonce, encrypt} ───────▶  ◀─────── HELLO {id, nonce, name, size…}
//    known viewer:   AUTH(proof) ──────▶  ◀─────── AUTH(proof)       → session
//                                          ◀─────── NEED_PAIRING     → pairing ↓
//    pairing:  PAIR_COMMIT(H(pk)) ─────▶  ◀─────── PAIR_KEY(pkV)
//              PAIR_KEY(pkH) ──────────▶            both show the same 6-digit code
//    user confirms: PAIR_CONFIRM ──────▶  ◀─────── PAIR_CONFIRM      → session
//
//  Once the session starts (and if encryption is on), every message in both directions
//  travels inside SECURE envelopes.
//
//  Platform-neutral on purpose (only System.Net.Sockets): the interop test runs this exact
//  class on Linux against the Mac apps' C crypto.
//

using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;

namespace Screen3R;

/// Pairing keys, one per viewer.
public interface IPairingKeys
{
    byte[]? Get(string viewerId);
    void Store(string viewerId, byte[] key, string name);
}

public sealed class PeerConnection
{
    public sealed record Stats(int Fps, double Mbps, double RttMs, ViewerStats? Viewer, bool Encrypted);

    public string DisplayName { get; }
    /// This session is (or will be, once authenticated) encrypted.
    public bool Encrypt { get; }

    // Callbacks run on background threads (the receiving thread or the timer); the UI marshals.
    /// The viewer is authenticated (known pairing, or a new pairing confirmed).
    public Action<ViewerHello>? OnReady;
    /// The connection ended; null reason = closed on purpose. Called once.
    public Action<string?>? OnClosed;
    public Action<Stats>? OnStats;
    /// Optional: called with the viewer's HELLO before authentication starts. The handshake
    /// waits until `resume` is called (any thread; keep-alive pings go on meanwhile).
    public Action<ViewerHello, Action>? OnHelloGate;
    /// New pairing: show `code`, call `decide(true)` if the viewer shows the same code.
    public Action<string, string, Action<bool>>? OnPairingCode;
    public Action? OnKeyframeRequest;
    /// Keyboard/mouse events from the old Mac, in order, only while input is enabled.
    /// `Reset` is also delivered when input is switched off or the connection closes.
    public Action<InputEvent>? OnInput;

    /// Frames sent but not yet acknowledged before we start skipping captured frames.
    public uint MaxInFlight { get; set; } = 2;

    enum State { AwaitHello, HelloGate, AwaitAuth, PairAwaitKey, PairAwaitUser, PairAwaitConfirm, Ready }

    readonly string _host;
    readonly int _port;
    readonly string _hostId;
    readonly string _localName;
    readonly IPairingKeys _keys;

    readonly object _gate = new();        // state, handshake, closing
    readonly object _sendLock = new();    // sealing and writing happen in the same order
    readonly object _statLock = new();

    Socket? _socket;
    System.Threading.Timer? _timer;
    volatile bool _closed;
    long _lastReceive;                    // Stopwatch ticks (Interlocked)

    // guarded by _gate
    State _state = State.AwaitHello;
    ViewerHello? _hello;
    string _viewerId = "";
    byte[] _nonceHost = [];
    byte[] _nonceViewer = [];
    EcdhKeyPair? _ecdh;
    byte[] _pairTranscript = [];
    byte[] _pairKey = [];
    byte[]? _authKey;
    long _handshakeStarted;               // Stopwatch ticks; 0 once the session runs
    bool _inputEnabled;
    bool _inputControlSent;

    SecureChannel? _sendChannel;          // guarded by _sendLock
    SecureChannel? _recvChannel;          // receiving thread (set under _gate before the session starts)

    // guarded by _statLock
    uint _sentSeq, _ackedSeq;
    long _statBytes;
    int _statFrames;
    double _rttMs;
    ViewerStats? _viewerStats;
    bool _cueSent;

    public PeerConnection(string host, int port, string displayName, bool encrypt, string hostId, string localName,
                          IPairingKeys keys)
    {
        _host = host;
        _port = port;
        DisplayName = displayName;
        Encrypt = encrypt;
        _hostId = hostId;
        _localName = localName;
        _keys = keys;
    }

    public void Start()
    {
        var thread = new Thread(Run) { IsBackground = true, Name = "Screen3R connection" };
        thread.Start();
    }

    /// User-initiated disconnect. OnClosed is still called (with null).
    public void Cancel() => Close(null);

    // MARK: - Sending (any thread)

    public bool CanSendFrame()
    {
        lock (_statLock) return _sentSeq - _ackedSeq < MaxInFlight;
    }

    public void SendFormat(IReadOnlyList<byte[]> parameterSets, int nalLength)
    {
        int size = 2;
        foreach (var s in parameterSets) size += 2 + s.Length;
        byte[] p = new byte[size];
        p[0] = (byte)nalLength;
        p[1] = (byte)parameterSets.Count;
        int at = 2;
        foreach (var s in parameterSets)
        {
            BinaryPrimitives.WriteUInt16BigEndian(p.AsSpan(at), (ushort)s.Length);
            s.CopyTo(p, at + 2);
            at += 2 + s.Length;
        }
        Send(MessageType.Format, p);
    }

    public void SendFrame(ReadOnlySpan<byte> avcc, bool keyframe)
    {
        uint seq;
        lock (_statLock)
        {
            seq = ++_sentSeq;
            _statFrames++;
            _statBytes += avcc.Length;
        }
        byte[] p = new byte[13 + avcc.Length];
        p[0] = (byte)(keyframe ? 1 : 0);
        BinaryPrimitives.WriteUInt32BigEndian(p.AsSpan(1), seq);
        BinaryPrimitives.WriteUInt64BigEndian(p.AsSpan(5), Wire.MonotonicMicros());
        avcc.CopyTo(p.AsSpan(13));
        Send(MessageType.Frame, p);
    }

    /// `inputSeq`: the last movement of the old Mac's mouse included in this position.
    public void SendCursorPosition(short x, short y, bool visible, uint inputSeq)
    {
        byte[] p = new byte[9];
        BinaryPrimitives.WriteInt16BigEndian(p, x);
        BinaryPrimitives.WriteInt16BigEndian(p.AsSpan(2), y);
        p[4] = (byte)(visible ? 1 : 0);
        BinaryPrimitives.WriteUInt32BigEndian(p.AsSpan(5), inputSeq);
        Send(MessageType.CursorPosition, p);
    }

    /// Raw BGRA pixels (premultiplied, top row first); size and hot spot in stream pixels.
    public void SendCursorImage(ushort width, ushort height, ushort hotX, ushort hotY,
                                ushort pixelWidth, ushort pixelHeight, ReadOnlySpan<byte> bgra)
    {
        byte[] p = new byte[12 + bgra.Length];
        BinaryPrimitives.WriteUInt16BigEndian(p, width);
        BinaryPrimitives.WriteUInt16BigEndian(p.AsSpan(2), height);
        BinaryPrimitives.WriteUInt16BigEndian(p.AsSpan(4), hotX);
        BinaryPrimitives.WriteUInt16BigEndian(p.AsSpan(6), hotY);
        BinaryPrimitives.WriteUInt16BigEndian(p.AsSpan(8), pixelWidth);
        BinaryPrimitives.WriteUInt16BigEndian(p.AsSpan(10), pixelHeight);
        bgra.CopyTo(p.AsSpan(12));
        Send(MessageType.CursorImage, p);
    }

    /// Once per session at most.
    public void SendCue(byte cue)
    {
        lock (_gate) if (_closed || _state != State.Ready) return;
        lock (_statLock)
        {
            if (_cueSent) return;
            _cueSent = true;
        }
        Send(MessageType.Cue, [cue]);
    }

    /// Accept (or stop accepting) the old Mac's keyboard and mouse. Only possible in an
    /// encrypted session with a viewer that supports it: without encryption anyone on the
    /// network could inject keystrokes into the connection.
    public void SetInputEnabled(bool wanted)
    {
        bool sendControl, enabled, wasEnabled;
        lock (_gate)
        {
            if (_closed || _state != State.Ready || _hello == null) return;
            bool supported = _hello.Has("input");
            enabled = wanted && supported && _recvChannel != null;
            if (enabled == _inputEnabled && _inputControlSent) return;
            wasEnabled = _inputEnabled;
            _inputEnabled = enabled;
            _inputControlSent = true;
            sendControl = supported;
        }
        if (wasEnabled && !enabled) OnInput?.Invoke(new InputEvent.Reset());
        if (sendControl) Send(MessageType.InputControl, [(byte)(enabled ? 1 : 0)]);
    }

    /// Frames, seals (once the session is encrypted) and writes one message.
    void Send(MessageType type, ReadOnlySpan<byte> payload)
    {
        lock (_sendLock)
        {
            Socket? socket = _socket;
            if (_closed || socket == null) return;
            byte[] message;
            if (_sendChannel != null)
            {
                byte[] inner = new byte[1 + payload.Length];
                inner[0] = (byte)type;
                payload.CopyTo(inner.AsSpan(1));
                byte[]? sealedMessage = _sendChannel.Seal(inner);
                if (sealedMessage == null)
                {
                    ThreadPool.QueueUserWorkItem(_ => Close("Encryption failed."));
                    return;
                }
                message = Wire.Message(MessageType.Secure, sealedMessage);
            }
            else
            {
                message = Wire.Message(type, payload);
            }
            try
            {
                int sent = 0;
                while (sent < message.Length) sent += socket.Send(message, sent, message.Length - sent, SocketFlags.None);
            }
            catch (Exception e) when (e is SocketException or ObjectDisposedException)
            {
                ThreadPool.QueueUserWorkItem(_ => Close($"Send failed: {e.Message}"));
            }
        }
    }

    // MARK: - Lifecycle

    void Run()
    {
        Socket socket;
        try
        {
            socket = Connect();
        }
        catch (Exception e)
        {
            Close($"Cannot reach {DisplayName}: {e.Message}");
            return;
        }
        lock (_sendLock)
        {
            if (_closed) { socket.Dispose(); return; }
            _socket = socket;
        }
        Interlocked.Exchange(ref _lastReceive, System.Diagnostics.Stopwatch.GetTimestamp());
        lock (_gate)
        {
            _handshakeStarted = System.Diagnostics.Stopwatch.GetTimestamp();
            _nonceHost = RdCrypto.Random(RdCrypto.NonceLength);
        }
        Send(MessageType.Hello, Wire.HostHello(_localName, _hostId, RdCrypto.Hex(_nonceHost), Encrypt));
        _timer = new System.Threading.Timer(_ => Tick(), null, 1000, 1000);
        ReceiveLoop(socket);
    }

    Socket Connect()
    {
        IPAddress[] addresses = IPAddress.TryParse(_host, out var ip)
            ? [ip]
            : Dns.GetHostAddresses(_host).OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? 0 : 1).ToArray();
        Exception? last = null;
        foreach (var address in addresses)
        {
            var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp)
            {
                NoDelay = true,
                SendTimeout = 6000,
                SendBufferSize = 1 << 20,
            };
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                socket.ConnectAsync(new IPEndPoint(address, _port), cts.Token).AsTask().GetAwaiter().GetResult();
                socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
                return socket;
            }
            catch (Exception e)
            {
                socket.Dispose();
                last = e is OperationCanceledException ? new TimeoutException("the connection timed out") : e;
                if (_closed) throw last;
            }
        }
        throw last ?? new IOException("no address");
    }

    void Tick()
    {
        if (_closed) return;
        long now = System.Diagnostics.Stopwatch.GetTimestamp();
        double idle = (now - Interlocked.Read(ref _lastReceive)) / (double)System.Diagnostics.Stopwatch.Frequency;
        if (idle > 6)
        {
            Close($"{DisplayName} stopped responding.");
            return;
        }
        bool encrypted;
        lock (_gate)
        {
            if (_state != State.Ready && _handshakeStarted != 0 &&
                (now - _handshakeStarted) / (double)System.Diagnostics.Stopwatch.Frequency > 120)
            {
                bool pairing = _state != State.AwaitHello && _state != State.AwaitAuth;
                ThreadPool.QueueUserWorkItem(_ => Close(pairing ? "Pairing timed out." : $"{DisplayName} did not complete the connection."));
                return;
            }
            encrypted = _recvChannel != null;
        }
        byte[] ping = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(ping, Wire.MonotonicMicros());
        Send(MessageType.Ping, ping);

        Stats stats;
        lock (_statLock)
        {
            stats = new Stats(_statFrames, _statBytes * 8 / 1_000_000.0, _rttMs, _viewerStats, encrypted);
            _statFrames = 0;
            _statBytes = 0;
        }
        OnStats?.Invoke(stats);
    }

    void Close(string? reason)
    {
        bool releaseInput;
        lock (_gate)
        {
            if (_closed) return;
            _closed = true;
            releaseInput = _inputEnabled;
            _inputEnabled = false;
            _ecdh?.Dispose();
            _ecdh = null;
            _pairKey = [];
            _authKey = null;
        }
        _timer?.Dispose();
        lock (_sendLock)
        {
            try { _socket?.Shutdown(SocketShutdown.Both); } catch { }
            _socket?.Dispose();
            _sendChannel?.Dispose();
            _sendChannel = null;
        }
        if (releaseInput) OnInput?.Invoke(new InputEvent.Reset());   // nothing stays pressed on this PC
        ThreadPool.QueueUserWorkItem(_ => OnClosed?.Invoke(reason));
    }

    // MARK: - Receiving (connection thread)

    void ReceiveLoop(Socket socket)
    {
        byte[] header = new byte[5];
        try
        {
            while (!_closed)
            {
                if (!ReadFully(socket, header)) { Close($"{DisplayName} closed the connection."); return; }
                byte type = header[0];
                uint length = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(1));
                if (length > RD.MaxViewerMessageSize) { Close("Protocol error (message too large)."); return; }
                byte[] payload = new byte[length];
                if (length > 0 && !ReadFully(socket, payload)) { Close($"{DisplayName} closed the connection."); return; }
                Interlocked.Exchange(ref _lastReceive, System.Diagnostics.Stopwatch.GetTimestamp());
                Receive(type, payload);
            }
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException or IOException)
        {
            Close(_closed ? null : $"Connection lost: {e.Message}");
        }
    }

    static bool ReadFully(Socket socket, byte[] buffer)
    {
        int done = 0;
        while (done < buffer.Length)
        {
            int n = socket.Receive(buffer, done, buffer.Length - done, SocketFlags.None);
            if (n <= 0) return false;
            done += n;
        }
        return true;
    }

    /// Unwraps SECURE envelopes, then dispatches.
    void Receive(byte rawType, byte[] payload)
    {
        if (rawType == (byte)MessageType.Secure)
        {
            byte[]? inner = _recvChannel?.Open(payload);
            if (inner == null || inner.Length < 1 || inner[0] == (byte)MessageType.Secure)
            {
                Close($"A message from {DisplayName} failed authentication.");
                return;
            }
            Handle(inner[0], inner.AsSpan(1));
        }
        else if (_recvChannel != null)
        {
            Close($"{DisplayName} sent unencrypted data in an encrypted session.");
        }
        else
        {
            Handle(rawType, payload);
        }
    }

    void Handle(byte rawType, ReadOnlySpan<byte> payload)
    {
        State state;
        lock (_gate) state = _state;
        if (!Enum.IsDefined(typeof(MessageType), rawType))
        {
            // Unknown types are ignored once the session runs (forward compat), never before.
            if (state != State.Ready) Close("Protocol error during the security handshake.");
            return;
        }
        var type = (MessageType)rawType;
        if (type == MessageType.Pong)
        {
            if (payload.Length >= 8)
            {
                ulong t = BinaryPrimitives.ReadUInt64BigEndian(payload), now = Wire.MonotonicMicros();
                if (now >= t) lock (_statLock) _rttMs = (now - t) / 1000.0;
            }
            return;
        }
        if (state != State.Ready)
        {
            HandleHandshake(type, payload.ToArray());
            return;
        }

        switch (type)
        {
            case MessageType.Ack when payload.Length >= 4:
                uint seq = BinaryPrimitives.ReadUInt32BigEndian(payload);
                lock (_statLock)
                {
                    // Acks arrive in order; guard against anything odd anyway.
                    if (seq - _ackedSeq <= _sentSeq - _ackedSeq) _ackedSeq = seq;
                }
                break;
            case MessageType.KeyframeRequest:
                OnKeyframeRequest?.Invoke();
                break;
            case MessageType.ViewerStats:
                var stats = ViewerStats.Parse(payload);
                if (stats != null) lock (_statLock) _viewerStats = stats;
                break;
            case MessageType.InputMove or MessageType.InputButton or MessageType.InputScroll
                or MessageType.InputKey or MessageType.InputReset:
                bool accept;
                lock (_gate) accept = _inputEnabled && _recvChannel != null;
                // Ignored unless the user turned the feature on and the session is encrypted.
                if (accept && InputEvent.Parse(type, payload) is { } e) OnInput?.Invoke(e);
                break;
        }
    }

    // MARK: - Handshake (connection thread, or the UI's decision)

    void HandleHandshake(MessageType type, byte[] payload)
    {
        string? fail = null;
        Action? after = null;
        lock (_gate)
        {
            if (_closed) return;
            switch (_state, type)
            {
                case (State.AwaitHello, MessageType.Hello):
                {
                    ViewerHello? hello = ViewerHello.Parse(payload);
                    if (hello == null) { fail = "Invalid HELLO from viewer."; break; }
                    if (hello.Proto != RD.ProtocolVersion)
                    {
                        fail = $"The viewer runs a different version of Screen3R (protocol {hello.Proto}, this app {RD.ProtocolVersion}). Update both apps.";
                        break;
                    }
                    byte[]? nonce = RdCrypto.Unhex(hello.Nonce, RdCrypto.NonceLength);
                    if (!RdCrypto.IsValidId(hello.Id) || nonce == null) { fail = "Invalid HELLO from viewer."; break; }
                    _hello = hello;
                    _viewerId = hello.Id!;
                    _nonceViewer = nonce;
                    var gate = OnHelloGate;
                    if (gate != null)
                    {
                        _state = State.HelloGate;
                        after = () => gate(hello, ResumeAfterHello);
                    }
                    else
                    {
                        after = StartAuthenticationLocked();
                    }
                    break;
                }
                case (State.AwaitAuth, MessageType.Auth):
                    if (_authKey == null ||
                        !RdCrypto.Equal(payload, RdCrypto.SessionProof(_authKey, SessionTranscript(), fromHost: false)))
                    {
                        fail = $"{DisplayName} could not prove it is the paired screen.";
                        break;
                    }
                    after = StartSessionLocked(_authKey);
                    break;

                case (State.AwaitAuth, MessageType.NeedPairing):
                    _authKey = null;
                    after = StartPairingLocked();   // the viewer forgot us (or never knew us): pair again
                    break;

                case (State.PairAwaitKey, MessageType.PairKey):
                {
                    byte[]? z = _ecdh?.SharedSecret(payload);
                    if (_ecdh == null || z == null) { fail = "Pairing failed (invalid key)."; break; }
                    byte[] pkHost = _ecdh.PublicKey;
                    _pairTranscript = RdCrypto.PairTranscript(_hostId, _viewerId, pkHost, payload);
                    _pairKey = RdCrypto.PairKey(z, _pairTranscript);
                    _ecdh.Dispose();
                    _ecdh = null;
                    uint code = RdCrypto.PairCode(_pairKey, _pairTranscript);
                    string text = $"{code / 1000:000} {code % 1000:000}";
                    string name = Wire.SanitizedName(_hello?.Name ?? DisplayName);
                    _state = State.PairAwaitUser;
                    after = () =>
                    {
                        Send(MessageType.PairKey, pkHost);
                        var ask = OnPairingCode;
                        if (ask == null) UserDecided(false);
                        else ask(text, name, UserDecided);
                    };
                    break;
                }
                case (State.PairAwaitConfirm, MessageType.PairConfirm):
                    if (!RdCrypto.Equal(payload, RdCrypto.PairConfirm(_pairKey, _pairTranscript, fromHost: false)))
                    {
                        fail = "Pairing failed (wrong confirmation).";
                        break;
                    }
                    _keys.Store(_viewerId, _pairKey, Wire.SanitizedName(_hello?.Name ?? DisplayName));
                    after = StartSessionLocked(_pairKey);
                    break;

                default:
                    fail = "Protocol error during the security handshake.";
                    break;
            }
        }
        if (fail != null) Close(fail);
        else after?.Invoke();
    }

    void ResumeAfterHello()
    {
        Action next;
        lock (_gate)
        {
            if (_closed || _state != State.HelloGate) return;
            next = StartAuthenticationLocked();
        }
        next();
    }

    /// Known viewer: prove we hold its key. Otherwise: pair.
    Action StartAuthenticationLocked()
    {
        byte[]? key = _keys.Get(_viewerId);
        if (key is { Length: RdCrypto.KeyLength })
        {
            _authKey = key;
            _state = State.AwaitAuth;
            byte[] proof = RdCrypto.SessionProof(key, SessionTranscript(), fromHost: true);
            return () => Send(MessageType.Auth, proof);
        }
        return StartPairingLocked();
    }

    byte[] SessionTranscript() =>
        RdCrypto.SessionTranscript(_hostId, _viewerId, _nonceHost, _nonceViewer, Encrypt);

    Action StartPairingLocked()
    {
        _ecdh?.Dispose();
        _ecdh = new EcdhKeyPair();
        _handshakeStarted = System.Diagnostics.Stopwatch.GetTimestamp();   // pairing gets its own 120 s
        _state = State.PairAwaitKey;
        byte[] commitment = RdCrypto.Commitment(_ecdh.PublicKey);
        return () => Send(MessageType.PairCommit, commitment);
    }

    void UserDecided(bool accepted)
    {
        byte[] confirm;
        lock (_gate)
        {
            if (_closed || _state != State.PairAwaitUser) return;
            if (accepted)
            {
                _state = State.PairAwaitConfirm;
                confirm = RdCrypto.PairConfirm(_pairKey, _pairTranscript, fromHost: true);
            }
            else confirm = [];
        }
        if (!accepted) Close("Pairing cancelled: the codes did not match.");
        else Send(MessageType.PairConfirm, confirm);
    }

    /// The viewer has proven it holds the pairing key: switch on encryption and start streaming.
    Action StartSessionLocked(byte[] key)
    {
        if (Encrypt)
        {
            var (send, recv) = SecureChannel.ForHost(key, SessionTranscript());
            _recvChannel = recv;
            lock (_sendLock) _sendChannel = send;
        }
        _pairKey = [];
        _authKey = null;
        _handshakeStarted = 0;
        _state = State.Ready;
        ViewerHello hello = _hello!;
        return () => OnReady?.Invoke(hello);
    }
}
