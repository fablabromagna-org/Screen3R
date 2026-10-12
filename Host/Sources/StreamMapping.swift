//
//  StreamMapping.swift
//  Screen3R (host)
//
//  Which part of the desktop the stream shows, and where it lands in the stream.
//  Extended mode: the virtual display, 1:1. Mirror mode: the display being mirrored,
//  scaled to fit the stream (aspect ratio kept, centred).
//  Global coordinates are in points with the origin at the top-left of the main display,
//  like CGEvent locations; stream coordinates are pixels with the origin at the top-left.
//

import CoreGraphics

struct StreamMapping {
    /// Area of the global desktop shown in the stream (points).
    let source: CGRect
    /// Where that area appears in the stream (stream pixels).
    let content: CGRect

    init?(displayID: CGDirectDisplayID, streamWidth: Int, streamHeight: Int) {
        // In a mirror set every display shows the primary one.
        let shown = CGDisplayPrimaryDisplay(displayID)
        let src = CGDisplayBounds(shown)
        guard src.width > 0, src.height > 0, streamWidth > 0, streamHeight > 0 else { return nil }
        let sw = CGFloat(streamWidth), sh = CGFloat(streamHeight)
        let scale = min(sw / src.width, sh / src.height)
        let w = src.width * scale, h = src.height * scale
        source = src
        content = CGRect(x: (sw - w) / 2, y: (sh - h) / 2, width: w, height: h)
    }

    /// Desktop points per stream pixel (1 in extended mode).
    var pointsPerStreamPixel: CGFloat { source.width / content.width }

    func contains(_ location: CGPoint) -> Bool { source.contains(location) }

    /// Global location -> stream pixel.
    func streamPoint(_ location: CGPoint) -> (x: Int, y: Int) {
        let k = content.width / source.width
        return (Int((content.minX + (location.x - source.minX) * k).rounded(.down)),
                Int((content.minY + (location.y - source.minY) * k).rounded(.down)))
    }
}
