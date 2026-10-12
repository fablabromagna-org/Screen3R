//
//  Protocol.swift
//  Screen3R (host)
//
//  Wire protocol shared with the viewer. See PROTOCOL.md.
//  Every message: [u8 type][u32 BE payload length][payload]
//

import Foundation

enum RD {
    static let serviceType = "_screen3r._tcp"
    static let port: UInt16 = 52020
    static let protocolVersion = 2   // 2: pairing, authentication, encryption
    static let maxMessageSize = 16 * 1024 * 1024
    /// The viewer only sends small messages (HELLO, ACK, PONG, stats).
    static let maxViewerMessageSize = 64 * 1024
}

enum MessageType: UInt8 {
    case hello = 0x01            // both directions, JSON
    case format = 0x02           // host -> viewer: H.264 parameter sets
    case frame = 0x03            // host -> viewer: one encoded frame
    case keyframeRequest = 0x04  // viewer -> host
    case ack = 0x05              // viewer -> host: u32 seq
    case ping = 0x06             // host -> viewer: u64 timestamp (µs)
    case pong = 0x07             // viewer -> host: echo of ping payload
    case cursorPosition = 0x08   // host -> viewer: i16 x, i16 y, u8 flags (bit 0 = visible)
    case cursorImage = 0x09      // host -> viewer: u16 w, u16 h, u16 hotX, u16 hotY (points), u16 pixelW, u16 pixelH + raw BGRA
    case viewerStats = 0x0A      // viewer -> host: JSON, about once a second
    // Pairing and authentication (protocol 2), see PROTOCOL.md
    case pairCommit = 0x0B       // host -> viewer: SHA-256 commitment to the host's public key
    case pairKey = 0x0C          // both: 65-byte P-256 public key
    case pairConfirm = 0x0D      // both: 32-byte proof of the new pairing key
    case auth = 0x0E             // both: 32-byte proof of the stored pairing key
    case needPairing = 0x0F      // viewer -> host: no (valid) pairing for this host
    case secure = 0x10           // both: encrypted envelope around one inner message
    // Keyboard & mouse of the old Mac (viewer feature "input"), only in encrypted sessions
    case inputControl = 0x11     // host -> viewer: u8 flags (bit 0 = input accepted)
    case inputMove = 0x12        // viewer -> host: u32 seq, i16 dx, i16 dy (stream pixels), u32 modifier flags
    case inputButton = 0x13      // viewer -> host: u8 button, u8 down, u8 clickCount, u32 modifier flags
    case inputScroll = 0x14      // viewer -> host: u8 continuous, u8 phase, u8 momentumPhase, i32 dy, i32 dx, u32 flags
    case inputKey = 0x15         // viewer -> host: u16 keyCode, u8 bits (0 = down, 1 = repeat), u8 keyboardType, u32 flags
    case inputReset = 0x16       // viewer -> host: release every key and button held
}

/// One keyboard or mouse event from the old Mac, already range-checked.
enum InputEvent {
    case move(seq: UInt32, dx: Int16, dy: Int16, flags: UInt32)
    case button(button: UInt8, down: Bool, clicks: UInt8, flags: UInt32)
    case scroll(continuous: Bool, phase: UInt8, momentum: UInt8, dy: Int32, dx: Int32, flags: UInt32)
    case key(code: UInt16, down: Bool, isRepeat: Bool, keyboardType: UInt8, flags: UInt32)
    case reset

    init?(type: MessageType, payload p: Data) {
        switch type {
        case .inputMove:
            guard p.count >= 12, let seq = p.readBE(UInt32.self, at: 0),
                  let dx = p.readBE(UInt16.self, at: 4), let dy = p.readBE(UInt16.self, at: 6),
                  let flags = p.readBE(UInt32.self, at: 8) else { return nil }
            self = .move(seq: seq, dx: Int16(bitPattern: dx), dy: Int16(bitPattern: dy), flags: flags)
        case .inputButton:
            guard p.count >= 7, let flags = p.readBE(UInt32.self, at: 3) else { return nil }
            let b = p[p.startIndex], down = p[p.startIndex + 1], clicks = p[p.startIndex + 2]
            guard b < 32 else { return nil }
            self = .button(button: b, down: down != 0, clicks: min(clicks, 3), flags: flags)
        case .inputScroll:
            guard p.count >= 15, let dy = p.readBE(UInt32.self, at: 3), let dx = p.readBE(UInt32.self, at: 7),
                  let flags = p.readBE(UInt32.self, at: 11) else { return nil }
            func clamp(_ v: UInt32) -> Int32 { max(-10_000, min(10_000, Int32(bitPattern: v))) }
            self = .scroll(continuous: p[p.startIndex] != 0, phase: p[p.startIndex + 1],
                           momentum: p[p.startIndex + 2], dy: clamp(dy), dx: clamp(dx), flags: flags)
        case .inputKey:
            guard p.count >= 8, let code = p.readBE(UInt16.self, at: 0), code <= 0x7F,
                  let flags = p.readBE(UInt32.self, at: 4) else { return nil }
            let bits = p[p.startIndex + 2]
            self = .key(code: code, down: bits & 1 != 0, isRepeat: bits & 2 != 0,
                        keyboardType: p[p.startIndex + 3], flags: flags)
        case .inputReset:
            self = .reset
        default:
            return nil
        }
    }
}

/// HELLO sent by the viewer right after the TCP connection is accepted.
struct ViewerHello: Decodable {
    let proto: Int
    let name: String
    let width: Int
    let height: Int
    let scale: Double?
    let os: String?
    /// Optional capabilities, e.g. "cursor" = the viewer draws the mouse pointer itself.
    let features: [String]?
    /// Protocol 2: the viewer's stable identifier and a fresh random nonce (hex).
    let id: String?
    let nonce: String?
}

/// Decoder statistics reported by the viewer.
struct ViewerStats: Decodable {
    let hw: Bool?          // hardware H.264 decoder in use
    let decodeMs: Double?  // average decode time per frame
    let frames: Int?       // frames decoded in the last interval
}

/// Makes a name received from the network safe to show in menus and System Settings:
/// no control/format characters (incl. bidi overrides), at most 64 characters.
func sanitizedName(_ raw: String, fallback: String = "Old Mac") -> String {
    let scalars = raw.unicodeScalars.filter { scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
            return false
        default:
            return true
        }
    }
    var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    if name.count > 64 { name = String(name.prefix(64)) + "…" }
    return name.isEmpty ? fallback : name
}

/// HELLO sent by the host.
struct HostHello: Encodable {
    let proto: Int
    let name: String
    let id: String
    let nonce: String      // hex, fresh for every connection
    let encrypt: Bool      // ask the viewer for an encrypted session
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    func readBE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var value: T = 0
        for i in 0..<size {
            value = (value << 8) | T(truncatingIfNeeded: self[startIndex + offset + i])
        }
        return value
    }
}

func makeMessage(_ type: MessageType, _ payload: Data = Data()) -> Data {
    var d = Data(capacity: 5 + payload.count)
    d.append(type.rawValue)
    d.appendBE(UInt32(payload.count))
    d.append(payload)
    return d
}

func monotonicMicros() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1000
}
