//
//  rd_ecdh.c
//  Screen3R — ephemeral P-256 ECDH with Security.framework (macOS 10.12+).
//  (The Linux unit test has its own OpenSSL version of these three functions.)
//

#include "rd_crypto.h"
#include <stdlib.h>
#include <string.h>
#include <Security/Security.h>

struct rd_ecdh {
    SecKeyRef privateKey;
};

rd_ecdh *rd_ecdh_create(uint8_t pubOut[RD_PUBKEY_LEN]) {
    int bits = 256;
    CFNumberRef size = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bits);
    const void *keys[] = { kSecAttrKeyType, kSecAttrKeySizeInBits };
    const void *values[] = { kSecAttrKeyTypeECSECPrimeRandom, size };
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFRelease(size);
    SecKeyRef priv = SecKeyCreateRandomKey(attrs, NULL);   // in memory only, never stored
    CFRelease(attrs);
    if (!priv) return NULL;

    SecKeyRef pub = SecKeyCopyPublicKey(priv);
    CFDataRef data = pub ? SecKeyCopyExternalRepresentation(pub, NULL) : NULL;
    if (pub) CFRelease(pub);
    if (!data || CFDataGetLength(data) != RD_PUBKEY_LEN) {
        if (data) CFRelease(data);
        CFRelease(priv);
        return NULL;
    }
    memcpy(pubOut, CFDataGetBytePtr(data), RD_PUBKEY_LEN);
    CFRelease(data);

    rd_ecdh *e = calloc(1, sizeof(*e));
    if (!e) { CFRelease(priv); return NULL; }
    e->privateKey = priv;
    return e;
}

bool rd_ecdh_shared(const rd_ecdh *e, const uint8_t peerPub[RD_PUBKEY_LEN], uint8_t zOut[32]) {
    if (!e || !e->privateKey || peerPub[0] != 0x04) return false;

    CFDataRef peerData = CFDataCreate(kCFAllocatorDefault, peerPub, RD_PUBKEY_LEN);
    int bits = 256;
    CFNumberRef size = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bits);
    const void *keys[] = { kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits };
    const void *values[] = { kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPublic, size };
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFRelease(size);
    SecKeyRef peer = SecKeyCreateWithData(peerData, attrs, NULL);   // rejects points not on the curve
    CFRelease(attrs);
    CFRelease(peerData);
    if (!peer) return false;

    CFDictionaryRef params = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    CFDataRef z = SecKeyCopyKeyExchangeResult(e->privateKey, kSecKeyAlgorithmECDHKeyExchangeStandard,
                                              peer, params, NULL);
    CFRelease(params);
    CFRelease(peer);
    if (!z || CFDataGetLength(z) != 32) {
        if (z) CFRelease(z);
        return false;
    }
    memcpy(zOut, CFDataGetBytePtr(z), 32);
    CFRelease(z);
    return true;
}

void rd_ecdh_free(rd_ecdh *e) {
    if (!e) return;
    if (e->privateKey) CFRelease(e->privateKey);
    free(e);
}
