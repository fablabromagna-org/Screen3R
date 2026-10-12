//
//  RDServer.m
//  Screen3R Viewer
//
//  Deliberately plain: POSIX sockets + one reader thread, because Network.framework
//  needs macOS 10.14 and this must run on High Sierra (10.13).
//
//  Threads:
//  - server thread: accepts, reads messages; handles ping and cursor messages at once
//    (so the pointer never waits behind video decoding);
//  - decode queue (serial): FORMAT and FRAME messages, VideoToolbox decoding, display.
//    A frame is acknowledged only after it has been decoded, so the host's flow control
//    follows the real speed of this Mac and frames never pile up in a queue here.
//  - input queue (serial): keyboard and mouse events of this Mac, sent to the host while
//    it accepts them.
//  Socket writes from all three are serialized by a mutex.
//
//  Security (protocol 2): nothing but HELLO, PING and the pairing/authentication messages
//  is accepted until the host has proven it holds a pairing key we stored (or a new pairing
//  has been confirmed). After that, if the host asked for it, every message in both
//  directions is encrypted and authenticated (Shared/rd_crypto.c).
//

#import "RDServer.h"
#import "RDProtocol.h"
#import "RDPairingStore.h"
#include "rd_crypto.h"
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <Carbon/Carbon.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <libkern/OSByteOrder.h>
#include <ifaddrs.h>
#include <net/if.h>

static const int kSocketTimeoutSeconds = 6;   // host pings every second

// Hardening limits. The old Mac runs an OS without security updates, so we keep untrusted
// input away from complex parsers and bound every resource a peer can make us use.
static const int kMaxPendingFrames = 8;        // an honest host keeps ~2 frames in flight (+ FORMAT, encoder lag)
static const uint32_t kMaxPingPayload = 64;
static const int kMaxCursorPixels = 256;       // per side
static const int32_t kMaxVideoWidth = 4096, kMaxVideoHeight = 2304;
static const CFAbsoluteTime kPairingTimeout = 120;   // seconds to authenticate or approve a pairing
static const uint32_t kMaxHandshakeMessage = 64 * 1024;   // before authentication

typedef NS_ENUM(int, RDSessionState) {
    RDSessionAwaitHello,         // waiting for the host's HELLO
    RDSessionAwaitAuth,          // waiting for AUTH (known host) or PAIR_COMMIT (new host)
    RDSessionPairAwaitKey,       // sent our public key, waiting for the host's
    RDSessionPairAwaitConfirm,   // code shown, waiting for the host user's confirmation
    RDSessionPairAwaitLocal,     // host confirmed, waiting for Return on this Mac
    RDSessionReady,              // authenticated: video, cursor…
};

#pragma mark - Small helpers

/// Identifiers are UUID strings: letters, digits and dashes, 1–64 characters.
static BOOL isValidID(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *s = value;
    if (s.length < 1 || s.length > 64) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"] invertedSet];
    return [s rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static BOOL hexToBytes(id value, uint8_t *out, size_t len) {
    if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] != len * 2) return NO;
    const char *s = [(NSString *)value UTF8String];
    for (size_t i = 0; i < len; i++) {
        unsigned int byte;
        if (sscanf(s + 2 * i, "%2x", &byte) != 1) return NO;
        out[i] = (uint8_t)byte;
    }
    return YES;
}

static NSString *bytesToHex(const uint8_t *p, size_t len) {
    NSMutableString *s = [NSMutableString stringWithCapacity:len * 2];
    for (size_t i = 0; i < len; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

NSString *RDCryMode(void) {
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:@"cryMode"];
    return ([mode isEqualToString:@"always"] || [mode isEqualToString:@"never"]) ? mode : @"sometimes";
}

/// Layout type of the keyboard last used on this Mac. Main thread.
static NSString *keyboardLayoutName(void) {
    switch (KBGetLayoutType(LMGetKbdType())) {
        case kKeyboardISO: return @"iso";
        case kKeyboardJIS: return @"jis";
        default: return @"ansi";
    }
}

#pragma mark - Who may connect

static BOOL isPrivateIPv4(uint32_t a) {   // host byte order
    return (a & 0xFF000000u) == 0x0A000000u     // 10.0.0.0/8
        || (a & 0xFFF00000u) == 0xAC100000u     // 172.16.0.0/12
        || (a & 0xFFFF0000u) == 0xC0A80000u     // 192.168.0.0/16
        || (a & 0xFFFF0000u) == 0xA9FE0000u     // 169.254.0.0/16 link-local
        || (a & 0xFF000000u) == 0x7F000000u;    // 127.0.0.0/8 loopback
}

/// YES if `peer` is in the same subnet as one of this Mac's interfaces
/// (covers global IPv6 addresses handed out on the home network).
static BOOL isOnLink(const struct sockaddr *peer) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return NO;
    BOOL found = NO;
    for (struct ifaddrs *i = list; i && !found; i = i->ifa_next) {
        if (!i->ifa_addr || !i->ifa_netmask || !(i->ifa_flags & IFF_UP)) continue;
        if (i->ifa_addr->sa_family != peer->sa_family) continue;
        const uint8_t *a = NULL, *b = NULL;
        size_t n = 0, maskOffset = 0;
        if (peer->sa_family == AF_INET) {
            a = (const uint8_t *)&((const struct sockaddr_in *)i->ifa_addr)->sin_addr;
            b = (const uint8_t *)&((const struct sockaddr_in *)peer)->sin_addr;
            n = 4;
            maskOffset = offsetof(struct sockaddr_in, sin_addr);
        } else if (peer->sa_family == AF_INET6) {
            a = ((const struct sockaddr_in6 *)i->ifa_addr)->sin6_addr.s6_addr;
            b = ((const struct sockaddr_in6 *)peer)->sin6_addr.s6_addr;
            n = 16;
            maskOffset = offsetof(struct sockaddr_in6, sin6_addr);
        } else {
            continue;
        }
        // BSD netmasks may be truncated (sa_len covers only the significant bytes):
        // copy what is there, the rest is zero.
        uint8_t m[16] = {0};
        size_t maskLength = i->ifa_netmask->sa_len;
        if (maskLength > maskOffset) {
            memcpy(m, (const uint8_t *)i->ifa_netmask + maskOffset, MIN(n, maskLength - maskOffset));
        }
        BOOL same = YES, anyMask = NO;
        for (size_t k = 0; k < n; k++) {
            if (m[k]) anyMask = YES;
            if ((a[k] & m[k]) != (b[k] & m[k])) { same = NO; break; }
        }
        found = same && anyMask;
    }
    freeifaddrs(list);
    return found;
}

