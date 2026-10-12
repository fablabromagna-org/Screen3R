//
//  rd_crypto.c
//  Screen3R — see rd_crypto.h.
//
//  On Apple platforms the primitives come from CommonCrypto / Security.framework.
//  The OpenSSL branch exists only so the protocol logic can be unit-tested on Linux
//  (Tests/crypto_test.c); it is never compiled into the apps.
//

#include "rd_crypto.h"
#include <string.h>

#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonCryptor.h>
#include <Security/SecRandom.h>
#else
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#endif

/// Every domain-separation label starts with the project name (string literal concatenation).
#define RD_LABEL(x) "Screen3R " x

#pragma mark - primitives

void rd_sha256(const void *data, size_t len, uint8_t out[RD_HASH_LEN]) {
#if defined(__APPLE__)
    CC_SHA256(data, (CC_LONG)len, out);
#else
    SHA256(data, len, out);
#endif
}

void rd_hmac_sha256(const uint8_t *key, size_t keyLen, const void *data, size_t len,
                    uint8_t out[RD_HASH_LEN]) {
#if defined(__APPLE__)
    CCHmac(kCCHmacAlgSHA256, key, keyLen, data, len, out);
#else
    unsigned int outLen = RD_HASH_LEN;
    HMAC(EVP_sha256(), key, (int)keyLen, data, len, out, &outLen);
#endif
}

bool rd_random(void *buf, size_t len) {
#if defined(__APPLE__)
    return SecRandomCopyBytes(kSecRandomDefault, len, buf) == 0;
#else
    return RAND_bytes(buf, (int)len) == 1;
#endif
}

/// AES-128-CTR, big-endian 128-bit counter starting at `iv`. Same operation both ways.
static bool aes128_ctr(const uint8_t key[16], const uint8_t iv[16],
                       const uint8_t *in, size_t len, uint8_t *out) {
    if (len == 0) return true;
#if defined(__APPLE__)
    CCCryptorRef cryptor = NULL;
    if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, iv, key, 16,
                                NULL, 0, 0, kCCModeOptionCTR_BE, &cryptor) != kCCSuccess) {
        return false;
    }
    size_t moved = 0;
    CCCryptorStatus status = CCCryptorUpdate(cryptor, in, len, out, len, &moved);
    CCCryptorRelease(cryptor);
    return status == kCCSuccess && moved == len;
#else
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int outLen = 0, ok = ctx
        && EVP_EncryptInit_ex(ctx, EVP_aes_128_ctr(), NULL, key, iv) == 1
        && EVP_EncryptUpdate(ctx, out, &outLen, in, (int)len) == 1
        && (size_t)outLen == len;
    EVP_CIPHER_CTX_free(ctx);
    return ok;
#endif
}

bool rd_equal(const uint8_t *a, const uint8_t *b, size_t len) {
    uint8_t diff = 0;
    for (size_t i = 0; i < len; i++) diff |= a[i] ^ b[i];
    return diff == 0;
}

void rd_hkdf_sha256(const uint8_t *ikm, size_t ikmLen, const uint8_t *salt, size_t saltLen,
                    const char *info, uint8_t *out, size_t outLen) {
    static const uint8_t zeroSalt[RD_HASH_LEN] = {0};
    uint8_t prk[RD_HASH_LEN];
    if (!salt || saltLen == 0) { salt = zeroSalt; saltLen = sizeof(zeroSalt); }
    rd_hmac_sha256(salt, saltLen, ikm, ikmLen, prk);                       // extract

    size_t infoLen = info ? strlen(info) : 0;
    uint8_t block[RD_HASH_LEN];
    size_t blockLen = 0, done = 0;
    uint8_t counter = 1;
    uint8_t buf[RD_HASH_LEN + 256 + 1];
    if (infoLen > 256) infoLen = 256;
    while (done < outLen && counter != 0) {                                 // expand
        size_t n = 0;
        memcpy(buf + n, block, blockLen); n += blockLen;
        memcpy(buf + n, info, infoLen);   n += infoLen;
        buf[n++] = counter++;
        rd_hmac_sha256(prk, sizeof(prk), buf, n, block);
        blockLen = RD_HASH_LEN;
        size_t take = outLen - done < RD_HASH_LEN ? outLen - done : RD_HASH_LEN;
        memcpy(out + done, block, take);
        done += take;
    }
    memset(prk, 0, sizeof(prk));
    memset(block, 0, sizeof(block));
}

