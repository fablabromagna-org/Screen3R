//
//  CursorTracker.cs
//  Screen3R for Windows
//
//  Sends the mouse pointer separately from the video (as the Mac host does), so the viewer
//  draws it with network latency only:
//  - position: polled every 8 ms, sent when it changes (and at least once a second);
//    movements made with the old Mac's mouse are reported at once with their sequence number;
//  - shape: checked every 100 ms while the pointer is on the streamed display, sent as raw
//    premultiplied BGRA pixels (no image file format) only when it changes.
//

using System.Runtime.InteropServices;
using static Screen3R.Native;

namespace Screen3R;

sealed class CursorTracker : IDisposable
{
    const int MaxSide = 256;   // must match the viewer's limit

    /// Stream pixels (origin top-left), visible on the streamed display, last input movement included.
    public Action<short, short, bool, uint>? OnPosition;
    /// Size and hot spot in stream pixels, then pixel size and BGRA pixels.
    public Action<ushort, ushort, ushort, ushort, ushort, ushort, byte[]>? OnImage;

    readonly StreamMapping _map;
    readonly object _lock = new();
    readonly Thread _thread;
    volatile bool _stopped;

    // guarded by _lock
    int _lastX = int.MinValue, _lastY = int.MinValue;
    bool _lastVisible;
    long _lastSent;
    uint _inputSeq;
    ulong _lastInjected;

    // tracker thread only
    nint _lastCursor;

    public CursorTracker(StreamMapping map)
    {
        _map = map;
        _thread = new Thread(Run) { IsBackground = true, Name = "Screen3R cursor", Priority = ThreadPriority.AboveNormal };
    }

    public void Start() => _thread.Start();

    /// The old Mac's mouse moved the pointer to (x, y) (desktop pixels). Any thread.
    public void Injected(int x, int y, uint seq) => Report(x, y, ShowingCursor(), seq);

    void Run()
    {
        timeBeginPeriod(1);   // 8 ms sleeps instead of the default 15.6 ms ticks
        try
        {
            int n = 0;
            while (!_stopped)
            {
                Poll();
                if (++n % 12 == 0) PollImage();
                Thread.Sleep(8);
            }
        }
        finally
        {
            timeEndPeriod(1);
        }
    }

    static bool ShowingCursor()
    {
        var info = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        return !GetCursorInfo(ref info) || (info.flags & CURSOR_SHOWING) != 0;
    }

    void Poll()
    {
        lock (_lock)
        {
            // While the old Mac's mouse is moving, its exact positions are reported by Injected;
            // a polled one could be older and make the pointer jump back.
            if (Wire.MonotonicMicros() - _lastInjected < 60_000) return;
        }
        if (!GetCursorPos(out POINT p)) return;
        Report(p.X, p.Y, ShowingCursor(), null);
    }

    void Report(int x, int y, bool showing, uint? injectedSeq)
    {
        lock (_lock)
        {
            if (injectedSeq is uint seq)
            {
                _inputSeq = seq;
                _lastInjected = Wire.MonotonicMicros();
            }
            bool visible = showing && _map.Contains(x, y);
            int sx = _lastX, sy = _lastY;
            if (visible) (sx, sy) = _map.StreamPoint(x, y);
            bool changed = visible != _lastVisible || (visible && (sx != _lastX || sy != _lastY));
            long now = Environment.TickCount64;
            bool stale = now - _lastSent > 1000;   // resend once a second in any case
            if (!changed && !stale && injectedSeq == null) return;
            _lastX = sx;
            _lastY = sy;
            _lastVisible = visible;
            _lastSent = now;
            // Off the streamed display only "not visible" is sent, never where the pointer is.
            OnPosition?.Invoke((short)Math.Clamp(visible ? sx : 0, short.MinValue, short.MaxValue),
                               (short)Math.Clamp(visible ? sy : 0, short.MinValue, short.MaxValue), visible, _inputSeq);
        }
    }