/// Only devices on the local network may connect: private/link-local/unique-local addresses,
/// or addresses in the same subnet as one of our interfaces. Never the internet.
static BOOL isLocalPeer(const struct sockaddr_storage *ss) {
    if (ss->ss_family == AF_INET) {
        uint32_t a = ntohl(((const struct sockaddr_in *)ss)->sin_addr.s_addr);
        return isPrivateIPv4(a) || isOnLink((const struct sockaddr *)ss);
    }
    if (ss->ss_family == AF_INET6) {
        const struct in6_addr *a6 = &((const struct sockaddr_in6 *)ss)->sin6_addr;
        if (IN6_IS_ADDR_V4MAPPED(a6)) {
            uint32_t a;
            memcpy(&a, &a6->s6_addr[12], 4);
            if (isPrivateIPv4(ntohl(a))) return YES;
            struct sockaddr_in v4;
            memset(&v4, 0, sizeof(v4));
            v4.sin_len = sizeof(v4);
            v4.sin_family = AF_INET;
            memcpy(&v4.sin_addr, &a, 4);
            return isOnLink((const struct sockaddr *)&v4);
        }
        if (IN6_IS_ADDR_LOOPBACK(a6) || IN6_IS_ADDR_LINKLOCAL(a6)) return YES;
        if ((a6->s6_addr[0] & 0xFE) == 0xFC) return YES;          // fc00::/7 unique local
        return isOnLink((const struct sockaddr *)ss);
    }
    return NO;
}

/// Removes control/format characters (incl. bidi overrides) and limits the length,
/// before a name received from the network is shown on screen.
static NSString *sanitizedName(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return nil;
    NSArray *parts = [name componentsSeparatedByCharactersInSet:[NSCharacterSet controlCharacterSet]];
    NSString *clean = [[parts componentsJoinedByString:@""]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length > 64) {
        clean = [clean substringWithRange:[clean rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 64)]];
    }
    return clean.length ? clean : nil;
}

#pragma mark - Socket helpers