#pragma mark - transcripts

/// Appends a length-prefixed field (u16 BE length || bytes), so concatenations are unambiguous.
static size_t put_field(uint8_t *buf, size_t at, const void *data, size_t len) {
    buf[at] = (uint8_t)(len >> 8);
    buf[at + 1] = (uint8_t)len;
    memcpy(buf + at + 2, data, len);
    return at + 2 + len;
}

static size_t clamp_id(const char *id) {
    size_t n = id ? strlen(id) : 0;
    return n > 64 ? 64 : n;
}

void rd_pair_commitment(const uint8_t pkHost[RD_PUBKEY_LEN], uint8_t out[RD_HASH_LEN]) {
    uint8_t buf[32 + RD_PUBKEY_LEN];
    static const char label[] = RD_LABEL("commit v1");
    size_t n = 0;
    memcpy(buf, label, sizeof(label) - 1); n += sizeof(label) - 1;
    memcpy(buf + n, pkHost, RD_PUBKEY_LEN); n += RD_PUBKEY_LEN;
    rd_sha256(buf, n, out);
}

void rd_pair_transcript(const char *hostID, const char *viewerID,
                        const uint8_t pkHost[RD_PUBKEY_LEN], const uint8_t pkViewer[RD_PUBKEY_LEN],
                        uint8_t out[RD_HASH_LEN]) {
    uint8_t buf[512];
    size_t n = 0;
    n = put_field(buf, n, RD_LABEL("pair v1"), sizeof(RD_LABEL("pair v1")) - 1);
    n = put_field(buf, n, hostID, clamp_id(hostID));
    n = put_field(buf, n, viewerID, clamp_id(viewerID));
    n = put_field(buf, n, pkHost, RD_PUBKEY_LEN);
    n = put_field(buf, n, pkViewer, RD_PUBKEY_LEN);
    rd_sha256(buf, n, out);
}

void rd_pair_key(const uint8_t *sharedSecret, size_t sharedLen, const uint8_t transcript[RD_HASH_LEN],
                 uint8_t outKey[RD_KEY_LEN]) {
    rd_hkdf_sha256(sharedSecret, sharedLen, transcript, RD_HASH_LEN, RD_LABEL("pairing key v1"),
                   outKey, RD_KEY_LEN);
}

uint32_t rd_pair_code(const uint8_t key[RD_KEY_LEN], const uint8_t transcript[RD_HASH_LEN]) {
    static const char label[] = RD_LABEL("SAS");
    uint8_t buf[sizeof(label) - 1 + RD_HASH_LEN], mac[RD_HASH_LEN];
    memcpy(buf, label, sizeof(label) - 1);
    memcpy(buf + sizeof(label) - 1, transcript, RD_HASH_LEN);
    rd_hmac_sha256(key, RD_KEY_LEN, buf, sizeof(buf), mac);
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | mac[i];
    return (uint32_t)(v % 1000000u);
}

static void labelled_mac(const uint8_t key[RD_KEY_LEN], const char *label,
                         const uint8_t transcript[RD_HASH_LEN], uint8_t out[RD_HASH_LEN]) {
    uint8_t buf[64 + RD_HASH_LEN];
    size_t n = strlen(label);
    if (n > 64) n = 64;
    memcpy(buf, label, n);
    memcpy(buf + n, transcript, RD_HASH_LEN);
    rd_hmac_sha256(key, RD_KEY_LEN, buf, n + RD_HASH_LEN, out);
}

void rd_pair_confirm(const uint8_t key[RD_KEY_LEN], const uint8_t transcript[RD_HASH_LEN],
                     bool fromHost, uint8_t out[RD_HASH_LEN]) {
    labelled_mac(key, fromHost ? RD_LABEL("pair confirm host") : RD_LABEL("pair confirm viewer"),
                 transcript, out);
}