    unsafe void PollImage()
    {
        bool onDisplay;
        lock (_lock) onDisplay = _lastVisible;
        if (!onDisplay) return;
        var info = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref info) || info.hCursor == 0 || info.hCursor == _lastCursor) return;
        if (!GetIconInfo(info.hCursor, out ICONINFO icon)) return;
        try
        {
            BITMAP bm;
            int w, h;
            if (icon.hbmColor != 0 && GetObject(icon.hbmColor, sizeof(BITMAP), &bm) != 0)
            {
                w = bm.bmWidth;
                h = bm.bmHeight;
            }
            else if (icon.hbmMask != 0 && GetObject(icon.hbmMask, sizeof(BITMAP), &bm) != 0)
            {
                w = bm.bmWidth;
                h = bm.bmHeight / 2;   // monochrome: AND mask above XOR mask
            }
            else return;
            if (w < 1 || h < 1 || w > MaxSide || h > MaxSide) return;

            byte[]? onBlack = Render(info.hCursor, w, h, 0x00), onWhite = Render(info.hCursor, w, h, 0xFF);
            if (onBlack == null || onWhite == null) return;
            byte[] pixels = Combine(onBlack, onWhite, w, h);
            _lastCursor = info.hCursor;

            // The viewer draws it in stream pixels: scale like the picture.
            // (At most 256 stream pixels: the viewer ignores larger pointers.)
            double k = Math.Min(1 / _map.DesktopPerStreamPixel, 256.0 / Math.Max(w, h));
            ushort sw = (ushort)Math.Max(1, Math.Round(w * k)), sh = (ushort)Math.Max(1, Math.Round(h * k));
            ushort hx = (ushort)Math.Clamp(Math.Round(icon.xHotspot * k), 0, sw), hy = (ushort)Math.Clamp(Math.Round(icon.yHotspot * k), 0, sh);
            OnImage?.Invoke(sw, sh, hx, hy, (ushort)w, (ushort)h, pixels);
        }
        finally
        {
            if (icon.hbmColor != 0) DeleteObject(icon.hbmColor);
            if (icon.hbmMask != 0) DeleteObject(icon.hbmMask);
        }
    }

    /// Draws the cursor on a uniform background into a 32-bit top-down DIB.
    static unsafe byte[]? Render(nint cursor, int w, int h, byte background)
    {
        var header = new BITMAPINFOHEADER
        {
            biSize = sizeof(BITMAPINFOHEADER), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32,
        };
        nint dc = CreateCompatibleDC(0);
        if (dc == 0) return null;
        nint bitmap = CreateDIBSection(dc, &header, 0, out nint bits, 0, 0);
        if (bitmap == 0) { DeleteDC(dc); return null; }
        nint old = SelectObject(dc, bitmap);
        try
        {
            new Span<byte>((void*)bits, w * h * 4).Fill(background);
            if (!DrawIconEx(dc, 0, 0, cursor, w, h, 0, 0, DI_NORMAL)) return null;
            GdiFlush();
            return new Span<byte>((void*)bits, w * h * 4).ToArray();
        }
        finally
        {
            SelectObject(dc, old);
            DeleteObject(bitmap);
            DeleteDC(dc);
        }
    }

    /// Alpha from the difference between the two renderings; colour from the one on black
    /// (= premultiplied). Pixels that invert the screen (classic monochrome cursors such as the
    /// text I-beam) can't be represented: they become black with a white outline.
    static byte[] Combine(byte[] black, byte[] white, int w, int h)
    {
        byte[] result = new byte[w * h * 4];
        bool[] inverting = new bool[w * h];
        for (int i = 0; i < w * h; i++)
        {
            int o = i * 4;
            int db = white[o] - black[o], dg = white[o + 1] - black[o + 1], dr = white[o + 2] - black[o + 2];
            if (db < 0 && dg < 0 && dr < 0)
            {
                inverting[i] = true;
                result[o + 3] = 255;   // opaque black
                continue;
            }
            int alpha = 255 - Math.Clamp(Math.Max(db, Math.Max(dg, dr)), 0, 255);
            result[o] = (byte)Math.Min(black[o], alpha);
            result[o + 1] = (byte)Math.Min(black[o + 1], alpha);
            result[o + 2] = (byte)Math.Min(black[o + 2], alpha);
            result[o + 3] = (byte)alpha;
        }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = y * w + x;
                if (inverting[i] || result[i * 4 + 3] != 0) continue;
                bool next = (x > 0 && inverting[i - 1]) || (x < w - 1 && inverting[i + 1]) ||
                            (y > 0 && inverting[i - w]) || (y < h - 1 && inverting[i + w]);
                if (next) { result[i * 4] = result[i * 4 + 1] = result[i * 4 + 2] = result[i * 4 + 3] = 255; }
            }
        return result;
    }

    public void Dispose()
    {
        _stopped = true;
        if (_thread.IsAlive) _thread.Join(500);
    }
}
