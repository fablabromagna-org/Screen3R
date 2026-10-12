//
//  InputInjector.cs
//  Screen3R for Windows
//
//  Turns keyboard and mouse events from the old Mac into real input on this PC (SendInput),
//  like InputInjector.swift on the Mac:
//  - the mouse is relative: movements (in stream pixels) are scaled to desktop pixels and added
//    to the pointer position, which may leave the streamed display for the PC's other screens;
//  - keys are physical (scan codes): the Windows keyboard layout decides the characters;
//  - every key and button pressed is tracked and released when the session ends, the feature is
//    switched off or the old Mac asks for it, so nothing can stay stuck down.
//
//  Windows does not let a normal program type into windows of programs running as administrator
//  (Task Manager, installers…) or into the secure desktop (UAC, Ctrl+Alt+Del).
//

using System.Runtime.InteropServices;
using static Screen3R.Native;

namespace Screen3R;

sealed class InputInjector
{
    /// Where an injected movement put the pointer (desktop pixels) and its sequence number.
    public Action<int, int, uint>? OnMoved;

    const uint CapsLockFlag = 1 << 16;   // NSEventModifierFlagCapsLock / kCGEventFlagMaskAlphaShift

    readonly StreamMapping _map;
    readonly MacKeyboardLayout _layout;
    readonly bool _commandAsControl;
    readonly object _lock = new();
    bool _stopped;
    double _x, _y;                 // last position we moved the pointer to (sub-pixel)
    long _lastMove;                // Environment.TickCount64
    readonly Dictionary<ushort, ScanCode> _pressedKeys = new();   // Mac key -> what we pressed
    readonly HashSet<byte> _pressedButtons = new();
    double _scrollX, _scrollY;     // sub-notch remainders of continuous scrolling

    public InputInjector(StreamMapping map, MacKeyboardLayout layout, bool commandAsControl)
    {
        _map = map;
        _layout = layout;
        _commandAsControl = commandAsControl;
    }

    public void Handle(InputEvent e)
    {
        lock (_lock)
        {
            if (_stopped) return;
            switch (e)
            {
                case InputEvent.Move m: Move(m); break;
                case InputEvent.Button b: Button(b.Number, b.Down); break;
                case InputEvent.Scroll s: Scroll(s); break;
                case InputEvent.Key k: Key(k); break;
                case InputEvent.Reset: ReleaseHeld(); break;
            }
        }
    }

    /// Releases everything held and ignores any later event. Any thread.
    public void ReleaseAll()
    {
        lock (_lock)
        {
            ReleaseHeld();
            _stopped = true;
        }
    }

    // MARK: - Mouse

    void Move(InputEvent.Move m)
    {
        // Ours while the old Mac's mouse is moving, otherwise the real position (this PC's own
        // mouse may have moved it in the meantime).
        if (Environment.TickCount64 - _lastMove > 100 && GetCursorPos(out POINT p)) { _x = p.X; _y = p.Y; }
        double k = _map.DesktopPerStreamPixel;
        double tx = _x + m.Dx * k, ty = _y + m.Dy * k;
        var target = new POINT { X = (int)Math.Floor(tx), Y = (int)Math.Floor(ty) };
        if (!IsOnAnyMonitor(target))
        {
            // Slide along the edge of the display the pointer is on.
            RECT r = MonitorRect(new POINT { X = (int)Math.Floor(_x), Y = (int)Math.Floor(_y) });
            tx = Math.Clamp(tx, r.Left, r.Right - 1);
            ty = Math.Clamp(ty, r.Top, r.Bottom - 1);
            target = new POINT { X = (int)Math.Floor(tx), Y = (int)Math.Floor(ty) };
        }
        _x = tx;
        _y = ty;
        _lastMove = Environment.TickCount64;

        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = Math.Max(1, GetSystemMetrics(SM_CXVIRTUALSCREEN)), vh = Math.Max(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
        // Normalised 0…65535 over the whole virtual desktop, rounded so it lands on the pixel.
        int nx = (int)Math.Clamp(((target.X - vx) * 65536L + vw / 2) / vw, 0, 65535);
        int ny = (int)Math.Clamp(((target.Y - vy) * 65536L + vh / 2) / vh, 0, 65535);
        SendMouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, nx, ny, 0);
        OnMoved?.Invoke(target.X, target.Y, m.Seq);
    }

