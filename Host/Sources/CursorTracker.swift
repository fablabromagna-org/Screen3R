//
//  CursorTracker.swift
//  Screen3R (host)
//
//  Sends the mouse pointer separately from the video, so the viewer can draw it
//  itself with network latency only (a few ms) instead of waiting for
//  capture → encode → send → decode → display of a whole frame.
//
//  - Position: polled every 8 ms (CGEvent location, thread-safe), sent only when
//    it changes or when the pointer enters/leaves the virtual display. While the old Mac's
//    own mouse moves the pointer, the injected positions are sent at once instead, tagged
//    with the movement's sequence number, so the viewer can draw the pointer ahead of the
//    network (local prediction) and reconcile when the position comes back.
//  - Shape: polled every 100 ms on the main thread (NSCursor.currentSystem), sent as
//    raw BGRA pixels (no image file format: the viewer never runs an image decoder on
//    network data), only when it changes and only while the pointer is on the virtual
//    display, so nothing about what you do on the other screens leaves this Mac.
//

import AppKit

final class CursorTracker: @unchecked Sendable {
    struct CursorImage {
        let pixels: Data       // BGRA, premultiplied alpha, rows top to bottom
        let pixelWidth: Int
        let pixelHeight: Int
        let size: CGSize       // points
        let hotSpot: CGPoint   // points, from the top-left corner
    }

    /// Called on the tracker's queue. Coordinates in stream pixels, origin top-left; the last
    /// input movement (from the old Mac) included in this position.
    var onPosition: ((Int16, Int16, Bool, UInt32) -> Void)?
    /// Called on the main thread.
    var onImage: ((CursorImage) -> Void)?

    static let maxCursorSide = 256   // must match the viewer's limit

    private let displayID: CGDirectDisplayID
    private let streamWidth: Int
    private let streamHeight: Int
    private let queue = DispatchQueue(label: "screen3r.cursor", qos: .userInteractive)

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var lastX = Int.min
    private var lastY = Int.min
    private var lastVisible = false
    private var lastSent = DispatchTime.now()
    private var inputSeq: UInt32 = 0
    private var lastInjectedMicros: UInt64 = 0

    // Shared between `queue` (writer) and the main thread (reader).
    private let visibleLock = NSLock()
    private var pointerOnDisplay = false

    // Only touched on the main thread.
    private var imageTimer: Timer?
    private var lastPixels: Data?
    private var lastHotSpot = CGPoint.zero

    init(displayID: CGDirectDisplayID, streamWidth: Int, streamHeight: Int) {
        self.displayID = displayID
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
    }

    /// Call on the main thread.
    func start() {
        // Strong capture is fine here: this closure runs once; the timer handler below is weak.
        queue.async { [self] in
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.pollPosition() }
            t.resume()
            self.timer = t
        }
        imageTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollImage()
        }
    }

    /// Call on the main thread.
    func stop() {
        imageTimer?.invalidate()
        imageTimer = nil
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// The old Mac's mouse moved the pointer to `location` (global points). Any thread.
    func injected(at location: CGPoint, seq: UInt32) {
        queue.async { [weak self] in self?.report(location, injectedSeq: seq) }
    }

    private func pollPosition() {
        // While the old Mac's mouse is moving, its exact positions are reported by `injected`;
        // a polled one could be older than the last movement and make the pointer jump back.
        guard monotonicMicros() &- lastInjectedMicros > 60_000 else { return }
        guard let location = CGEvent(source: nil)?.location else { return }
        report(location, injectedSeq: nil)
    }

    private func report(_ location: CGPoint, injectedSeq: UInt32?) {
        // Global coordinates, origin top-left, like CGEvent. Mirror mode: the mirrored display.
        guard let map = StreamMapping(displayID: displayID, streamWidth: streamWidth, streamHeight: streamHeight)
        else { return }
        if let injectedSeq {
            inputSeq = injectedSeq
            lastInjectedMicros = monotonicMicros()
        }

        let visible = map.contains(location)
        var x = lastX, y = lastY
        if visible {
            let p = map.streamPoint(location)
            x = p.x
            y = p.y
        }

        if visible != lastVisible {
            visibleLock.lock()
            pointerOnDisplay = visible
            visibleLock.unlock()
        }

        let changed = visible != lastVisible || (visible && (x != lastX || y != lastY))
        // Also resend once a second, in case the viewer missed the state (e.g. it reconnected).
        let stale = DispatchTime.now().uptimeNanoseconds - lastSent.uptimeNanoseconds > 1_000_000_000
        // Injected positions always go out: the viewer needs the sequence number back.
        guard changed || stale || injectedSeq != nil else { return }

        lastX = x
        lastY = y
        lastVisible = visible
        lastSent = .now()
        // Off the virtual display only "not visible" is sent, never where the pointer is.
        onPosition?(Int16(clamping: visible ? x : 0), Int16(clamping: visible ? y : 0), visible, inputSeq)
    }

    /// Always called on the main thread (the main-run-loop timer).
    private func pollImage() {
        MainActor.assumeIsolated { self.pollImageOnMain() }
    }

    @MainActor
    private func pollImageOnMain() {
        visibleLock.lock()
        let onDisplay = pointerOnDisplay
        visibleLock.unlock()
        guard onDisplay, let cursor = NSCursor.currentSystem else { return }

        let image = cursor.image
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { return }
        let w = min(Self.maxCursorSide, Int(size.width.rounded(.up)))
        let h = min(Self.maxCursorSide, Int(size.height.rounded(.up)))

        // Render at 1x (the viewer's display is 1x) into a BGRA premultiplied bitmap.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let base = ctx.data else { return }
        let pixels = Data(bytes: base, count: w * h * 4)

        // Scaled like the image (it is squeezed into w × h if larger than the limit).
        let hotSpot = CGPoint(x: min(max(cursor.hotSpot.x * CGFloat(w) / size.width, 0), CGFloat(w)),
                              y: min(max(cursor.hotSpot.y * CGFloat(h) / size.height, 0), CGFloat(h)))
        guard pixels != lastPixels || hotSpot != lastHotSpot else { return }
        lastPixels = pixels
        lastHotSpot = hotSpot
        onImage?(CursorImage(pixels: pixels, pixelWidth: w, pixelHeight: h,
                             size: CGSize(width: w, height: h), hotSpot: hotSpot))
    }
}
