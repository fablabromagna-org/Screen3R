# Screen3R wire protocol (v2)

One TCP connection. The **viewer** (old Mac) listens on port **52020** and advertises
`_screen3r._tcp` via Bonjour; the **host** (new Mac, or a PC running Screen3R for Windows) connects.

Every message is:

```
u8   type
u32  payload length (big-endian)
...  payload
```

All integers are big-endian. Unknown message types are ignored once a session is running.

| Type | Name | Direction | Payload |
|-----:|------|-----------|---------|
| 0x01 | HELLO | both | UTF-8 JSON (see below) |
| 0x02 | FORMAT | host → viewer | `u8 nalLengthSize`, `u8 count`, then `count` × (`u16 len`, `len` bytes): H.264 SPS/PPS |
| 0x03 | FRAME | host → viewer | `u8 flags` (bit 0 = keyframe), `u32 seq`, `u64 hostTimeMicros`, then the frame in AVCC format (NAL units prefixed by `nalLengthSize`-byte lengths) |
| 0x04 | KEYFRAME_REQUEST | viewer → host | empty |
| 0x05 | ACK | viewer → host | `u32 seq` of a FRAME received |
| 0x06 | PING | host → viewer | `u64` opaque |
| 0x07 | PONG | viewer → host | the PING payload, echoed |
| 0x08 | CURSOR_POSITION | host → viewer | `i16 x`, `i16 y` (stream pixels, origin top-left), `u8 flags` (bit 0 = visible on this display), then (newer hosts) `u32 inputSeq`: the last INPUT_MOVE included in this position |
| 0x09 | CURSOR_IMAGE | host → viewer | `u16 width`, `u16 height`, `u16 hotX`, `u16 hotY` (points, hot spot from top-left), `u16 pixelWidth`, `u16 pixelHeight`, then `pixelWidth × pixelHeight × 4` bytes of BGRA, premultiplied alpha, top row first (raw pixels on purpose: no image decoder runs on network data). Max 256×256. Sent only while the pointer is on the virtual display. |
| 0x0A | VIEWER_STATS | viewer → host | UTF-8 JSON, about once a second: `{"hw":true,"decodeMs":6.2,"frames":58}` (all fields optional) |
| 0x0B | PAIR_COMMIT | host → viewer | 32 bytes: SHA-256("Screen3R commit v1" ‖ pkHost) |
| 0x0C | PAIR_KEY | both | 65 bytes: ephemeral P-256 public key, uncompressed |
| 0x0D | PAIR_CONFIRM | both | 32 bytes: HMAC proof of the new pairing key |
| 0x0E | AUTH | both | 32 bytes: HMAC proof of the stored pairing key |
| 0x0F | NEED_PAIRING | viewer → host | empty: no valid pairing for this host |
| 0x10 | SECURE | both | sealed inner message (see *Encryption*) |
| 0x11 | INPUT_CONTROL | host → viewer | `u8 flags`: bit 0 = the host accepts the viewer's keyboard and mouse |
| 0x12 | INPUT_MOVE | viewer → host | `u32 seq`, `i16 dx`, `i16 dy` (stream pixels, y down), `u32 modifierFlags` |
| 0x13 | INPUT_BUTTON | viewer → host | `u8 button` (0 left, 1 right, 2+ other), `u8 down`, `u8 clickCount`, `u32 modifierFlags` |
| 0x14 | INPUT_SCROLL | viewer → host | `u8 continuous`, `u8 scrollPhase`, `u8 momentumPhase`, `i32 dy`, `i32 dx` (pixels if continuous, else lines), `u32 modifierFlags` |
| 0x15 | INPUT_KEY | viewer → host | `u16 keyCode` (virtual key code, 0–127), `u8 bits` (bit 0 = down, bit 1 = auto-repeat), `u8 keyboardType`, `u32 modifierFlags` |
| 0x16 | INPUT_RESET | viewer → host | empty: release every key and button the viewer holds |

