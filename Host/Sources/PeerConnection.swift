//
//  PeerConnection.swift
//  Screen3R (host)
//
//  TCP connection to one viewer: framing, keep-alive, acknowledgements, stats, and the
//  security handshake (protocol 2):
//
//    host                                   viewer
//    HELLO {id, nonce, encrypt} ───────▶  ◀─────── HELLO {id, nonce, name, size…}
//    known viewer:   AUTH(proof) ──────▶  ◀─────── AUTH(proof)       → session
//                                          ◀─────── NEED_PAIRING     → pairing ↓
//    pairing:  PAIR_COMMIT(H(pk)) ─────▶  ◀─────── PAIR_KEY(pkV)
//              PAIR_KEY(pkH) ──────────▶            both show the same 6-digit code
//    user confirms: PAIR_CONFIRM ──────▶  ◀─────── PAIR_CONFIRM      → session
//
//  Once the session starts (and if encryption is on), every message in both directions
//  travels inside SECURE envelopes (Shared/rd_crypto.c).
//

import Foundation
import Network
import CoreGraphics

// Thread safety is handled by hand: `queue` + `lock` + `sendLock` (see comments).
final class PeerConnection: @unchecked Sendable {
    struct Stats {
        let fps: Int
        let mbps: Double
        let rttMs: Double
        let viewer: ViewerStats?
        let encrypted: Bool
    }

    let displayName: String
    /// Resolved once on the main thread: Host.current() can be slow (reverse DNS).
    private let localName = Host.current().localizedName ?? "Mac"
    private let hostID = HostIdentity.id
    /// This session is (or will be, once authenticated) encrypted.
    let encrypt: Bool

    /// All callbacks are delivered on the main queue.
    /// Called once the viewer is authenticated (known pairing, or a new pairing confirmed).
    var onHello: ((ViewerHello) -> Void)?
    var onClosed: ((String?) -> Void)?
    var onStats: ((Stats) -> Void)?
    /// New pairing: show `code`, call `decide(true)` if the viewer shows the same code.
    var onPairingCode: ((_ code: String, _ viewerName: String, _ decide: @escaping (Bool) -> Void) -> Void)?
    /// Delivered on the network queue.
    var onKeyframeRequest: (() -> Void)?
    /// Keyboard/mouse events from the old Mac, only while input is enabled. Network queue.
    /// `.reset` is also delivered when input is switched off or the connection closes.
    var onInput: ((InputEvent) -> Void)?

    /// Frames sent but not yet acknowledged before we start skipping captured frames.
    /// Kept small: every queued frame is latency (and delays cursor messages behind it).
    var maxInFlight: UInt32 = 2

    private enum HandshakeState {
        case awaitHello, awaitKey, awaitAuth, pairAwaitKey, pairAwaitUser, pairAwaitConfirm, ready
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "screen3r.net", qos: .userInteractive)

    private let lock = NSLock()
    private var sentSeq: UInt32 = 0     // guarded by lock
    private var ackedSeq: UInt32 = 0    // guarded by lock
    private var statBytes = 0           // guarded by lock
    private var statFrames = 0          // guarded by lock

    // Sealing must happen in the same order as sending: one lock around both.
    private let sendLock = NSLock()
    private var sendChannel: SecureChannel?    // guarded by sendLock

    // Only touched on `queue`.
    private var closed = false
    private var lastReceive = DispatchTime.now()
    private var timer: DispatchSourceTimer?
    private var rttMs: Double = 0
    private var viewerStats: ViewerStats?
    private var state = HandshakeState.awaitHello
    private var hello: ViewerHello?
    private var viewerID = ""
    private var nonceHost = Data()
    private var nonceViewer = Data()
    private var ecdh: ECDHKeyPair?
    private var pairTranscript = Data()
    private var pairKey = Data()
    private var authKey: Data?          // stored pairing key, read once per connection
    private var pairingStarted: DispatchTime?   // handshake (then pairing) start, for the timeout
    private var recvChannel: SecureChannel?
    private var inputEnabled = false
    private var inputControlSent = false