void rd_session_transcript(const char *hostID, const char *viewerID,
                           const uint8_t nonceHost[RD_NONCE_LEN], const uint8_t nonceViewer[RD_NONCE_LEN],
                           bool encrypt, uint8_t out[RD_HASH_LEN]) {
    uint8_t buf[256];
    size_t n = 0;
    n = put_field(buf, n, RD_LABEL("session v1"), sizeof(RD_LABEL("session v1")) - 1);
    n = put_field(buf, n, hostID, clamp_id(hostID));
    n = put_field(buf, n, viewerID, clamp_id(viewerID));
    n = put_field(buf, n, nonceHost, RD_NONCE_LEN);
    n = put_field(buf, n, nonceViewer, RD_NONCE_LEN);
    uint8_t flag = encrypt ? 1 : 0;
    n = put_field(buf, n, &flag, 1);
    rd_sha256(buf, n, out);
}

void rd_session_proof(const uint8_t key[RD_KEY_LEN], const uint8_t transcript[RD_HASH_LEN],
                      bool fromHost, uint8_t out[RD_HASH_LEN]) {
    labelled_mac(key, fromHost ? RD_LABEL("auth host") : RD_LABEL("auth viewer"), transcript, out);
}

#pragma mark - channel

void rd_session_channels(const uint8_t key[RD_KEY_LEN], const uint8_t transcript[RD_HASH_LEN],
                         bool isHost, rd_channel *send, rd_channel *recv) {
    uint8_t material[96];   // host->viewer enc(16) mac(32), viewer->host enc(16) mac(32)
    rd_hkdf_sha256(key, RD_KEY_LEN, transcript, RD_HASH_LEN, RD_LABEL("channel keys v1"),
                   material, sizeof(material));
    rd_channel h2v, v2h;
    memcpy(h2v.encKey, material, 16);
    memcpy(h2v.macKey, material + 16, 32);
    memcpy(v2h.encKey, material + 48, 16);
    memcpy(v2h.macKey, material + 64, 32);
    h2v.counter = v2h.counter = 0;
    *send = isHost ? h2v : v2h;
    *recv = isHost ? v2h : h2v;
    memset(material, 0, sizeof(material));
}

static void make_iv(uint64_t counter, uint8_t iv[16]) {
    // High 64 bits: message counter. Low 64 bits: block counter inside the message,
    // so keystreams of different messages never overlap.
    for (int i = 0; i < 8; i++) iv[i] = (uint8_t)(counter >> (56 - 8 * i));
    memset(iv + 8, 0, 8);
}

static void tag_of(const rd_channel *ch, const uint8_t *counterAndCiphertext, size_t len,
                   uint8_t tag[RD_TAG_LEN]) {
    uint8_t mac[RD_HASH_LEN];
    rd_hmac_sha256(ch->macKey, sizeof(ch->macKey), counterAndCiphertext, len, mac);
    memcpy(tag, mac, RD_TAG_LEN);
}

bool rd_seal(rd_channel *ch, const uint8_t *plain, size_t len, uint8_t *out) {
    if (ch->counter == UINT64_MAX) return false;
    uint64_t counter = ch->counter + 1;
    uint8_t iv[16];
    make_iv(counter, iv);
    memcpy(out, iv, 8);                                   // u64 counter, big-endian
    if (!aes128_ctr(ch->encKey, iv, plain, len, out + 8)) return false;
    tag_of(ch, out, 8 + len, out + 8 + len);
    ch->counter = counter;
    return true;
}

bool rd_open(rd_channel *ch, const uint8_t *in, size_t inLen, uint8_t *out, size_t *outLen) {
    if (inLen < RD_SEAL_OVERHEAD) return false;
    size_t len = inLen - RD_SEAL_OVERHEAD;
    uint64_t counter = 0;
    for (int i = 0; i < 8; i++) counter = (counter << 8) | in[i];
    if (ch->counter == UINT64_MAX || counter != ch->counter + 1) return false;   // replay / reorder
    uint8_t tag[RD_TAG_LEN];
    tag_of(ch, in, 8 + len, tag);
    if (!rd_equal(tag, in + 8 + len, RD_TAG_LEN)) return false;                // verify before decrypting
    uint8_t iv[16];
    make_iv(counter, iv);
    if (!aes128_ctr(ch->encKey, iv, in + 8, len, out)) return false;
    ch->counter = counter;
    *outLen = len;
    return true;
}