## Session

1. Viewer accepts and immediately sends HELLO:
   `{"proto":2,"id":"<viewer UUID>","nonce":"<32 hex>","name":"iMac di Riccardo","width":1920,"height":1080,"scale":1,"os":"10.13.6","features":["cursor","input"],"keyboardLayout":"iso"}`
   (`width`/`height` in points; always a 1× display for now.)
   `keyboardLayout` (optional, v0.4+): `"ansi"`, `"iso"` or `"jis"`, the layout type of the viewer's
   keyboard. Mac hosts get it from the key events themselves; other hosts need it to map the keys
   next to the left Shift and below Esc, which macOS reports swapped on ISO keyboards.
   `features` is optional. `"cursor"` means the viewer draws the mouse pointer itself: the host then
   leaves the pointer out of the video and sends CURSOR_POSITION (polled every 8 ms, sent on change and
   at least once a second) and CURSOR_IMAGE (on change) instead. `"input"` means the viewer can send its
   keyboard and mouse (see *Keyboard and mouse*).
2. Host sends HELLO: `{"proto":2,"id":"<host UUID>","nonce":"<32 hex>","name":"MacBook Pro","encrypt":true}`.
3. **Authentication** (see below). Until it succeeds, only HELLO, PING/PONG and the handshake
   messages are accepted; anything else (unknown types included) closes the connection. The handshake
   must complete within 120 s (a pairing gets 120 s from PAIR_COMMIT).