static BOOL readFully(int fd, void *buffer, size_t length) {
    uint8_t *p = buffer;
    size_t got = 0;
    while (got < length) {
        ssize_t n = recv(fd, p + got, length - got, 0);
        if (n > 0) { got += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return NO;  // closed, timed out or failed
    }
    return YES;
}

static BOOL writeFully(int fd, const void *buffer, size_t length) {
    const uint8_t *p = buffer;
    size_t sent = 0;
    while (sent < length) {
        ssize_t n = send(fd, p + sent, length - sent, 0);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return NO;
    }
    return YES;
}

static BOOL sendMessage(int fd, RDMessageType type, const void *payload, uint32_t length) {
    uint8_t header[5];
    header[0] = type;
    OSWriteBigInt32(header, 1, length);
    if (!writeFully(fd, header, sizeof(header))) return NO;
    if (length > 0 && !writeFully(fd, payload, length)) return NO;
    return YES;
}

#pragma mark - RDServer

@implementation RDServer {
    AVSampleBufferDisplayLayer *_layer;
    int _width, _height;
    double _scale;
    int _listenFD;
    NSNetService *_netService;

    // Server thread only.
    uint8_t *_buffer;
    size_t _bufferSize;
    uint8_t *_plain;                     // decrypted inner message
    size_t _plainSize;

    RDPairingStore *_store;              // created on the main thread, then server thread only
    RDSessionState _state;
    NSString *_hostID, *_hostName;
    BOOL _encrypt;                       // host asked for an encrypted session
    uint8_t _nonceHost[RD_NONCE_LEN], _nonceViewer[RD_NONCE_LEN];
    uint8_t _commitment[RD_HASH_LEN];
    uint8_t _pkViewer[RD_PUBKEY_LEN];
    uint8_t _pairTranscript[RD_HASH_LEN];
    uint8_t _pairKey[RD_KEY_LEN];
    rd_ecdh *_ecdh;
    CFAbsoluteTime _pairingStarted;      // handshake (then pairing) start, for the timeout
    int _pairingApproved;                // guarded by @synchronized(self)
    NSString *_pendingCode;              // code awaiting Return; guarded by @synchronized(self)
    rd_channel _recvChannel;             // server thread
    BOOL _recvSecure;
    BOOL _cuePlayed;                     // server thread
    NSString *_keyboardLayout;           // set on the main thread before the server thread starts

    rd_channel _sendChannel;             // guarded by _writeLock
    BOOL _sendSecure;                    // guarded by _writeLock

    pthread_mutex_t _writeLock;          // serializes socket writes from all threads
    int _inputFD;                        // session socket for input, -1 if none; guarded by _writeLock
    BOOL _inputAllowed;                  // host accepts our keyboard/mouse; guarded by _writeLock
    dispatch_queue_t _decodeQueue;
    dispatch_queue_t _inputQueue;
    int _inputBacklog;                   // input messages queued, not yet written (atomic builtins)

    // Decode queue only.
    CMVideoFormatDescriptionRef _format;       // compressed (H.264) format from FORMAT
    VTDecompressionSessionRef _session;        // NULL -> fall back to letting the layer decode
    CMVideoFormatDescriptionRef _imageFormat;  // format of decoded images, for display
    BOOL _hardwareDecoder;
    BOOL _waitingForKeyframe;
    BOOL _hasPicture;
    int _nalLength;                            // AVCC length-prefix size from FORMAT (1, 2 or 4)
    int _pendingFrames;                        // frames queued for decoding (atomic builtins)
    CFAbsoluteTime _lastKeyframeRequest;
    CFAbsoluteTime _statsStart;
    int _statsFrames;
    double _statsDecodeSeconds;
}

#pragma mark - VideoToolbox output

/// Called synchronously from VTDecompressionSessionDecodeFrame (we wait for it).
static void didDecompress(void *refcon, void *frameRefcon, OSStatus status, VTDecodeInfoFlags flags,
                          CVImageBufferRef image, CMTime pts, CMTime duration) {
    CVImageBufferRef *out = (CVImageBufferRef *)frameRefcon;
    if (status == noErr && image && out) *out = CVBufferRetain(image);
}

- (instancetype)initWithLayer:(AVSampleBufferDisplayLayer *)layer
                  screenWidth:(int)width
                 screenHeight:(int)height
                        scale:(double)scale {
    if ((self = [super init])) {
        _layer = layer;
        _width = width;
        _height = height;
        _scale = scale;
        _listenFD = -1;
        _inputFD = -1;
        pthread_mutex_init(&_writeLock, NULL);
        _store = [[RDPairingStore alloc] init];
        _decodeQueue = dispatch_queue_create("screen3r.decode", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_decodeQueue, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        _inputQueue = dispatch_queue_create("screen3r.input", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_inputQueue, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    }
    return self;
}

/// Thread-safe write of one message; encrypted once the session is secure.
- (BOOL)send:(int)fd type:(RDMessageType)type payload:(const void *)payload length:(uint32_t)length {
    pthread_mutex_lock(&_writeLock);
    BOOL ok = [self sendLocked:fd type:type payload:payload length:length];
    pthread_mutex_unlock(&_writeLock);
    return ok;
}

/// Same, with _writeLock already held.
- (BOOL)sendLocked:(int)fd type:(RDMessageType)type payload:(const void *)payload length:(uint32_t)length {
    BOOL ok;
    if (_sendSecure) {
        size_t innerLength = (size_t)length + 1;
        uint8_t *inner = malloc(innerLength);
        uint8_t *sealed = malloc(innerLength + RD_SEAL_OVERHEAD);
        ok = inner && sealed;
        if (ok) {
            inner[0] = type;
            if (length) memcpy(inner + 1, payload, length);
            ok = rd_seal(&_sendChannel, inner, innerLength, sealed) &&
                 sendMessage(fd, RDMsgSecure, sealed, (uint32_t)(innerLength + RD_SEAL_OVERHEAD));
        }
        free(inner);
        free(sealed);
    } else {
        ok = sendMessage(fd, type, payload, length);
    }
    return ok;
}

/// Sends one last plaintext message, then turns on encryption for everything after it.
- (BOOL)send:(int)fd lastPlainType:(RDMessageType)type payload:(const void *)payload length:(uint32_t)length
    thenEncryptWith:(const rd_channel *)channel {
    pthread_mutex_lock(&_writeLock);
    BOOL ok = sendMessage(fd, type, payload, length);
    if (ok && channel) {
        _sendChannel = *channel;
        _sendSecure = YES;
    }
    pthread_mutex_unlock(&_writeLock);
    return ok;
}

- (void)approvePendingPairingWithCode:(NSString *)code {
    // Only the pairing whose code is on screen: a Return pressed for one session can never
    // approve a different session that started in the meantime.
    @synchronized (self) {
        if (_pendingCode && [code isEqualToString:_pendingCode]) _pairingApproved = 1;
    }
}

#pragma mark - Keyboard & mouse of this Mac

/// Input queue: sends one input message if a session accepts input (and only encrypted:
/// the host never enables input otherwise, and we don't send keystrokes in clear either).
/// Mouse movements are dropped while the network is backed up (the pointer catches up with
/// the next one); keys and buttons never are.
- (void)sendInput:(RDMessageType)type data:(NSData *)data {
    if (type == RDMsgInputMove && __atomic_load_n(&_inputBacklog, __ATOMIC_SEQ_CST) > 64) return;
    __atomic_add_fetch(&_inputBacklog, 1, __ATOMIC_SEQ_CST);
    dispatch_async(_inputQueue, ^{
        pthread_mutex_lock(&self->_writeLock);
        if (self->_inputFD >= 0 && self->_inputAllowed && self->_sendSecure) {
            if (![self sendLocked:self->_inputFD type:type payload:data.bytes length:(uint32_t)data.length]) {
                // A failed or partial write breaks the stream (and the encryption counter):
                // end the session instead of blocking every later write on a dead socket.
                // The reader thread wakes up and closes; acceptLoop clears _inputFD before close().
                shutdown(self->_inputFD, SHUT_RDWR);
                self->_inputFD = -1;
            }
        }
        pthread_mutex_unlock(&self->_writeLock);
        __atomic_sub_fetch(&self->_inputBacklog, 1, __ATOMIC_SEQ_CST);
    });
}

- (void)flushInput {
    dispatch_sync(_inputQueue, ^{});
}

- (void)sendMouseMoveSeq:(uint32_t)seq dx:(int16_t)dx dy:(int16_t)dy flags:(uint32_t)flags {
    uint8_t p[12];
    OSWriteBigInt32(p, 0, seq);
    OSWriteBigInt16(p, 4, (uint16_t)dx);
    OSWriteBigInt16(p, 6, (uint16_t)dy);
    OSWriteBigInt32(p, 8, flags);
    [self sendInput:RDMsgInputMove data:[NSData dataWithBytes:p length:sizeof(p)]];
}

- (void)sendMouseButton:(uint8_t)button down:(BOOL)down clicks:(uint8_t)clicks flags:(uint32_t)flags {
    uint8_t p[7] = { button, down ? 1 : 0, clicks };
    OSWriteBigInt32(p, 3, flags);
    [self sendInput:RDMsgInputButton data:[NSData dataWithBytes:p length:sizeof(p)]];
}

- (void)sendScrollContinuous:(BOOL)continuous phase:(uint8_t)phase momentum:(uint8_t)momentum
                          dy:(int32_t)dy dx:(int32_t)dx flags:(uint32_t)flags {
    uint8_t p[15] = { continuous ? 1 : 0, phase, momentum };
    OSWriteBigInt32(p, 3, (uint32_t)dy);
    OSWriteBigInt32(p, 7, (uint32_t)dx);
    OSWriteBigInt32(p, 11, flags);
    [self sendInput:RDMsgInputScroll data:[NSData dataWithBytes:p length:sizeof(p)]];
}

- (void)sendKey:(uint16_t)keyCode down:(BOOL)down repeat:(BOOL)isRepeat
   keyboardType:(uint8_t)keyboardType flags:(uint32_t)flags {
    uint8_t p[8];
    OSWriteBigInt16(p, 0, keyCode);
    p[2] = (down ? 1 : 0) | (isRepeat ? 2 : 0);
    p[3] = keyboardType;
    OSWriteBigInt32(p, 4, flags);
    [self sendInput:RDMsgInputKey data:[NSData dataWithBytes:p length:sizeof(p)]];
}

- (void)sendInputReset {
    [self sendInput:RDMsgInputReset data:[NSData data]];
}

- (void)postInputControl:(BOOL)enabled {
    void (^callback)(BOOL) = self.onInputControl;
    if (!callback) return;
    dispatch_async(dispatch_get_main_queue(), ^{ callback(enabled); });
}

#pragma mark - Listening

- (BOOL)start:(NSError **)error {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) return [self fail:error message:@"socket() failed"];

    int no = 0, yes = 1;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));   // accept IPv4 too
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in6 addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin6_len = sizeof(addr);
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(RD_PORT);
    addr.sin6_addr = in6addr_any;

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return [self fail:error message:[NSString stringWithFormat:
            @"Port %d is already in use. Is another copy of the viewer running?", RD_PORT]];
    }
    if (listen(fd, 4) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return [self fail:error message:@"listen() failed"];
    }
    _listenFD = fd;
    _keyboardLayout = keyboardLayoutName();   // HIToolbox: ask on the main thread

    // Bonjour: empty name = this Mac's computer name.
    _netService = [[NSNetService alloc] initWithDomain:@"local." type:RD_SERVICE_TYPE name:@"" port:RD_PORT];
    [_netService publish];

    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(acceptLoop) object:nil];
    thread.name = @"Screen3R server";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];
    return YES;
}

