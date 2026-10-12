#!/usr/bin/env python3
"""A simulated Screen3R viewer for testing other hosts (the Windows sender) on Linux.

It follows the viewer's side of PROTOCOL.md with the Mac apps' own C crypto
(Shared/rd_crypto.c, loaded through ctypes), so a host that passes this test speaks the
protocol byte for byte like the Mac host. Used by Tests/windows_interop.sh:

    fake_viewer.py LIB PORT STATE_FILE   -> exit 0 if the session behaved as expected
"""
import ctypes, json, os, socket, struct, sys, time

lib = ctypes.CDLL(sys.argv[1])
PORT = int(sys.argv[2])
STATE = sys.argv[3]

class Channel(ctypes.Structure):
    _fields_ = [("encKey", ctypes.c_uint8 * 16), ("macKey", ctypes.c_uint8 * 32), ("counter", ctypes.c_uint64)]

B = ctypes.c_char_p
lib.rd_ecdh_create.restype = ctypes.c_void_p
lib.rd_ecdh_shared.argtypes = [ctypes.c_void_p, B, B]
lib.rd_ecdh_shared.restype = ctypes.c_bool
lib.rd_pair_code.restype = ctypes.c_uint32
lib.rd_seal.restype = ctypes.c_bool
lib.rd_open.restype = ctypes.c_bool
lib.rd_equal.restype = ctypes.c_bool
lib.rd_session_channels.argtypes = [B, B, ctypes.c_bool, ctypes.POINTER(Channel), ctypes.POINTER(Channel)]

def out(n):
    return ctypes.create_string_buffer(n)

state = json.load(open(STATE)) if os.path.exists(STATE) else {"id": "FAKE-VIEWER-0001", "pairings": {}}

def save():
    json.dump(state, open(STATE, "w"))

def fail(msg):
    print("FAIL", msg)
    sys.exit(1)

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(1)
print("viewer listening", flush=True)
srv.settimeout(20)
conn, _ = srv.accept()
conn.settimeout(10)