    init(endpoint: NWEndpoint, displayName: String, encrypt: Bool) {
        self.displayName = displayName
        self.encrypt = encrypt
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        connection = NWConnection(to: endpoint, using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.didBecomeReady()
            case .waiting(let error):
                self.close(reason: "Cannot reach \(self.displayName): \(error.localizedDescription)")
            case .failed(let error):
                self.close(reason: "Connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.close(reason: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// User-initiated disconnect. `onClosed` is still called (with nil).
    func cancel() {
        queue.async { self.close(reason: nil) }
    }

    // MARK: - Sending (callable from any thread)

    func canSendFrame() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sentSeq &- ackedSeq < maxInFlight
    }

    func sendFormat(_ parameterSets: [Data], nalLength: Int32) {
        var payload = Data()
        payload.append(UInt8(truncatingIfNeeded: nalLength))
        payload.append(UInt8(parameterSets.count))
        for set in parameterSets {
            payload.appendBE(UInt16(set.count))
            payload.append(set)
        }
        send(.format, payload)
    }

    func sendFrame(_ avcc: Data, keyframe: Bool) {
        lock.lock()
        sentSeq &+= 1
        let seq = sentSeq
        statFrames += 1
        statBytes += avcc.count
        lock.unlock()

        var payload = Data(capacity: 13 + avcc.count)
        payload.append(keyframe ? 1 : 0)
        payload.appendBE(seq)
        payload.appendBE(monotonicMicros())
        payload.append(avcc)
        send(.frame, payload)
    }

    /// `inputSeq`: the last movement of the old Mac's mouse included in this position
    /// (viewers that predict the pointer locally use it; older viewers ignore the extra bytes).
    func sendCursorPosition(x: Int16, y: Int16, visible: Bool, inputSeq: UInt32) {
        var payload = Data(capacity: 9)
        payload.appendBE(UInt16(bitPattern: x))
        payload.appendBE(UInt16(bitPattern: y))
        payload.append(visible ? 1 : 0)
        payload.appendBE(inputSeq)
        send(.cursorPosition, payload)
    }

    /// Accept (or stop accepting) the old Mac's keyboard and mouse. Only possible in an
    /// encrypted session with a viewer that supports it: without encryption anyone on the
    /// network could inject keystrokes into the connection. Any thread.
    func setInputEnabled(_ wanted: Bool) {
        queue.async { [weak self] in
            guard let self, !self.closed, self.state == .ready else { return }
            let supported = self.hello?.features?.contains("input") ?? false
            let enabled = wanted && supported && self.recvChannel != nil
            guard enabled != self.inputEnabled || !self.inputControlSent else { return }
            if self.inputEnabled && !enabled { self.onInput?(.reset) }
            self.inputEnabled = enabled
            self.inputControlSent = true
            if supported { self.send(.inputControl, Data([enabled ? 1 : 0])) }
        }
    }

    /// Raw BGRA pixels; `size` and `hotSpot` in points (hot spot from the top-left corner).
    func sendCursorImage(_ cursor: CursorTracker.CursorImage) {
        func u16(_ v: CGFloat) -> UInt16 { UInt16(clamping: Int(v.rounded())) }
        var payload = Data(capacity: 12 + cursor.pixels.count)
        payload.appendBE(u16(cursor.size.width))
        payload.appendBE(u16(cursor.size.height))
        payload.appendBE(u16(cursor.hotSpot.x))
        payload.appendBE(u16(cursor.hotSpot.y))
        payload.appendBE(UInt16(clamping: cursor.pixelWidth))
        payload.appendBE(UInt16(clamping: cursor.pixelHeight))
        payload.append(cursor.pixels)
        send(.cursorImage, payload)
    }

    /// Frames, seals (once the session is encrypted) and sends one message.
    private func send(_ type: MessageType, _ payload: Data = Data()) {
        sendLock.lock()
        defer { sendLock.unlock() }
        let message: Data
        if var ch = sendChannel {
            var inner = Data(capacity: 1 + payload.count)
            inner.append(type.rawValue)
            inner.append(payload)
            guard let sealed = ch.seal(inner) else {
                queue.async { self.close(reason: "Encryption failed.") }
                return
            }
            sendChannel = ch
            message = makeMessage(.secure, sealed)
        } else {
            message = makeMessage(type, payload)
        }
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            if let error, let self {
                self.queue.async { self.close(reason: "Send failed: \(error.localizedDescription)") }
            }
        })
    }

    // MARK: - Lifecycle (on `queue`)

    private func didBecomeReady() {
        lastReceive = .now()
        pairingStarted = .now()
        guard let nonce = RDCrypto.random(RDCrypto.nonceLength) else {
            close(reason: "No random numbers available.")
            return
        }
        nonceHost = nonce
        let hello = HostHello(proto: RD.protocolVersion, name: localName, id: hostID,
                              nonce: RDCrypto.hex(nonce), encrypt: encrypt)
        if let json = try? JSONEncoder().encode(hello) {
            send(.hello, json)
        }
        receiveHeader()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !closed else { return }
        if DispatchTime.now().uptimeNanoseconds - lastReceive.uptimeNanoseconds > 6_000_000_000 {
            close(reason: "\(displayName) stopped responding.")
            return
        }
        if let started = pairingStarted, state != .ready,
           DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds > 120_000_000_000 {
            let pairing = state != .awaitHello && state != .awaitKey && state != .awaitAuth
            close(reason: pairing ? "Pairing timed out." : "\(displayName) did not complete the connection.")
            return
        }
        var ping = Data()
        ping.appendBE(monotonicMicros())
        send(.ping, ping)

        lock.lock()
        let frames = statFrames, bytes = statBytes
        statFrames = 0; statBytes = 0
        lock.unlock()
        let stats = Stats(fps: frames, mbps: Double(bytes) * 8 / 1_000_000, rttMs: rttMs,
                          viewer: viewerStats, encrypted: recvChannel != nil)
        DispatchQueue.main.async { self.onStats?(stats) }
    }