- (BOOL)fail:(NSError **)error message:(NSString *)message {
    if (error) {
        *error = [NSError errorWithDomain:@"Screen3R" code:errno
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

- (void)postState:(RDServerState)state detail:(NSString *)detail {
    void (^callback)(RDServerState, NSString *) = self.onStateChange;
    if (!callback) return;
    dispatch_async(dispatch_get_main_queue(), ^{ callback(state, detail ?: @""); });
}

#pragma mark - Server thread

- (void)acceptLoop {
    for (;;) {
        @autoreleasepool {
            struct sockaddr_storage peer;
            socklen_t peerLength = sizeof(peer);
            int fd = accept(_listenFD, (struct sockaddr *)&peer, &peerLength);
            if (fd < 0) {
                if (errno != EINTR) usleep(200 * 1000);
                continue;
            }
            if (!isLocalPeer(&peer)) {
                NSLog(@"Screen3R: refused a connection from outside the local network");
                close(fd);
                continue;
            }
            [self configureClientSocket:fd];
            [self runSession:fd];
            pthread_mutex_lock(&_writeLock);   // no more input on this socket (before close: fd reuse)
            _inputFD = -1;
            _inputAllowed = NO;
            pthread_mutex_unlock(&_writeLock);
            [self postInputControl:NO];
            // Let pending decodes finish (their writes just fail) before the fd number can be reused.
            dispatch_sync(_decodeQueue, ^{ [self resetVideo]; });
            close(fd);
            [self endSecureSession];
            [self postCursorX:0 y:0 visible:NO hasSeq:NO seq:0];
            [self postState:RDServerStateWaiting detail:nil];
        }
    }
}

- (void)configureClientSocket:(int)fd {
    int yes = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    int rcvbuf = 4 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    struct timeval tv = { .tv_sec = kSocketTimeoutSeconds, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

- (void)endSecureSession {
    _state = RDSessionAwaitHello;
    _pairingStarted = 0;
    _hostID = nil;
    _hostName = nil;
    _recvSecure = NO;
    _cuePlayed = NO;
    memset(&_recvChannel, 0, sizeof(_recvChannel));
    _encrypt = NO;
    memset(_pairKey, 0, sizeof(_pairKey));
    memset(_pairTranscript, 0, sizeof(_pairTranscript));
    if (_ecdh) { rd_ecdh_free(_ecdh); _ecdh = NULL; }
    @synchronized (self) {
        _pairingApproved = 0;
        _pendingCode = nil;
    }
    pthread_mutex_lock(&_writeLock);
    _sendSecure = NO;
    memset(&_sendChannel, 0, sizeof(_sendChannel));
    pthread_mutex_unlock(&_writeLock);
}

- (void)runSession:(int)fd {
    dispatch_sync(_decodeQueue, ^{
        self->_waitingForKeyframe = YES;
        self->_hasPicture = NO;
        self->_lastKeyframeRequest = 0;
        self->_statsStart = CFAbsoluteTimeGetCurrent();
        self->_statsFrames = 0;
        self->_statsDecodeSeconds = 0;
    });
    __atomic_store_n(&_pendingFrames, 0, __ATOMIC_SEQ_CST);
    [self endSecureSession];
    // The handshake must finish in time too: a peer that only answers pings must not keep
    // the (single) session slot forever. Pairing restarts the clock.
    _pairingStarted = CFAbsoluteTimeGetCurrent();
    if (!rd_random(_nonceViewer, sizeof(_nonceViewer))) return;

    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    NSDictionary *hello = @{
        @"proto": @(RD_PROTOCOL_VERSION),
        @"id": _store.viewerID,
        @"nonce": bytesToHex(_nonceViewer, sizeof(_nonceViewer)),
        @"name": [[NSHost currentHost] localizedName] ?: @"Old Mac",
        @"width": @(_width),
        @"height": @(_height),
        @"scale": @(_scale),
        @"os": [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion],
        // We draw the mouse pointer ourselves, and can send this Mac's keyboard and mouse.
        @"features": @[@"cursor", @"input"],
        // ANSI/ISO/JIS: hosts that are not Macs need it to map the keys next to Shift and below Esc.
        @"keyboardLayout": _keyboardLayout ?: @"ansi",
        // How this Mac takes being connected to a PC ("always", "sometimes", "never").
        @"cry": RDCryMode(),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:hello options:0 error:NULL];
    if (![self send:fd type:RDMsgHello payload:json.bytes length:(uint32_t)json.length]) return;

    for (;;) {
        @autoreleasepool {
            uint8_t header[5];
            if (!readFully(fd, header, sizeof(header))) return;
            uint8_t type = header[0];
            uint32_t length = OSReadBigInt32(header, 1);
            if (length > RD_MAX_MESSAGE) return;
            if (_state != RDSessionReady && length > kMaxHandshakeMessage) return;

            if (length > _bufferSize) {
                uint8_t *grown = realloc(_buffer, length);
                if (!grown) return;
                _buffer = grown;
                _bufferSize = length;
            }
            if (length > 0 && !readFully(fd, _buffer, length)) return;
            const uint8_t *body = _buffer;

            if (type == RDMsgSecure) {
                // Decrypt and authenticate; anything that fails ends the session.
                if (!_recvSecure || length < RD_SEAL_OVERHEAD + 1) return;
                size_t needed = length - RD_SEAL_OVERHEAD;
                if (needed > _plainSize) {
                    uint8_t *grown = realloc(_plain, needed);
                    if (!grown) return;
                    _plain = grown;
                    _plainSize = needed;
                }
                size_t plainLength = 0;
                if (!rd_open(&_recvChannel, _buffer, length, _plain, &plainLength) || plainLength < 1) {
                    NSLog(@"Screen3R: message failed authentication, disconnecting");
                    return;
                }
                type = _plain[0];
                body = _plain + 1;
                length = (uint32_t)(plainLength - 1);
                if (type == RDMsgSecure) return;   // no nesting
            } else if (_recvSecure && (type != RDMsgPing || _recvChannel.counter > 0)) {
                // A clear PING is only legitimate before the host's first sealed message
                // (it may have sent one just before switching); after that, nothing in clear.
                NSLog(@"Screen3R: unencrypted message in an encrypted session, disconnecting");
                return;
            }

            if (type == RDMsgPing) {
                if (length > kMaxPingPayload) return;
                if (![self send:fd type:RDMsgPong payload:body length:length]) return;
                if (_state == RDSessionPairAwaitLocal && ![self finishPairingIfApproved:fd]) return;
                if (_state != RDSessionReady && _pairingStarted > 0 &&
                    CFAbsoluteTimeGetCurrent() - _pairingStarted > kPairingTimeout) {
                    BOOL pairing = _state != RDSessionAwaitHello && _state != RDSessionAwaitAuth;
                    [self postState:RDServerStateRefused
                             detail:(pairing ? @"Pairing timed out." : @"A Mac did not complete the connection.")];
                    return;
                }
                if (_state == RDSessionReady) {
                    // A keyframe request can be throttled away; on a still screen no further
                    // frame would trigger a retry, so retry on the 1 s ping as well.
                    dispatch_async(_decodeQueue, ^{
                        if (self->_waitingForKeyframe && self->_lastKeyframeRequest != 0) [self requestKeyframe:fd];
                    });
                }
                continue;
            }

            if (_state != RDSessionReady) {
                // Before authentication only the handshake is accepted.
                if (![self handleHandshake:type body:body length:length fd:fd]) return;
                continue;
            }

            switch (type) {
                case RDMsgFormat:
                case RDMsgFrame: {
                    // A well-behaved host waits for acks; a peer that floods us is dropped
                    // instead of being allowed to fill memory with queued frames.
                    if (__atomic_add_fetch(&_pendingFrames, 1, __ATOMIC_SEQ_CST) > kMaxPendingFrames) {
                        NSLog(@"Screen3R: peer ignores flow control, disconnecting");
                        return;
                    }
                    // Copy: the buffer is reused for the next message while this one is decoded.
                    NSData *message = [NSData dataWithBytes:body length:length];
                    dispatch_async(_decodeQueue, ^{
                        // Counted until decoding starts: decrementing after the ACK went out
                        // would race with the host's next frame and could drop an honest host.
                        __atomic_sub_fetch(&self->_pendingFrames, 1, __ATOMIC_SEQ_CST);
                        BOOL ok = YES;
                        if (type == RDMsgFormat) {
                            [self handleFormat:message.bytes length:(uint32_t)message.length];
                        } else {
                            ok = [self handleFrame:message.bytes length:(uint32_t)message.length fd:fd];
                        }
                        if (!ok) shutdown(fd, SHUT_RDWR);   // wakes up the reader, which ends the session
                    });
                    break;
                }
                case RDMsgCursorPosition: [self handleCursorPosition:body length:length]; break;
                case RDMsgCursorImage:    [self handleCursorImage:body length:length]; break;
                case RDMsgCue: {
                    if (length != 1 || body[0] != 1 || _cuePlayed) break;
                    _cuePlayed = YES;
                    uint8_t cue = body[0];
                    void (^callback)(uint8_t) = self.onCue;
                    if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(cue); });
                    break;
                }
                case RDMsgInputControl: {
                    if (length < 1) break;
                    // Only an encrypted session may carry keystrokes (the host enforces it too).
                    BOOL enabled = (body[0] & 1) && _recvSecure;
                    pthread_mutex_lock(&_writeLock);
                    _inputAllowed = enabled;
                    pthread_mutex_unlock(&_writeLock);
                    [self postInputControl:enabled];
                    break;
                }
                default:
                    break;  // unknown or late handshake message: ignore (forward compatibility)
            }
        }
    }
}

#pragma mark - Handshake (server thread)

/// Returns NO to end the session.
- (BOOL)handleHandshake:(uint8_t)type body:(const uint8_t *)p length:(uint32_t)length fd:(int)fd {
    switch (_state) {
        case RDSessionAwaitHello:
            if (type != RDMsgHello) return NO;
            return [self handleHostHello:p length:length fd:fd];

        case RDSessionAwaitAuth:
            if (type == RDMsgAuth && length == RD_HASH_LEN) return [self handleAuth:p fd:fd];
            if (type == RDMsgPairCommit && length == RD_HASH_LEN) return [self startPairing:p fd:fd];
            return NO;

        case RDSessionPairAwaitKey:
            if (type != RDMsgPairKey || length != RD_PUBKEY_LEN) return NO;
            return [self handleHostPublicKey:p fd:fd];

        case RDSessionPairAwaitConfirm:
            if (type != RDMsgPairConfirm || length != RD_HASH_LEN) return NO;
            return [self handleHostConfirm:p fd:fd];

        case RDSessionPairAwaitLocal:
        case RDSessionReady:
            return NO;
    }
    return NO;
}

- (BOOL)handleHostHello:(const uint8_t *)p length:(uint32_t)length fd:(int)fd {
    NSDictionary *hello = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:p length:length]
                                                          options:0 error:NULL];
    if (![hello isKindOfClass:[NSDictionary class]]) return NO;
    NSNumber *proto = hello[@"proto"];
    if (![proto isKindOfClass:[NSNumber class]] || proto.intValue != RD_PROTOCOL_VERSION) {
        [self postState:RDServerStateRefused detail:@"The Mac runs a different version of Screen3R. Update both apps."];
        return NO;
    }
    if (!isValidID(hello[@"id"]) || !hexToBytes(hello[@"nonce"], _nonceHost, sizeof(_nonceHost))) return NO;
    _hostID = hello[@"id"];
    _hostName = sanitizedName(hello[@"name"]) ?: @"a Mac";
    NSNumber *encrypt = hello[@"encrypt"];
    _encrypt = [encrypt isKindOfClass:[NSNumber class]] ? encrypt.boolValue : YES;
    _state = RDSessionAwaitAuth;
    return YES;
}

/// Host proves it holds our shared pairing key; we prove it back.
- (BOOL)handleAuth:(const uint8_t *)proof fd:(int)fd {
    NSData *key = [_store keyForHost:_hostID];
    uint8_t transcript[RD_HASH_LEN], expected[RD_HASH_LEN];
    rd_session_transcript(_hostID.UTF8String, _store.viewerID.UTF8String, _nonceHost, _nonceViewer,
                          _encrypt, transcript);
    if (key) rd_session_proof(key.bytes, transcript, true, expected);
    if (!key || !rd_equal(proof, expected, RD_HASH_LEN)) {
        // Unknown host, or it lost its key: it may start a new pairing (which needs approval).
        return [self send:fd type:RDMsgNeedPairing payload:NULL length:0];
    }
    return [self completeSessionWithKey:key.bytes transcript:transcript
                              replyType:RDMsgAuth fd:fd];
}

/// Sends our proof (plain), switches on encryption if requested, and starts the session.
- (BOOL)completeSessionWithKey:(const uint8_t *)key transcript:(const uint8_t *)transcript
                     replyType:(RDMessageType)replyType fd:(int)fd {
    uint8_t reply[RD_HASH_LEN];
    if (replyType == RDMsgAuth) {
        rd_session_proof(key, transcript, false, reply);
    } else {
        rd_pair_confirm(key, _pairTranscript, false, reply);
    }
    uint8_t sessionTranscript[RD_HASH_LEN];
    rd_session_transcript(_hostID.UTF8String, _store.viewerID.UTF8String, _nonceHost, _nonceViewer,
                          _encrypt, sessionTranscript);
    rd_channel sendChannel, recvChannel;
    rd_session_channels(key, sessionTranscript, false, &sendChannel, &recvChannel);
    if (![self send:fd lastPlainType:replyType payload:reply length:sizeof(reply)
        thenEncryptWith:(_encrypt ? &sendChannel : NULL)]) return NO;
    if (_encrypt) {
        _recvChannel = recvChannel;
        _recvSecure = YES;
    }
    memset(&sendChannel, 0, sizeof(sendChannel));
    memset(&recvChannel, 0, sizeof(recvChannel));
    _state = RDSessionReady;
    _pairingStarted = 0;
    pthread_mutex_lock(&_writeLock);
    _inputFD = fd;           // input stays off until the host sends INPUT_CONTROL
    _inputAllowed = NO;
    pthread_mutex_unlock(&_writeLock);
    [self postState:RDServerStateConnected detail:_hostName];
    return YES;
}

- (BOOL)startPairing:(const uint8_t *)commitment fd:(int)fd {
    memcpy(_commitment, commitment, RD_HASH_LEN);
    if (_ecdh) rd_ecdh_free(_ecdh);
    _ecdh = rd_ecdh_create(_pkViewer);   // fresh key pair for every pairing attempt
    if (!_ecdh) return NO;
    _pairingStarted = CFAbsoluteTimeGetCurrent();
    _state = RDSessionPairAwaitKey;
    return [self send:fd type:RDMsgPairKey payload:_pkViewer length:sizeof(_pkViewer)];
}

- (BOOL)handleHostPublicKey:(const uint8_t *)pkHost fd:(int)fd {
    uint8_t check[RD_HASH_LEN];
    rd_pair_commitment(pkHost, check);
    if (!rd_equal(check, _commitment, RD_HASH_LEN)) {
        NSLog(@"Screen3R: pairing commitment mismatch");
        return NO;
    }
    uint8_t z[32];
    if (!rd_ecdh_shared(_ecdh, pkHost, z)) return NO;
    rd_ecdh_free(_ecdh);
    _ecdh = NULL;
    rd_pair_transcript(_hostID.UTF8String, _store.viewerID.UTF8String, pkHost, _pkViewer, _pairTranscript);
    rd_pair_key(z, sizeof(z), _pairTranscript, _pairKey);
    memset(z, 0, sizeof(z));

    uint32_t code = rd_pair_code(_pairKey, _pairTranscript);
    NSString *text = [NSString stringWithFormat:@"%03u %03u", code / 1000, code % 1000];
    // The very first Mac pairs with the code alone. Once any Mac is paired, every new pairing
    // (also re-pairing a known Mac: its ID is not secret) needs Return on this Mac, so nobody on
    // the network can add themselves or replace an existing pairing silently.
    BOOL needsApproval = _store.pairedCount > 0;
    @synchronized (self) {
        _pairingApproved = needsApproval ? 0 : 1;
        _pendingCode = needsApproval ? text : nil;
    }
    [self postState:(needsApproval ? RDServerStatePairingNeedsApproval : RDServerStatePairing) detail:text];
    _state = RDSessionPairAwaitConfirm;
    return YES;
}

- (BOOL)handleHostConfirm:(const uint8_t *)proof fd:(int)fd {
    uint8_t expected[RD_HASH_LEN];
    rd_pair_confirm(_pairKey, _pairTranscript, true, expected);
    if (!rd_equal(proof, expected, RD_HASH_LEN)) {
        NSLog(@"Screen3R: pairing confirmation invalid");
        [self postState:RDServerStateRefused detail:@"Pairing failed."];
        return NO;
    }
    _state = RDSessionPairAwaitLocal;
    return [self finishPairingIfApproved:fd];
}

- (BOOL)finishPairingIfApproved:(int)fd {
    @synchronized (self) {
        if (!_pairingApproved) return YES;   // keep waiting
        _pendingCode = nil;
    }
    NSData *key = [NSData dataWithBytes:_pairKey length:sizeof(_pairKey)];
    if (![_store setKey:key forHost:_hostID name:_hostName]) return NO;
    BOOL ok = [self completeSessionWithKey:_pairKey transcript:_pairTranscript
                                 replyType:RDMsgPairConfirm fd:fd];
    memset(_pairKey, 0, sizeof(_pairKey));
    return ok;
}

- (void)handleCursorPosition:(const uint8_t *)p length:(uint32_t)length {
    if (length < 5) return;
    int x = (int16_t)OSReadBigInt16(p, 0);
    int y = (int16_t)OSReadBigInt16(p, 2);
    BOOL visible = (p[4] & 1) != 0;
    BOOL hasSeq = length >= 9;   // newer hosts: last input movement included
    [self postCursorX:x y:y visible:visible hasSeq:hasSeq seq:(hasSeq ? OSReadBigInt32(p, 5) : 0)];
}

- (void)postCursorX:(int)x y:(int)y visible:(BOOL)visible hasSeq:(BOOL)hasSeq seq:(uint32_t)seq {
    void (^callback)(int, int, BOOL, BOOL, uint32_t) = self.onCursorPosition;
    if (!callback) return;
    dispatch_async(dispatch_get_main_queue(), ^{ callback(x, y, visible, hasSeq, seq); });
}

/// CURSOR_IMAGE carries raw BGRA pixels, so no image decoder (ImageIO, PDF…) ever sees
/// data from the network: those parsers get no more security fixes on old macOS versions.
- (void)handleCursorImage:(const uint8_t *)p length:(uint32_t)length {
    if (length < 12) return;
    int w = OSReadBigInt16(p, 0), h = OSReadBigInt16(p, 2);          // points
    int hotX = OSReadBigInt16(p, 4), hotY = OSReadBigInt16(p, 6);    // points, from top-left
    int pw = OSReadBigInt16(p, 8), ph = OSReadBigInt16(p, 10);       // pixels
    if (w < 1 || h < 1 || w > kMaxCursorPixels || h > kMaxCursorPixels) return;
    if (pw < 1 || ph < 1 || pw > kMaxCursorPixels || ph > kMaxCursorPixels) return;
    if (hotX > w || hotY > h) return;
    if ((uint64_t)length != 12 + (uint64_t)pw * (uint64_t)ph * 4) return;

    CFDataRef pixels = CFDataCreate(kCFAllocatorDefault, p + 12, (CFIndex)pw * ph * 4);
    if (!pixels) return;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
    CFRelease(pixels);
    if (!provider) return;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef cgImage = CGImageCreate(pw, ph, 8, 32, (size_t)pw * 4, space,
                                       kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst,
                                       provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    if (!cgImage) return;

    id image = (__bridge_transfer id)cgImage;   // ARC owns it from here
    NSSize size = NSMakeSize(w, h);
    NSPoint hotSpot = NSMakePoint(hotX, hotY);
    void (^callback)(id, NSSize, NSPoint) = self.onCursorImage;
    if (!callback) return;
    dispatch_async(dispatch_get_main_queue(), ^{ callback(image, size, hotSpot); });
}

- (void)handleFormat:(const uint8_t *)p length:(uint32_t)length {
    if (length < 2) return;
    int nalLength = p[0];
    size_t count = p[1];
    if (nalLength != 1 && nalLength != 2 && nalLength != 4) return;
    if (count < 1 || count > 8) return;

    const uint8_t *pointers[8];
    size_t sizes[8];
    size_t offset = 2;
    for (size_t i = 0; i < count; i++) {
        if (offset + 2 > length) return;
        uint16_t size = OSReadBigInt16(p, offset);
        offset += 2;
        if (offset + size > length) return;
        pointers[i] = p + offset;
        sizes[i] = size;
        offset += size;
    }

    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, count, pointers, sizes, nalLength, &format);
    if (status != noErr || !format) {
        NSLog(@"Screen3R: bad parameter sets (%d)", (int)status);
        return;
    }
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format);
    if (dims.width < 1 || dims.height < 1 || dims.width > kMaxVideoWidth || dims.height > kMaxVideoHeight) {
        NSLog(@"Screen3R: refusing video format %dx%d", dims.width, dims.height);
        CFRelease(format);
        return;
    }
    _nalLength = nalLength;
    if (_format && CMFormatDescriptionEqual(_format, format)) {
        CFRelease(format);   // same parameters as before: keep the decoder
        return;
    }
    if (_format) CFRelease(_format);
    _format = format;
    [self destroyDecoder];   // recreated with the new format on the next keyframe
}

