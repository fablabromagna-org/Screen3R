//
//  Security.swift
//  Screen3R (host)
//
//  Thin Swift wrappers around Shared/rd_crypto.c (the same C code the viewer uses),
//  plus this Mac's identity and the pairing keys in the login keychain.
//

import Foundation
import Security

enum RDCrypto {
    static let keyLength = 32
    static let hashLength = 32
    static let publicKeyLength = 65
    static let nonceLength = 16
    static let sealOverhead = 24   // RD_SEAL_OVERHEAD: u64 counter + 16-byte tag

    static func random(_ count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { rd_random($0.baseAddress, count) }
        return ok ? data : nil
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ string: String, length: Int) -> Data? {
        guard string.count == length * 2 else { return nil }
        var data = Data(capacity: length)
        var index = string.startIndex
        for _ in 0..<length {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Identifiers are UUID strings: letters, digits and dashes, 1–64 characters.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-"
        }
    }

    /// Calls `body` with a raw pointer to the bytes of `data` (never nil, even for empty data).
    static func bytes<R>(_ data: Data, _ body: (UnsafePointer<UInt8>) -> R) -> R {
        if data.isEmpty {
            var zero: UInt8 = 0
            return body(&zero)
        }
        return data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress!) }
    }

    static func output(_ count: Int, _ body: (UnsafeMutablePointer<UInt8>) -> Void) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { body($0.bindMemory(to: UInt8.self).baseAddress!) }
        return data
    }

    // MARK: Pairing

    static func commitment(_ pkHost: Data) -> Data {
        bytes(pkHost) { pk in output(hashLength) { rd_pair_commitment(pk, $0) } }
    }

    static func pairTranscript(hostID: String, viewerID: String, pkHost: Data, pkViewer: Data) -> Data {
        bytes(pkHost) { h in bytes(pkViewer) { v in
            output(hashLength) { rd_pair_transcript(hostID, viewerID, h, v, $0) }
        } }
    }

    static func pairKey(sharedSecret: Data, transcript: Data) -> Data {
        bytes(sharedSecret) { z in bytes(transcript) { t in
            output(keyLength) { rd_pair_key(z, sharedSecret.count, t, $0) }
        } }
    }

    static func pairCode(key: Data, transcript: Data) -> UInt32 {
        bytes(key) { k in bytes(transcript) { t in rd_pair_code(k, t) } }
    }

    static func pairConfirm(key: Data, transcript: Data, fromHost: Bool) -> Data {
        bytes(key) { k in bytes(transcript) { t in output(hashLength) { rd_pair_confirm(k, t, fromHost, $0) } } }
    }

    // MARK: Sessions

    static func sessionTranscript(hostID: String, viewerID: String, nonceHost: Data, nonceViewer: Data,
                                  encrypt: Bool) -> Data {
        bytes(nonceHost) { h in bytes(nonceViewer) { v in
            output(hashLength) { rd_session_transcript(hostID, viewerID, h, v, encrypt, $0) }
        } }
    }

    static func sessionProof(key: Data, transcript: Data, fromHost: Bool) -> Data {
        bytes(key) { k in bytes(transcript) { t in output(hashLength) { rd_session_proof(k, t, fromHost, $0) } } }
    }

    static func equal(_ a: Data, _ b: Data) -> Bool {
        a.count == b.count && bytes(a) { x in bytes(b) { y in rd_equal(x, y, a.count) } }
    }
}

/// Ephemeral P-256 key pair for one pairing attempt.
final class ECDHKeyPair {
    private let handle: OpaquePointer
    let publicKey: Data

    init?() {
        var pub = Data(count: RDCrypto.publicKeyLength)
        guard let h = pub.withUnsafeMutableBytes({ rd_ecdh_create($0.bindMemory(to: UInt8.self).baseAddress!) })
        else { return nil }
        handle = h
        publicKey = pub
    }

    func sharedSecret(with peer: Data) -> Data? {
        guard peer.count == RDCrypto.publicKeyLength else { return nil }
        var z = Data(count: 32)
        let ok = RDCrypto.bytes(peer) { p in
            z.withUnsafeMutableBytes { rd_ecdh_shared(handle, p, $0.bindMemory(to: UInt8.self).baseAddress!) }
        }
        return ok ? z : nil
    }

    deinit { rd_ecdh_free(handle) }
}

/// One direction of an encrypted session (counter state included).
struct SecureChannel {
    private var raw = rd_channel()

    static func pair(key: Data, transcript: Data) -> (send: SecureChannel, recv: SecureChannel) {
        var send = SecureChannel(), recv = SecureChannel()
        RDCrypto.bytes(key) { k in RDCrypto.bytes(transcript) { t in
            rd_session_channels(k, t, true, &send.raw, &recv.raw)
        } }
        return (send, recv)
    }

    mutating func seal(_ plain: Data) -> Data? {
        var out = Data(count: plain.count + RDCrypto.sealOverhead)
        let ok = RDCrypto.bytes(plain) { p in
            out.withUnsafeMutableBytes { rd_seal(&raw, p, plain.count, $0.bindMemory(to: UInt8.self).baseAddress!) }
        }
        return ok ? out : nil
    }

    mutating func open(_ sealed: Data) -> Data? {
        guard sealed.count >= RDCrypto.sealOverhead else { return nil }
        var out = Data(count: max(1, sealed.count - RDCrypto.sealOverhead))
        var length = 0
        let ok = RDCrypto.bytes(sealed) { s in
            out.withUnsafeMutableBytes { rd_open(&raw, s, sealed.count, $0.bindMemory(to: UInt8.self).baseAddress!, &length) }
        }
        return ok ? out.prefix(length) : nil
    }
}

/// This Mac's stable identity towards viewers.
enum HostIdentity {
    static var id: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "hostID"), RDCrypto.isValidID(id) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "hostID")
        return id
    }
}

/// Pairing keys, one per viewer, in the login keychain.
enum PairingKeychain {
    private static let service = "io.github.screen3r.pairing"

    static func key(for viewerID: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: viewerID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == RDCrypto.keyLength else { return nil }
        return data
    }

    @discardableResult
    static func store(_ key: Data, for viewerID: String, name: String) -> Bool {
        remove(viewerID: viewerID)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: viewerID,
            kSecAttrLabel: "Screen3R pairing – \(name)",
            kSecValueData: key,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Screen3R: could not store pairing key (%d)", status) }
        return status == errSecSuccess
    }

    static func remove(viewerID: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: service, kSecAttrAccount: viewerID]
        for _ in 0..<16 where SecItemDelete(query as CFDictionary) == errSecSuccess {}
    }

    static func removeAll() {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        for _ in 0..<256 where SecItemDelete(query as CFDictionary) == errSecSuccess {}
    }
}