def read_exact(n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf

send_ch = None   # Channel when sending is encrypted
recv_ch = None

def send(t, payload=b""):
    if send_ch is not None:
        inner = bytes([t]) + payload
        sealed = out(len(inner) + 24)
        if not lib.rd_seal(ctypes.byref(send_ch), inner, len(inner), sealed):
            fail("seal")
        conn.sendall(struct.pack(">BI", 0x10, len(inner) + 24) + sealed.raw)
    else:
        conn.sendall(struct.pack(">BI", t, len(payload)) + payload)

nonce_v = os.urandom(16)
send(0x01, json.dumps({"proto": 2, "id": state["id"], "nonce": nonce_v.hex(), "name": "Fake iMac",
                       "width": 1920, "height": 1080, "scale": 1, "os": "10.13.6",
                       "features": ["cursor", "input"], "keyboardLayout": "iso",
                       "cry": "always"}).encode())

phase = "hello"
host_id = None
encrypt = True
nonce_h = None
commitment = None
ecdh = None
pk_v = None
pair_t = None
pair_k = None
frames = 0
cues = []
cursor_pos = cursor_img = False
input_control = None
input_sent = False
got_format = False
deadline = time.time() + 20

def session_transcript():
    t = out(32)
    lib.rd_session_transcript(host_id.encode(), state["id"].encode(), nonce_h, nonce_v, encrypt, t)
    return t.raw

def start_session(key, reply_type, reply):
    global send_ch, recv_ch, phase
    conn.sendall(struct.pack(">BI", reply_type, len(reply)) + reply)   # last message in clear
    if encrypt:
        s, r = Channel(), Channel()
        lib.rd_session_channels(key, session_transcript(), False, ctypes.byref(s), ctypes.byref(r))
        send_ch, recv_ch = s, r
    phase = "ready"
    print("SESSION ready, encrypted =", encrypt, flush=True)

while time.time() < deadline:
    header = read_exact(5)
    if header is None:
        break
    t, n = struct.unpack(">BI", header)
    body = read_exact(n) if n else b""
    if body is None:
        break
    if t == 0x10:
        if recv_ch is None:
            fail("SECURE before the session")
        plain = out(max(1, n - 24))
        length = ctypes.c_size_t(0)
        if not lib.rd_open(ctypes.byref(recv_ch), body, n, plain, ctypes.byref(length)):
            fail("message failed authentication")
        inner = plain.raw[:length.value]
        t, body = inner[0], inner[1:]
    elif recv_ch is not None and not (t == 0x06 and recv_ch.counter == 0):
        fail(f"clear message 0x{t:02x} in an encrypted session")

    if t == 0x06:                      # PING
        send(0x07, body)
        continue
    if phase == "hello":
        if t != 0x01:
            fail("expected HELLO")
        hello = json.loads(body)
        host_id, encrypt = hello["id"], hello.get("encrypt", True)
        nonce_h = bytes.fromhex(hello["nonce"])
        print("HOST", hello["name"], "encrypt =", encrypt, flush=True)
        phase = "auth"
    elif phase == "auth" and t == 0x0E:     # AUTH
        key = bytes.fromhex(state["pairings"].get(host_id, "00" * 32))
        expected = out(32)
        lib.rd_session_proof(key, session_transcript(), True, expected)
        if host_id not in state["pairings"] or not lib.rd_equal(body, expected.raw, 32):
            print("AUTH unknown -> NEED_PAIRING", flush=True)
            send(0x0F)
            continue
        print("AUTH ok (known host)", flush=True)
        reply = out(32)
        lib.rd_session_proof(key, session_transcript(), False, reply)
        start_session(key, 0x0E, reply.raw)
    elif phase == "auth" and t == 0x0B:     # PAIR_COMMIT
        commitment = body
        pk = out(65)
        ecdh = lib.rd_ecdh_create(pk)
        pk_v = pk.raw
        send(0x0C, pk_v)
        phase = "pair_key"
    elif phase == "pair_key" and t == 0x0C:
        check = out(32)
        lib.rd_pair_commitment(body, check)
        if check.raw != commitment:
            fail("commitment mismatch")
        z = out(32)
        if not lib.rd_ecdh_shared(ecdh, body, z):
            fail("ECDH")
        tt, kk = out(32), out(32)
        lib.rd_pair_transcript(host_id.encode(), state["id"].encode(), body, pk_v, tt)
        lib.rd_pair_key(z, 32, tt, kk)
        pair_t, pair_k = tt.raw, kk.raw
        print(f"VIEWER CODE {lib.rd_pair_code(pair_k, pair_t):06d}", flush=True)
        phase = "pair_confirm"
    elif phase == "pair_confirm" and t == 0x0D:
        expected = out(32)
        lib.rd_pair_confirm(pair_k, pair_t, True, expected)
        if not lib.rd_equal(body, expected.raw, 32):
            fail("host confirmation invalid")
        state["pairings"][host_id] = pair_k.hex()
        save()
        reply = out(32)
        lib.rd_pair_confirm(pair_k, pair_t, False, reply)
        start_session(pair_k, 0x0D, reply.raw)
    elif phase == "ready":
        if t == 0x02:
            got_format = body[0] == 4 and body[1] == 2
        elif t == 0x03:
            seq = struct.unpack(">I", body[1:5])[0]
            avcc, off = body[13:], 0
            while off < len(avcc):
                ln = struct.unpack(">I", avcc[off:off + 4])[0]
                off += 4 + ln
            if off != len(avcc):
                fail("malformed AVCC")
            frames += 1
            send(0x05, struct.pack(">I", seq))
        elif t == 0x08:
            cursor_pos = len(body) == 9 and struct.unpack(">hhBI", body) == (100, 200, 1, 7)
        elif t == 0x09:
            cursor_img = len(body) == 12 + 16
        elif t == 0x11:
            input_control = bool(body[0] & 1)
            if input_control and encrypt and not input_sent:
                input_sent = True
                send(0x12, struct.pack(">IhhI", 1, 5, -3, 0))
                send(0x15, struct.pack(">HBBI", 0x00, 1, 41, 0))
                send(0x15, struct.pack(">HBBI", 0x00, 0, 41, 0))
                send(0x13, struct.pack(">BBBI", 0, 1, 1, 0))
                send(0x13, struct.pack(">BBBI", 0, 0, 1, 0))
                send(0x16)
        elif t == 0x17:
            cues.append(body)
        if frames >= 6 and cursor_pos and cursor_img and input_control is not None and cues and got_format:
            time.sleep(0.5)   # let the input events reach the host before closing
            break

conn.close()
ok = frames >= 6 and cursor_pos and cursor_img and got_format and cues == [b"\x01"] and \
     input_control == encrypt
print(f"VIEWER frames={frames} format={got_format} cursor={cursor_pos}/{cursor_img} cues={cues} "
      f"inputControl={input_control}", flush=True)
sys.exit(0 if ok else 1)
