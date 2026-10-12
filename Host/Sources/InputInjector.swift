//
//  InputInjector.swift
//  Screen3R (host)
//
//  Turns keyboard and mouse events from the old Mac into real events on this Mac
//  (CGEvent posting: needs Privacy & Security › Accessibility).
//
//  - The mouse is relative: the old Mac sends movements, not positions, so the pointer
//    can leave the old Mac's screen and reach every other display, as a second mouse would.
//    Movements are in stream pixels and are scaled to points, so in mirror mode the pointer
//    moves on the old Mac's screen exactly as far as the mouse was moved.
//  - Keys are sent as key codes (physical keys): this Mac's keyboard layout decides the
//    characters. The old Mac's keyboard type is passed along so ISO keys map correctly.
//  - Every key and button pressed is tracked and released when the session ends, the
//    feature is switched off or the old Mac asks for it, so nothing can stay stuck down.
//
//  Called on the connection's network queue; `releaseAll()` from any thread.
//

import CoreGraphics
import Foundation

final class InputInjector: @unchecked Sendable {
    /// Where an injected movement put the pointer, and its sequence number (for the viewer's
    /// local pointer prediction). Called on the caller's thread, inside the lock: keep it quick.
    var onMoved: ((CGPoint, UInt32) -> Void)?

    /// Modifier bits we let through: device-independent modifiers plus left/right bits.
    private static let allowedFlags: UInt64 =
        CGEventFlags([.maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand,
                      .maskSecondaryFn, .maskNumericPad, .maskHelp]).rawValue | 0x207F

    private let displayID: CGDirectDisplayID
    private let streamWidth: Int
    private let streamHeight: Int
    private let source: CGEventSource?

    private let lock = NSLock()
    private var stopped = false                  // guarded by lock (as everything below)
    private var position: CGPoint?               // last position we moved the pointer to
    private var lastMoveMicros: UInt64 = 0
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<UInt8>()

    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    init(displayID: CGDirectDisplayID, streamWidth: Int, streamHeight: Int) {
        self.displayID = displayID
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
        source = CGEventSource(stateID: .hidSystemState)
        // By default posting an event briefly mutes this Mac's own trackpad and keyboard.
        source?.localEventsSuppressionInterval = 0
    }

    func handle(_ event: InputEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        switch event {
        case let .move(seq, dx, dy, flags):
            move(seq: seq, dx: dx, dy: dy, flags: flags)
        case let .button(button, down, clicks, flags):
            self.button(button, down: down, clicks: clicks, flags: flags)
        case let .scroll(continuous, phase, momentum, dy, dx, flags):
            scroll(continuous: continuous, phase: phase, momentum: momentum, dy: dy, dx: dx, flags: flags)
        case let .key(code, down, isRepeat, keyboardType, flags):
            key(code, down: down, isRepeat: isRepeat, keyboardType: keyboardType, flags: flags)
        case .reset:
            releaseHeld()
        }
    }

    /// Releases everything held and ignores any later event. Any thread.
    func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        releaseHeld()
        stopped = true
    }

    // MARK: - Mouse (lock held)

    /// The pointer position to start from: ours while the old Mac's mouse is moving,
    /// otherwise the real one (this Mac's trackpad may have moved it in the meantime).
    /// Reading the real position right after posting could return a stale value.
    private func currentPosition() -> CGPoint {
        if let position, monotonicMicros() &- lastMoveMicros < 100_000 { return position }
        return CGEvent(source: nil)?.location ?? .zero
    }

    private func move(seq: UInt32, dx: Int16, dy: Int16, flags: UInt32) {
        let base = currentPosition()
        guard let map = StreamMapping(displayID: displayID, streamWidth: streamWidth, streamHeight: streamHeight)
        else {
            onMoved?(base, seq)   // still confirm the movement, or the viewer's prediction drifts
            return
        }
        let k = map.pointsPerStreamPixel
        let target = clampToDisplays(CGPoint(x: base.x + CGFloat(dx) * k, y: base.y + CGFloat(dy) * k), from: base)
        position = target
        lastMoveMicros = monotonicMicros()

        let type: CGEventType
        let mouseButton: CGMouseButton
        if pressedButtons.contains(0) {
            type = .leftMouseDragged; mouseButton = .left
        } else if pressedButtons.contains(1) {
            type = .rightMouseDragged; mouseButton = .right
        } else if !pressedButtons.isEmpty {
            type = .otherMouseDragged; mouseButton = .center
        } else {
            type = .mouseMoved; mouseButton = .left
        }
        if let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target,
                               mouseButton: mouseButton) {
            if type == .otherMouseDragged, let other = pressedButtons.min() {
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(other))
            }
            // Relative movement too, for apps that read deltas (games, 3D viewers…).
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((target.x - base.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((target.y - base.y).rounded()))
            event.flags = Self.flags(flags)
            event.post(tap: .cghidEventTap)
        }
        onMoved?(target, seq)
    }

    /// Keeps the pointer on a display: it may cross to any display next to this one,
    /// otherwise it slides along the edge of the display it is on.
    private func clampToDisplays(_ point: CGPoint, from base: CGPoint) -> CGPoint {
        if display(at: point) != nil { return point }
        let bounds = CGDisplayBounds(display(at: base) ?? CGMainDisplayID())
        guard bounds.width > 0, bounds.height > 0 else { return base }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private func display(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    private func button(_ button: UInt8, down: Bool, clicks: UInt8, flags: UInt32) {
        // A release for a button pressed before the old Mac took over is not ours to send.
        guard down || pressedButtons.contains(button) else { return }
        let p = currentPosition()
        let type: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; mouseButton = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; mouseButton = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; mouseButton = .center
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                                  mouseButton: mouseButton) else { return }
        if button >= 2 { event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clicks)))   // double clicks
        event.flags = Self.flags(flags)
        event.post(tap: .cghidEventTap)
        if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
    }

    private func scroll(continuous: Bool, phase: UInt8, momentum: UInt8, dy: Int32, dx: Int32, flags: UInt32) {
        // Trackpads and Magic Mouse scroll in pixels with phases (so momentum and rubber-banding
        // work); wheel mice in lines.
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: continuous ? .pixel : .line,
                                  wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        if continuous { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
        event.flags = Self.flags(flags)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard (lock held)

    private func key(_ code: UInt16, down: Bool, isRepeat: Bool, keyboardType: UInt8, flags: UInt32) {
        // Caps Lock can't be toggled by posted events; its state travels in the flags instead.
        guard code != 57 else { return }
        guard down || pressedKeys.contains(code) else { return }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        else { return }
        event.flags = Self.flags(flags)
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        if keyboardType > 0 { event.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(keyboardType)) }
        event.post(tap: .cghidEventTap)
        if down { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
    }

    private func releaseHeld() {
        for code in pressedKeys {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
            else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        pressedKeys.removeAll()
        let p = currentPosition()
        for button in pressedButtons {
            let type: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            let mouseButton: CGMouseButton = button == 0 ? .left : (button == 1 ? .right : .center)
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                                      mouseButton: mouseButton) else { continue }
            if button >= 2 { event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        pressedButtons.removeAll()
        position = nil
    }

    private static func flags(_ raw: UInt32) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(raw) & allowedFlags)
    }
}