    void Button(byte button, bool down)
    {
        // A release for a button pressed before the old Mac took over is not ours to send.
        if (!down && !_pressedButtons.Contains(button)) return;
        if (down && _pressedButtons.Contains(button)) return;
        (uint flags, int data) = button switch
        {
            0 => (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP, 0),
            1 => (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP, 0),
            2 => (down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP, 0),
            3 => (down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, XBUTTON1),
            4 => (down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, XBUTTON2),
            _ => (0u, 0),
        };
        if (flags == 0) return;
        SendMouse(flags, 0, 0, data);   // Windows detects double clicks from the timing itself
        if (down) _pressedButtons.Add(button); else _pressedButtons.Remove(button);
    }

    void Scroll(InputEvent.Scroll s)
    {
        // Wheel mice send lines (one notch = one line on the Mac = 120 units on Windows);
        // trackpads and the Magic Mouse send pixels (about 40 pixels per notch).
        // Positive dy scrolls up on both systems; positive dx scrolls left on the Mac, right on Windows.
        double perUnit = s.Continuous ? 3.0 : 120.0;
        _scrollY += s.Dy * perUnit;
        _scrollX -= s.Dx * perUnit;
        int wy = (int)_scrollY, wx = (int)_scrollX;
        _scrollY -= wy;
        _scrollX -= wx;
        if (wy != 0) SendMouse(MOUSEEVENTF_WHEEL, 0, 0, wy);
        if (wx != 0) SendMouse(MOUSEEVENTF_HWHEEL, 0, 0, wx);
    }

    // MARK: - Keyboard

    void Key(InputEvent.Key k)
    {
        if (k.Code is KeyMap.Function or KeyMap.CapsLock) return;   // not sent as keys by the viewer
        if (k.Down)
        {
            // Caps Lock travels as a flag (bit 16) of every event; Windows has a toggle key:
            // press it before typing if the two states differ.
            bool macOn = (k.Flags & CapsLockFlag) != 0, pcOn = (GetKeyState(VK_CAPITAL) & 1) != 0;
            if (macOn != pcOn)
            {
                SendKey(new ScanCode(0x3A, false), true);
                SendKey(new ScanCode(0x3A, false), false);
            }
            if (_pressedKeys.TryGetValue(k.Code, out var held))
            {
                SendKey(held, true);   // auto-repeat
                return;
            }
            if (KeyMap.Map(k.Code, _layout, _commandAsControl) is not ScanCode sc) return;
            SendKey(sc, true);
            _pressedKeys[k.Code] = sc;
        }
        else if (_pressedKeys.Remove(k.Code, out var sc))
        {
            SendKey(sc, false);
        }
    }

    void ReleaseHeld()
    {
        foreach (var sc in _pressedKeys.Values) SendKey(sc, false);
        _pressedKeys.Clear();
        foreach (byte b in _pressedButtons.ToArray()) Button(b, false);
        _pressedButtons.Clear();
        _lastMove = 0;
    }

    static unsafe void SendKey(ScanCode sc, bool down)
    {
        INPUT input = default;
        input.type = INPUT_KEYBOARD;
        input.u.ki.wScan = sc.Code;
        input.u.ki.dwFlags = KEYEVENTF_SCANCODE | (sc.Extended ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
        SendInput(1, &input, Marshal.SizeOf<INPUT>());
    }

    static unsafe void SendMouse(uint flags, int dx, int dy, int data)
    {
        INPUT input = default;
        input.type = INPUT_MOUSE;
        input.u.mi.dx = dx;
        input.u.mi.dy = dy;
        input.u.mi.mouseData = data;
        input.u.mi.dwFlags = flags;
        SendInput(1, &input, Marshal.SizeOf<INPUT>());
    }
}
