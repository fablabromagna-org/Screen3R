//
//  crypto_test.c — protocol-level tests of Shared/rd_crypto.c, runnable on Linux or macOS:
//
//    cc -O2 -I Shared Tests/crypto_test.c Shared/rd_crypto.c -lcrypto -o /tmp/crypto_test && /tmp/crypto_test
//
//  On Linux, rd_crypto.c uses OpenSSL instead of CommonCrypto; ECDH below uses OpenSSL too.
//

#include "rd_crypto.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(__APPLE__)
#include <openssl/evp.h>
#include <openssl/ec.h>

struct rd_ecdh { EVP_PKEY *key; };

rd_ecdh *rd_ecdh_create(uint8_t pubOut[RD_PUBKEY_LEN]) {
    EVP_PKEY *key = EVP_EC_gen("P-256");
    if (!key) return NULL;
    size_t len = 0;
    if (!EVP_PKEY_get_octet_string_param(key, "encoded-pub-key", pubOut, RD_PUBKEY_LEN, &len) ||
        len != RD_PUBKEY_LEN) { EVP_PKEY_free(key); return NULL; }
    rd_ecdh *e = calloc(1, sizeof(*e));
    e->key = key;
    return e;
}

bool rd_ecdh_shared(const rd_ecdh *e, const uint8_t peerPub[RD_PUBKEY_LEN], uint8_t zOut[32]) {
    EVP_PKEY *peer = EVP_PKEY_new();
    EVP_PKEY_CTX *pctx = EVP_PKEY_CTX_new_from_name(NULL, "EC", NULL);
    EVP_PKEY_paramgen_init(pctx);
    EVP_PKEY_CTX_set_ec_paramgen_curve_nid(pctx, NID_X9_62_prime256v1);
    EVP_PKEY_paramgen(pctx, &peer);
    EVP_PKEY_CTX_free(pctx);
    if (!EVP_PKEY_set1_encoded_public_key(peer, peerPub, RD_PUBKEY_LEN)) { EVP_PKEY_free(peer); return false; }
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new(e->key, NULL);
    size_t len = 32;
    bool ok = ctx && EVP_PKEY_derive_init(ctx) == 1 && EVP_PKEY_derive_set_peer(ctx, peer) == 1 &&
              EVP_PKEY_derive(ctx, zOut, &len) == 1 && len == 32;
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(peer);
    return ok;
}

void rd_ecdh_free(rd_ecdh *e) { if (e) { EVP_PKEY_free(e->key); free(e); } }
#endif

static int failures = 0;
#define CHECK(cond, msg) do { if (cond) printf("ok   %s\n", msg); else { printf("FAIL %s\n", msg); failures++; } } while (0)

static void unhex(const char *hex, uint8_t *out, size_t n) {
    for (size_t i = 0; i < n; i++) sscanf(hex + 2 * i, "%2hhx", &out[i]);
}

