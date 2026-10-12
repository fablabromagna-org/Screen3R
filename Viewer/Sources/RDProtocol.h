//
//  RDProtocol.h
//  Screen3R Viewer
//
//  Wire protocol shared with the host. See PROTOCOL.md.
//  Every message: [u8 type][u32 BE payload length][payload]
//

#ifndef RDProtocol_h
#define RDProtocol_h

#define RD_SERVICE_TYPE      @"_screen3r._tcp."
#define RD_PORT              52020
#define RD_PROTOCOL_VERSION  2
#define RD_MAX_MESSAGE       (16u * 1024u * 1024u)

typedef enum : uint8_t {
    RDMsgHello           = 0x01,  // both directions, JSON
    RDMsgFormat          = 0x02,  // host -> viewer: H.264 parameter sets
    RDMsgFrame           = 0x03,  // host -> viewer: one encoded frame
    RDMsgKeyframeRequest = 0x04,  // viewer -> host
    RDMsgAck             = 0x05,  // viewer -> host: u32 seq
    RDMsgPing            = 0x06,  // host -> viewer: u64
    RDMsgPong            = 0x07,  // viewer -> host: echo
    RDMsgCursorPosition  = 0x08,  // host -> viewer: i16 x, i16 y, u8 flags (bit 0 = visible)
    RDMsgCursorImage     = 0x09,  // host -> viewer: u16 w, u16 h, u16 hotX, u16 hotY (points), u16 pixelW, u16 pixelH + raw BGRA
    RDMsgViewerStats     = 0x0A,  // viewer -> host: JSON {"hw":bool,"decodeMs":n,"frames":n}
    // Pairing and authentication (protocol 2), see PROTOCOL.md
    RDMsgPairCommit      = 0x0B,  // host -> viewer: SHA-256 commitment to the host's public key
    RDMsgPairKey         = 0x0C,  // both: 65-byte P-256 public key
    RDMsgPairConfirm     = 0x0D,  // both: 32-byte proof of the new pairing key
    RDMsgAuth            = 0x0E,  // both: 32-byte proof of the stored pairing key
    RDMsgNeedPairing     = 0x0F,  // viewer -> host: no (valid) pairing for this host
    RDMsgSecure          = 0x10,  // both: encrypted envelope around one inner message
    // Keyboard & mouse of this Mac (feature "input"), only in encrypted sessions
    RDMsgInputControl    = 0x11,  // host -> viewer: u8 flags (bit 0 = input accepted)
    RDMsgInputMove       = 0x12,  // viewer -> host: u32 seq, i16 dx, i16 dy (stream pixels), u32 modifier flags
    RDMsgInputButton     = 0x13,  // viewer -> host: u8 button, u8 down, u8 clickCount, u32 modifier flags
    RDMsgInputScroll     = 0x14,  // viewer -> host: u8 continuous, u8 phase, u8 momentumPhase, i32 dy, i32 dx, u32 flags
    RDMsgInputKey        = 0x15,  // viewer -> host: u16 keyCode, u8 bits (0 = down, 1 = repeat), u8 keyboardType, u32 flags
    RDMsgInputReset      = 0x16,  // viewer -> host: release every key and button held
    RDMsgCue             = 0x17,  // host -> viewer: u8 cue, at most once per session
} RDMessageType;

#endif