    private func close(reason: String?) {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        ecdh = nil
        pairKey = Data()
        authKey = nil
        if inputEnabled {
            inputEnabled = false
            onInput?(.reset)   // nothing stays pressed on this Mac
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        DispatchQueue.main.async { self.onClosed?(reason) }
    }

    // MARK: - Receiving (on `queue`)

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error {
                self.close(reason: "Connection lost: \(error.localizedDescription)")
                return
            }
            guard let data, data.count == 5,
                  let length = data.readBE(UInt32.self, at: 1) else {
                // Never leave the connection without a pending receive.
                self.close(reason: isComplete ? "\(self.displayName) closed the connection." : "Protocol error.")
                return
            }
            let type = data[data.startIndex]
            let size = Int(length)
            guard size <= RD.maxViewerMessageSize else {
                self.close(reason: "Protocol error (message too large).")
                return
            }
            if size == 0 {
                self.receive(type: type, payload: Data())
                if !self.closed { self.receiveHeader() }
            } else {
                self.receivePayload(type: type, size: size)
            }
        }
    }

    private func receivePayload(type: UInt8, size: Int) {
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let error {
                self.close(reason: "Connection lost: \(error.localizedDescription)")
                return
            }
            guard let data, data.count == size else {
                self.close(reason: "\(self.displayName) closed the connection.")
                return
            }
            self.receive(type: type, payload: data)
            if !self.closed { self.receiveHeader() }
        }
    }

    /// Unwraps SECURE envelopes, then dispatches.
    private func receive(type rawType: UInt8, payload: Data) {
        lastReceive = .now()
        if rawType == MessageType.secure.rawValue {
            guard var channel = recvChannel, let inner = channel.open(payload), let innerType = inner.first,
                  innerType != MessageType.secure.rawValue else {
                close(reason: "A message from \(displayName) failed authentication.")
                return
            }
            recvChannel = channel
            handle(type: innerType, payload: Data(inner.dropFirst()))
        } else if recvChannel != nil {
            close(reason: "\(displayName) sent unencrypted data in an encrypted session.")
        } else {
            handle(type: rawType, payload: payload)
        }
    }

    private func handle(type rawType: UInt8, payload: Data) {
        guard let type = MessageType(rawValue: rawType) else {
            // Unknown types are ignored once the session runs (forward compat), never before.
            if state != .ready { close(reason: "Protocol error during the security handshake.") }
            return
        }

        if type == .pong {
            if let t = payload.readBE(UInt64.self, at: 0) {
                let now = monotonicMicros()
                if now >= t { rttMs = Double(now - t) / 1000 }
            }
            return
        }
        guard state == .ready else {
            handleHandshake(type, payload)
            return
        }

        switch type {
        case .ack:
            if let seq = payload.readBE(UInt32.self, at: 0) {
                lock.lock()
                // Acks arrive in order; guard against anything odd anyway.
                if seq &- ackedSeq <= sentSeq &- ackedSeq { ackedSeq = seq }
                lock.unlock()
            }
        case .keyframeRequest:
            onKeyframeRequest?()
        case .viewerStats:
            if let stats = try? JSONDecoder().decode(ViewerStats.self, from: payload) {
                viewerStats = stats
            }
        case .inputMove, .inputButton, .inputScroll, .inputKey, .inputReset:
            // Ignored unless the user turned the feature on and the session is encrypted.
            guard inputEnabled, recvChannel != nil, let event = InputEvent(type: type, payload: payload) else { return }
            onInput?(event)
        default:
            break // not expected from a viewer once the session runs
        }
    }

    // MARK: - Handshake (on `queue`)

    private func handleHandshake(_ type: MessageType, _ payload: Data) {
        switch (state, type) {
        case (.awaitHello, .hello):
            guard let hello = try? JSONDecoder().decode(ViewerHello.self, from: payload) else {
                close(reason: "Invalid HELLO from viewer.")
                return
            }
            guard hello.proto == RD.protocolVersion else {
                close(reason: "The viewer runs a different version of Screen3R (protocol \(hello.proto), this app \(RD.protocolVersion)). Update both apps.")
                return
            }
            guard let id = hello.id, RDCrypto.isValidID(id),
                  let nonce = hello.nonce.flatMap({ RDCrypto.unhex($0, length: RDCrypto.nonceLength) }) else {
                close(reason: "Invalid HELLO from viewer.")
                return
            }
            self.hello = hello
            viewerID = id
            nonceViewer = nonce
            // After an update (new signature) macOS may ask whether Screen3R may read its keychain
            // item, and SecItemCopyMatching waits for the answer. Never on this queue: keep-alive
            // pings would stop and the viewer would hang up after 6 s.
            state = .awaitKey
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let key = PairingKeychain.key(for: id)
                self?.queue.async { self?.keyLookedUp(key) }
            }

        case (.awaitAuth, .auth):
            guard let key = authKey,
                  RDCrypto.equal(payload, RDCrypto.sessionProof(key: key, transcript: sessionTranscript(), fromHost: false))
            else {
                close(reason: "\(displayName) could not prove it is the paired screen.")
                return
            }
            startSession(key: key)

        case (.awaitAuth, .needPairing):
            authKey = nil
            startPairing()   // the viewer forgot us (or never knew us): pair again, with the user's consent

        case (.pairAwaitKey, .pairKey):
            guard let ecdh, payload.count == RDCrypto.publicKeyLength,
                  let z = ecdh.sharedSecret(with: payload) else {
                close(reason: "Pairing failed (invalid key).")
                return
            }
            send(.pairKey, ecdh.publicKey)
            pairTranscript = RDCrypto.pairTranscript(hostID: hostID, viewerID: viewerID,
                                                     pkHost: ecdh.publicKey, pkViewer: payload)
            pairKey = RDCrypto.pairKey(sharedSecret: z, transcript: pairTranscript)
            self.ecdh = nil
            let code = RDCrypto.pairCode(key: pairKey, transcript: pairTranscript)
            let text = String(format: "%03u %03u", code / 1000, code % 1000)
            let name = sanitizedName(hello?.name ?? displayName)
            state = .pairAwaitUser
            // Strong capture is fine: this block runs once; the decision callback below is weak.
            DispatchQueue.main.async { [self] in
                self.onPairingCode?(text, name) { [weak self] accepted in
                    self?.queue.async { self?.userDecided(accepted) }
                }
            }

        case (.pairAwaitConfirm, .pairConfirm):
            let expected = RDCrypto.pairConfirm(key: pairKey, transcript: pairTranscript, fromHost: false)
            guard RDCrypto.equal(payload, expected) else {
                close(reason: "Pairing failed (wrong confirmation).")
                return
            }
            // Off this queue as well: replacing an item written by an older build may ask too.
            let (key, id, name) = (pairKey, viewerID, sanitizedName(hello?.name ?? displayName))
            DispatchQueue.global(qos: .userInitiated).async { PairingKeychain.store(key, for: id, name: name) }
            startSession(key: pairKey)

        default:
            close(reason: "Protocol error during the security handshake.")
        }
    }

    /// The stored pairing key for this viewer (or nil): prove it, or pair.
    private func keyLookedUp(_ key: Data?) {
        guard !closed, state == .awaitKey else { return }
        if let key {
            authKey = key
            let proof = RDCrypto.sessionProof(key: key, transcript: sessionTranscript(), fromHost: true)
            state = .awaitAuth
            send(.auth, proof)
        } else {
            startPairing()
        }
    }

    private func sessionTranscript() -> Data {
        RDCrypto.sessionTranscript(hostID: hostID, viewerID: viewerID, nonceHost: nonceHost, nonceViewer: nonceViewer,
                                   encrypt: encrypt)
    }

    private func startPairing() {
        guard let key = ECDHKeyPair() else {
            close(reason: "Pairing failed (no key).")
            return
        }
        ecdh = key
        pairingStarted = .now()
        state = .pairAwaitKey
        send(.pairCommit, RDCrypto.commitment(key.publicKey))
    }

    private func userDecided(_ accepted: Bool) {
        guard !closed, state == .pairAwaitUser else { return }
        guard accepted else {
            close(reason: "Pairing cancelled: the codes did not match.")
            return
        }
        state = .pairAwaitConfirm
        send(.pairConfirm, RDCrypto.pairConfirm(key: pairKey, transcript: pairTranscript, fromHost: true))
    }

    /// The viewer has proven it holds the pairing key: switch on encryption and start streaming.
    private func startSession(key: Data) {
        if encrypt {
            let channels = SecureChannel.pair(key: key, transcript: sessionTranscript())
            recvChannel = channels.recv
            sendLock.lock()
            sendChannel = channels.send
            sendLock.unlock()
        }
        pairKey = Data()
        authKey = nil
        pairingStarted = nil
        state = .ready
        guard let hello else { return }
        DispatchQueue.main.async { self.onHello?(hello) }
    }
}