#pragma mark - Decoder (decode queue)

- (void)createDecoder {
    if (_session || !_format) return;
    NSDictionary *spec = @{
        (__bridge NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES,
    };
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},   // zero-copy to the display layer
    };
    VTDecompressionOutputCallbackRecord callback = { didDecompress, NULL };
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, _format,
                                                   (__bridge CFDictionaryRef)spec,
                                                   (__bridge CFDictionaryRef)attributes,
                                                   &callback, &_session);
    if (status != noErr || !_session) {
        NSLog(@"Screen3R: VTDecompressionSessionCreate failed (%d), letting the layer decode", (int)status);
        _session = NULL;
        _hardwareDecoder = NO;
        return;
    }
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    CFBooleanRef hw = NULL;
    VTSessionCopyProperty(_session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                          kCFAllocatorDefault, &hw);
    _hardwareDecoder = (hw == kCFBooleanTrue);
    if (hw) CFRelease(hw);
    NSLog(@"Screen3R: H.264 decoder ready (%@)", _hardwareDecoder ? @"hardware" : @"software");
}

- (void)destroyDecoder {
    if (_session) {
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_imageFormat) {
        CFRelease(_imageFormat);
        _imageFormat = NULL;
    }
}

/// Decodes one compressed sample; returns a display-ready sample (+1) or NULL.
- (CMSampleBufferRef)decode:(CMSampleBufferRef)compressed {
    CVImageBufferRef image = NULL;
    VTDecodeInfoFlags info = 0;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    OSStatus status = VTDecompressionSessionDecodeFrame(_session, compressed, 0, &image, &info);
    VTDecompressionSessionWaitForAsynchronousFrames(_session);
    _statsDecodeSeconds += CFAbsoluteTimeGetCurrent() - start;
    _statsFrames++;
    if (status != noErr || !image) {
        if (image) CVBufferRelease(image);
        NSLog(@"Screen3R: decode failed (%d)", (int)status);
        return NULL;
    }

    if (!_imageFormat || !CMVideoFormatDescriptionMatchesImageBuffer(_imageFormat, image)) {
        if (_imageFormat) CFRelease(_imageFormat);
        _imageFormat = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image, &_imageFormat);
    }
    CMSampleBufferRef sample = NULL;
    if (_imageFormat) {
        CMSampleTimingInfo timing = { kCMTimeInvalid, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid };
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, _imageFormat, &timing, &sample);
    }
    CVBufferRelease(image);
    return sample;
}

