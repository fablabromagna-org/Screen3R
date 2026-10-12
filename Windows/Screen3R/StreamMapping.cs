//
//  StreamMapping.cs
//  Screen3R for Windows
//
//  Which part of the desktop the stream shows (one display, in physical pixels) and where it
//  lands in the stream (aspect fit, centred) — the counterpart of StreamMapping.swift.
//

namespace Screen3R;

readonly record struct StreamMapping(int SourceLeft, int SourceTop, int SourceWidth, int SourceHeight,
                                     double ContentX, double ContentY, double ContentWidth, double ContentHeight)
{
    public static StreamMapping Create(int left, int top, int width, int height, int streamWidth, int streamHeight)
    {
        double scale = Math.Min(streamWidth / (double)width, streamHeight / (double)height);
        double w = width * scale, h = height * scale;
        return new StreamMapping(left, top, width, height, (streamWidth - w) / 2, (streamHeight - h) / 2, w, h);
    }

    /// Desktop pixels per stream pixel (1 when the display has the viewer's size).
    public double DesktopPerStreamPixel => SourceWidth / ContentWidth;

    public bool Contains(int x, int y) =>
        x >= SourceLeft && y >= SourceTop && x < SourceLeft + SourceWidth && y < SourceTop + SourceHeight;

    public (int X, int Y) StreamPoint(int x, int y)
    {
        double k = ContentWidth / SourceWidth;
        return ((int)Math.Floor(ContentX + (x - SourceLeft) * k), (int)Math.Floor(ContentY + (y - SourceTop) * k));
    }
}