4. The host creates a virtual display of the viewer's size and starts streaming.
5. Every keyframe is preceded by a FORMAT message. The viewer drops frames until it has a format and a keyframe, and asks for a keyframe (at most every 500 ms) when it needs one.
6. Flow control: the viewer ACKs **every** FRAME, even ones it drops, after it has been decoded (so the ACK rate follows the viewer's real decoding speed). The host keeps at most 2 frames un-ACKed and skips captured frames (before encoding) when the limit is reached.
7. Keep-alive: the host sends PING every second. Either side closes the connection after 6 s without receiving anything.

## Authentication and pairing

All crypto is in `Shared/rd_crypto.c`, compiled into both apps (CommonCrypto and Security.framework,
available on macOS 10.13). `‖` is concatenation; strings in transcripts are length-prefixed (u16).

**Known viewer** — both sides hold a 32-byte pairing key `K`:

```
T = SHA-256("Screen3R session v1" ‖ hostID ‖ viewerID ‖ nonceHost ‖ nonceViewer ‖ encrypt)
    (encrypt = the host's choice from its HELLO, 1 byte: changing it breaks the proofs)
host   → AUTH  HMAC-SHA256(K, "Screen3R auth host"   ‖ T)
viewer → AUTH  HMAC-SHA256(K, "Screen3R auth viewer" ‖ T)      (or NEED_PAIRING)
```

**Pairing** — when the host has no key for the viewer, or the viewer answers NEED_PAIRING:

```
host   → PAIR_COMMIT  SHA-256("Screen3R commit v1" ‖ pkH)     commits before seeing pkV
viewer → PAIR_KEY     pkV
host   → PAIR_KEY     pkH                                          viewer checks the commitment
Z = ECDH(P-256), P = SHA-256("Screen3R pair v1" ‖ hostID ‖ viewerID ‖ pkH ‖ pkV)
K = HKDF-SHA256(Z, salt P, "Screen3R pairing key v1")
code = first 8 bytes of HMAC(K, "Screen3R SAS" ‖ P) as u64, mod 1 000 000
```

Both Macs show `code`. The user confirms on the host that the codes match (numeric comparison, as in
Bluetooth pairing; the commitment stops a man in the middle from searching for colliding codes).
If at least one Mac is already paired with the viewer, the user must also press Return on the
viewer. Then:

```
host   → PAIR_CONFIRM  HMAC(K, "Screen3R pair confirm host"   ‖ P)
viewer → PAIR_CONFIRM  HMAC(K, "Screen3R pair confirm viewer" ‖ P)
```

Each side stores `K` (host: login keychain; viewer: `~/Library/Application Support/Screen3R Viewer/pairings.plist`, mode 0600).

## Encryption

If the host's HELLO says `"encrypt":true`, both sides derive, from `K` and the session transcript `T`:

```
HKDF-SHA256(K, salt T, "Screen3R channel keys v1") → 96 bytes:
  host→viewer: AES-128 key (16) ‖ HMAC key (32),  viewer→host: AES-128 key (16) ‖ HMAC key (32)
```

The viewer's AUTH / PAIR_CONFIRM is the last message it sends in clear; the host switches when it has
verified that message. From then on every message is sent as:

```
SECURE payload = counter (u64) ‖ AES-128-CTR(inner) ‖ HMAC-SHA256(counter ‖ ciphertext)[0..16]
inner          = u8 type ‖ payload of the original message
CTR IV         = counter (u64) ‖ 0 (u64)
```

Counters start at 1 and must increase by exactly 1 (no replay, no reordering). A message that fails
verification closes the connection. Only PING may still arrive in clear (sent by the host just before
it switched), and only until the first SECURE message has been received.

## Keyboard and mouse

Optional, off by default: the user turns it on in the host's menu. The host then needs the
Accessibility permission (to post events) and **only accepts input in an encrypted session**: without
encryption anyone on the network could inject keystrokes into the TCP connection. The host sends
INPUT_CONTROL after the session starts and whenever the setting changes; the viewer sends input only
while it is enabled and the session is encrypted, and the host ignores input otherwise.

- `modifierFlags` are NSEventModifierFlags / CGEventFlags (same bits): device-independent modifiers
  plus the left/right bits. The host keeps only the modifier bits. Modifier keys also arrive as
  INPUT_KEY (key down when pressed, up when released), which is what the Windows host uses.
- Keys are virtual key codes: the host's keyboard layout decides the characters. `keyboardType`
  (the viewer's CGEvent keyboard type) lets the host map ISO/JIS keys correctly. Caps Lock is not
  sent as a key, only as a flag (bit 16): the Windows host presses its own Caps Lock key before a key
  press when the states differ. The Windows host turns key codes into PC scan codes
  (`Windows/Screen3R/KeyMap.cs`).
- The mouse is relative: the host adds the movement (scaled from stream pixels to points of the
  displayed area) to the pointer position and keeps the pointer on a display, so it can leave the
  virtual display for the host's other screens.
- Pointer prediction: the viewer numbers its INPUT_MOVEs and draws the pointer at the last position
  from the host plus the movements the host has not yet included (`inputSeq` in CURSOR_POSITION).
  The host sends CURSOR_POSITION right after each injected movement.
- The host tracks the keys and buttons it pressed for the viewer and releases them on INPUT_RESET,
  when input is switched off and when the connection closes.

## Video

The video is H.264 Constrained High profile, no B-frames, keyframes only on demand. When the screen has been still for 150 ms the host re-encodes the last image once with the quantizer capped at 14 (near-lossless), so text ends up sharp.

## Limits enforced by the viewer

The viewer accepts connections only from private, link-local, unique-local or same-subnet addresses.
It closes the session if more than 8 FORMAT/FRAME messages are waiting to be decoded, if a PING
payload is larger than 64 bytes, if any message is larger than 16 MB, or larger than 64 KB before
authentication. FORMAT must use a NAL length
size of 1, 2 or 4 and describe at most 4096×2304; every FRAME must be a well-formed AVCC sequence
(length-prefixed NAL units whose lengths add up exactly). Names received from the host are stripped
of control and format characters and limited to 64 characters before being shown.

The host limits viewer messages to 64 KB and honours at most two keyframe requests per second. It
range-checks input messages (key codes 0–127, buttons 0–31, scroll deltas ±10 000) and drops them
unless input is enabled and the session is encrypted.