int main(void) {
    // RFC 5869, test case 1 (HKDF-SHA256)
    uint8_t ikm[22], salt[13], okm[42], expected[42];
    memset(ikm, 0x0b, sizeof(ikm));
    unhex("000102030405060708090a0b0c", salt, 13);
    const uint8_t info[] = {0xf0,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0};
    rd_hkdf_sha256(ikm, 22, salt, 13, (const char *)info, okm, 42);
    unhex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", expected, 42);
    CHECK(memcmp(okm, expected, 42) == 0, "HKDF-SHA256 matches RFC 5869 test case 1");

    // --- pairing between a simulated host and viewer
    const char *hostID = "8C1F7A2E-host", *viewerID = "3B9D0C44-viewer";
    uint8_t pkH[RD_PUBKEY_LEN], pkV[RD_PUBKEY_LEN], commit[32], commitCheck[32];
    rd_ecdh *eh = rd_ecdh_create(pkH), *ev = rd_ecdh_create(pkV);
    CHECK(eh && ev, "ECDH key pairs created");
    rd_pair_commitment(pkH, commit);                 // host -> viewer: PAIR_COMMIT
    rd_pair_commitment(pkH, commitCheck);            // viewer checks after PAIR_KEY(host)
    CHECK(rd_equal(commit, commitCheck, 32), "commitment verifies");

    uint8_t zH[32], zV[32], tH[32], tV[32], kH[32], kV[32];
    CHECK(rd_ecdh_shared(eh, pkV, zH) && rd_ecdh_shared(ev, pkH, zV), "shared secrets computed");
    CHECK(memcmp(zH, zV, 32) == 0, "both sides get the same ECDH secret");
    rd_pair_transcript(hostID, viewerID, pkH, pkV, tH);
    rd_pair_transcript(hostID, viewerID, pkH, pkV, tV);
    rd_pair_key(zH, 32, tH, kH);
    rd_pair_key(zV, 32, tV, kV);
    CHECK(memcmp(kH, kV, 32) == 0, "both sides derive the same pairing key");
    uint32_t codeH = rd_pair_code(kH, tH), codeV = rd_pair_code(kV, tV);
    CHECK(codeH == codeV && codeH < 1000000, "both Macs show the same 6-digit code");
    printf("     (code: %03u %03u)\n", codeH / 1000, codeH % 1000);

    uint8_t cH[32], cHcheck[32], cV[32];
    rd_pair_confirm(kH, tH, true, cH);
    rd_pair_confirm(kV, tV, true, cHcheck);
    rd_pair_confirm(kV, tV, false, cV);
    CHECK(rd_equal(cH, cHcheck, 32), "host confirmation verifies on the viewer");
    CHECK(!rd_equal(cH, cV, 32), "host and viewer confirmations differ (no reflection)");

    // A man in the middle with its own key yields a different code (with overwhelming probability)
    uint8_t pkM[RD_PUBKEY_LEN], zM[32], tM[32], kM[32];
    rd_ecdh *em = rd_ecdh_create(pkM);
    rd_ecdh_shared(em, pkV, zM);
    rd_pair_transcript(hostID, viewerID, pkM, pkV, tM);
    rd_pair_key(zM, 32, tM, kM);
    CHECK(rd_pair_code(kM, tM) != codeH, "a different key gives a different code");

    // --- session
    uint8_t nH[16], nV[16], sH[32], sV[32];
    rd_random(nH, 16); rd_random(nV, 16);
    rd_session_transcript(hostID, viewerID, nH, nV, true, sH);
    rd_session_transcript(hostID, viewerID, nH, nV, true, sV);
    uint8_t pH[32], pHcheck[32], pV[32], pVcheck[32];
    rd_session_proof(kH, sH, true, pH);   rd_session_proof(kV, sV, true, pHcheck);
    rd_session_proof(kV, sV, false, pV);  rd_session_proof(kH, sH, false, pVcheck);
    CHECK(rd_equal(pH, pHcheck, 32) && rd_equal(pV, pVcheck, 32), "session proofs verify both ways");
    uint8_t sFlipped[32];
    rd_session_transcript(hostID, viewerID, nH, nV, false, sFlipped);
    rd_session_proof(kV, sFlipped, true, pHcheck);
    CHECK(!rd_equal(pH, pHcheck, 32), "changing the encryption flag breaks the proof");
    uint8_t wrongKey[32]; memset(wrongKey, 7, 32);
    rd_session_proof(wrongKey, sV, true, pHcheck);
    CHECK(!rd_equal(pH, pHcheck, 32), "a wrong pairing key fails the proof");

    rd_channel hSend, hRecv, vSend, vRecv;
    rd_session_channels(kH, sH, true, &hSend, &hRecv);
    rd_session_channels(kV, sV, false, &vSend, &vRecv);
    CHECK(memcmp(hSend.encKey, vRecv.encKey, 16) == 0 && memcmp(hSend.macKey, vRecv.macKey, 32) == 0 &&
          memcmp(vSend.encKey, hRecv.encKey, 16) == 0 && memcmp(hSend.encKey, hRecv.encKey, 16) != 0,
          "channel keys pair up and differ per direction");

    // host -> viewer messages
    size_t sizes[] = {0, 1, 15, 16, 17, 1000, 300000};
    bool allOk = true;
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        size_t n = sizes[i];
        uint8_t *plain = malloc(n + 1), *sealed = malloc(n + RD_SEAL_OVERHEAD), *opened = malloc(n + 1);
        for (size_t k = 0; k < n; k++) plain[k] = (uint8_t)(k * 31 + i);
        size_t outLen = 0;
        bool ok = rd_seal(&hSend, plain, n, sealed) &&
                  rd_open(&vRecv, sealed, n + RD_SEAL_OVERHEAD, opened, &outLen) &&
                  outLen == n && memcmp(plain, opened, n) == 0 &&
                  (n < 16 || memcmp(plain, sealed + 8, 16) != 0);
        allOk = allOk && ok;
        free(plain); free(sealed); free(opened);
    }
    CHECK(allOk, "seal/open round trips (0 B ... 300 KB), ciphertext differs from plaintext");

    uint8_t msg[64] = "frame data", sealed[64 + RD_SEAL_OVERHEAD], out[64];
    size_t outLen;
    rd_seal(&hSend, msg, 64, sealed);
    rd_channel snapshot = vRecv;
    sealed[20] ^= 1;
    CHECK(!rd_open(&vRecv, sealed, sizeof(sealed), out, &outLen), "tampered ciphertext rejected");
    CHECK(vRecv.counter == snapshot.counter, "failed open does not advance the counter");
    sealed[20] ^= 1;
    CHECK(rd_open(&vRecv, sealed, sizeof(sealed), out, &outLen), "original message accepted");
    CHECK(!rd_open(&vRecv, sealed, sizeof(sealed), out, &outLen), "replayed message rejected");

    uint8_t a[64 + RD_SEAL_OVERHEAD], b[64 + RD_SEAL_OVERHEAD];
    rd_seal(&hSend, msg, 64, a);
    rd_seal(&hSend, msg, 64, b);
    CHECK(!rd_open(&vRecv, b, sizeof(b), out, &outLen), "out-of-order message rejected");
    CHECK(rd_open(&vRecv, a, sizeof(a), out, &outLen) && rd_open(&vRecv, b, sizeof(b), out, &outLen),
          "in-order messages accepted after a rejection");

    rd_seal(&vSend, msg, 64, a);
    CHECK(rd_open(&hRecv, a, sizeof(a), out, &outLen) && memcmp(out, msg, 64) == 0, "viewer -> host direction works");
    rd_seal(&vSend, msg, 64, a);
    rd_channel wrong = hSend; wrong.counter = hRecv.counter;
    CHECK(!rd_open(&wrong, a, sizeof(a), out, &outLen), "a message cannot be reflected into the other direction");
    CHECK(!rd_open(&vRecv, a, 5, out, &outLen), "truncated message rejected");

    rd_ecdh_free(eh); rd_ecdh_free(ev); rd_ecdh_free(em);
    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
