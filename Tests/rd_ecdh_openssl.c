//
//  rd_ecdh_openssl.c — the three rd_ecdh_* functions with OpenSSL, for tests on Linux only
//  (the Mac apps use Shared/rd_ecdh.c, Security.framework). Used by windows_interop.sh.
//

#include "rd_crypto.h"
#include <stdlib.h>
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