- (void)sendStatsIfDue:(int)fd {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _statsStart < 1.0) return;
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    stats[@"frames"] = @(_statsFrames);
    if (_session) stats[@"hw"] = @(_hardwareDecoder);
    if (_statsFrames > 0) stats[@"decodeMs"] = @(_statsDecodeSeconds * 1000.0 / _statsFrames);
    NSData *json = [NSJSONSerialization dataWithJSONObject:stats options:0 error:NULL];
    if (json) [self send:fd type:RDMsgViewerStats payload:json.bytes length:(uint32_t)json.length];
    _statsStart = now;
    _statsFrames = 0;
    _statsDecodeSeconds = 0;
}

/// Decode queue. Returns NO if the connection should be dropped.
- (BOOL)handleFrame:(const uint8_t *)p length:(uint32_t)length fd:(int)fd {
    if (length < 13) return YES;
    uint8_t flags = p[0];
    uint32_t seq = OSReadBigInt32(p, 1);
    BOOL keyframe = (flags & 1) != 0;

    BOOL ok = [self displayFrame:p + 13 length:length - 13 keyframe:keyframe fd:fd];

    // Acknowledge after decoding: the host's flow control then follows our real speed.
    // Every frame is acknowledged, also ones we had to drop.
    uint8_t ack[4];
    OSWriteBigInt32(ack, 0, seq);
    if (![self send:fd type:RDMsgAck payload:ack length:sizeof(ack)]) return NO;
    [self sendStatsIfDue:fd];
    return ok;
}

