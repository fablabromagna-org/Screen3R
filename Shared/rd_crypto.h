//
//  rd_crypto.h
//  Screen3R — shared by the host (Swift, via the bridging header) and the viewer (ObjC).
//
//  One C implementation on both sides, so the two apps can never disagree on the
//  crypto. Uses only CommonCrypto and Security.framework APIs available on macOS 10.13.
//
//  Pairing (first connection): ephemeral P-256 ECDH with a commitment, then both Macs
//  show the same 6-digit code and the user confirms on the host that they match
//  (numeric comparison, as in Bluetooth pairing). Result: a 256-bit pairing key stored
//  on both Macs.
//
//  Every session: mutual proof of the pairing key (HMAC over both random nonces), then
//  optional encryption: AES-128-CTR + HMAC-SHA256 (encrypt-then-MAC), one key set per
//  direction, strictly increasing message counters (no replay, no reordering).
//

#ifndef RD_CRYPTO_H
#define RD_CRYPTO_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RD_KEY_LEN      32
#define RD_HASH_LEN     32
#define RD_PUBKEY_LEN   65   // uncompressed P-256 point: 0x04 || X || Y
#define RD_NONCE_LEN    16
#define RD_TAG_LEN      16
#define RD_SEAL_OVERHEAD (8 + RD_TAG_LEN)   // counter + tag

// --- primitives -----------------------------------------------------------------
void rd_sha256(const void *data, size_t len, uint8_t out[RD_HASH_LEN]);
void rd_hmac_sha256(const uint8_t *key, size_t keyLen, const void *data, size_t len,
                    uint8_t out[RD_HASH_LEN]);
/// HKDF-SHA256 (RFC 5869). outLen <= 255 * 32.
void rd_hkdf_sha256(const uint8_t *ikm, size_t ikmLen, const uint8_t *salt, size_t saltLen,
                    const char *info, uint8_t *out, size_t outLen);
bool rd_random(void *buf, size_t len);
/// Constant-time comparison.
bool rd_equal(const uint8_t *a, const uint8_t *b, size_t len);

// --- pairing --------------------------------------------------------------------
/// Commitment the host sends before seeing the viewer's key: SHA-256(pkHost).
void rd_pair_commitment(const uint8_t pkHost[RD_PUBKEY_LEN], uint8_t out[RD_HASH_LEN]);
/// Binds both identities and both public keys.
void rd_pair_transcript(const char *hostID, const char *viewerID,
                        const uint8_t pkHost[RD_PUBKEY_LEN], const uint8_t pkViewer[RD_PUBKEY_LEN],
                        uint8_t out[RD_HASH_LEN]);
/// Pairing key from the ECDH shared secret.
void rd_pair_key(const uint8_t *sharedSecret, size_t sharedLen, const uint8_t transcript[RD_HASH_LEN],
                 uint8_t outKey[RD_KEY_LEN]);
/// 6-digit code (0...999999) both Macs show.
uint32_t rd_pair_code(const uint8_t key[RD_KEY_LEN], const uint8_t transcript[RD_HASH_LEN]);
/// Proof that the sender holds the pairing key (sent after the user confirmed the code).
void rd_pair_confirm(const uint8_t key[RD_KEY_LEN], const uint8_t transcript[RD_HASH_LEN],
                     bool fromHost, uint8_t out[RD_HASH_LEN]);

// --- sessions -------------------------------------------------------------------
/// `encrypt` is the host's choice from its HELLO: binding it here means nobody in the middle
/// can change it without the authentication failing.
void rd_session_transcript(const char *hostID, const char *viewerID,
                           const uint8_t nonceHost[RD_NONCE_LEN], const uint8_t nonceViewer[RD_NONCE_LEN],
                           bool encrypt, uint8_t out[RD_HASH_LEN]);
void rd_session_proof(const uint8_t key[RD_KEY_LEN], const uint8_t transcript[RD_HASH_LEN],
                      bool fromHost, uint8_t out[RD_HASH_LEN]);

typedef struct {
    uint8_t encKey[16];
    uint8_t macKey[32];
    uint64_t counter;      // last counter sent / received
} rd_channel;

/// Derives the two directions. The host's `send` is the viewer's `recv` and vice versa.
void rd_session_channels(const uint8_t key[RD_KEY_LEN], const uint8_t transcript[RD_HASH_LEN],
                         bool isHost, rd_channel *send, rd_channel *recv);

/// Encrypts and authenticates. `out` must hold len + RD_SEAL_OVERHEAD bytes.
/// Layout: u64 counter (BE) || AES-128-CTR ciphertext || HMAC-SHA256(counter||ciphertext)[0..16].
bool rd_seal(rd_channel *ch, const uint8_t *plain, size_t len, uint8_t *out);
/// Verifies and decrypts. Requires counter == last + 1. `out` must hold inLen - RD_SEAL_OVERHEAD.
bool rd_open(rd_channel *ch, const uint8_t *in, size_t inLen, uint8_t *out, size_t *outLen);

// --- ECDH (Security.framework, macOS 10.12+) --------------------------------------
typedef struct rd_ecdh rd_ecdh;
/// New ephemeral P-256 key pair; writes the public key. NULL on failure.
rd_ecdh *rd_ecdh_create(uint8_t pubOut[RD_PUBKEY_LEN]);
/// Shared secret (32 bytes, X coordinate) with the peer's public key.
bool rd_ecdh_shared(const rd_ecdh *e, const uint8_t peerPub[RD_PUBKEY_LEN], uint8_t zOut[32]);
void rd_ecdh_free(rd_ecdh *e);

#ifdef __cplusplus
}
#endif

#endif