/// Every NAL unit must be length-prefixed and the lengths must add up exactly.
- (BOOL)isWellFormedAVCC:(const uint8_t *)p length:(size_t)size {
    int prefix = _nalLength;
    if (prefix != 1 && prefix != 2 && prefix != 4) return NO;
    size_t offset = 0;
    while (offset < size) {
        if (size - offset < (size_t)prefix) return NO;
        size_t unit = 0;
        for (int k = 0; k < prefix; k++) unit = (unit << 8) | p[offset + k];
        offset += prefix;
        if (unit == 0 || unit > size - offset) return NO;
        offset += unit;
    }
    return offset == size;
}

- (BOOL)displayFrame:(const uint8_t *)nal length:(size_t)nalSize keyframe:(BOOL)keyframe fd:(int)fd {
    // A layer failure shows up on a later frame. After a flush only a keyframe can be shown again.
    if (_layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"Screen3R: display layer failed: %@", _layer.error);
        [_layer flush];
        _waitingForKeyframe = YES;
    }
    if (!_format || (_waitingForKeyframe && !keyframe)) {
        return [self requestKeyframe:fd];
    }
    if (nalSize == 0) return YES;
    if (![self isWellFormedAVCC:nal length:nalSize]) {
        NSLog(@"Screen3R: malformed frame dropped");
        _waitingForKeyframe = YES;
        return [self requestKeyframe:fd];
    }
    if (keyframe) [self createDecoder];

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, nalSize, kCFAllocatorDefault, NULL, 0, nalSize,
        kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status != kCMBlockBufferNoErr) return YES;
    CMBlockBufferReplaceDataBytes(nal, block, 0, nalSize);

    CMSampleBufferRef compressed = NULL;
    size_t sampleSize = nalSize;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format,
                                       1, 0, NULL, 1, &sampleSize, &compressed);
    CFRelease(block);
    if (status != noErr || !compressed) return YES;

    CMSampleBufferRef sample = NULL;
    if (_session) {
        sample = [self decode:compressed];
        CFRelease(compressed);
        if (!sample) {
            _waitingForKeyframe = YES;
            return [self requestKeyframe:fd];
        }
    } else {
        sample = compressed;   // fallback: the layer decodes by itself
        _statsFrames++;
    }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    [_layer enqueueSampleBuffer:sample];
    CFRelease(sample);

    if (_layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"Screen3R: display failed: %@", _layer.error);
        [_layer flush];
        _waitingForKeyframe = YES;
        return [self requestKeyframe:fd];
    }

    if (keyframe) _waitingForKeyframe = NO;
    if (!_hasPicture) {
        _hasPicture = YES;
        [self postState:RDServerStateStreaming detail:nil];
    }
    return YES;
}

- (BOOL)requestKeyframe:(int)fd {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastKeyframeRequest < 0.5) return YES;
    _lastKeyframeRequest = now;
    return [self send:fd type:RDMsgKeyframeRequest payload:NULL length:0];
}

/// Decode queue.
- (void)resetVideo {
    [self destroyDecoder];
    if (_format) {
        CFRelease(_format);
        _format = NULL;
    }
    _hasPicture = NO;
    _waitingForKeyframe = YES;
    // Same thread as -enqueueSampleBuffer:, so it cannot race with the next session.
    // This thread has no run loop to commit implicit CATransactions, so commit explicitly.
    [CATransaction begin];
    [_layer flushAndRemoveImage];
    [CATransaction commit];
}

@end
