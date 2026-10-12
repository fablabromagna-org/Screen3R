//
//  RDServer.h
//  Screen3R Viewer
//
//  Listens for the host on TCP (IPv4 + IPv6), advertises itself with Bonjour
//  and feeds received H.264 frames to an AVSampleBufferDisplayLayer.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, RDServerState) {
    RDServerStateWaiting,     // no host connected
    RDServerStateConnected,   // host connected and authenticated, no picture yet
    RDServerStateStreaming,   // picture on screen
    RDServerStatePairing,     // pairing: detail = 6-digit code (e.g. "123 456")
    RDServerStatePairingNeedsApproval,   // as above, and Return must be pressed on this Mac
    RDServerStateRefused,     // detail = reason (shown briefly)
};

/// How this Mac reacts to a PC connecting: @"always", @"sometimes" (default) or @"never"
/// (NSUserDefaults "cryMode"; set in the panel behind ⌃⌥⌘C). Any thread.
NSString *RDCryMode(void);

@interface RDServer : NSObject

/// Called on the main thread. `detail` is the host name (connected/streaming) or an error.
@property (nonatomic, copy) void (^onStateChange)(RDServerState state, NSString *detail);

/// Mouse pointer drawn locally (sent outside the video for low latency). Main thread.
/// Coordinates in stream pixels, origin top-left. `hasSeq`/`seq`: the last movement of this
/// Mac's mouse that the position includes (for local prediction).
@property (nonatomic, copy) void (^onCursorPosition)(int x, int y, BOOL visible, BOOL hasSeq, uint32_t seq);
/// The host accepts (or no longer accepts) this Mac's keyboard and mouse. Main thread.
@property (nonatomic, copy) void (^onInputControl)(BOOL enabled);
/// The host asked for a short sound (`cue` 1). At most once per session. Main thread.
@property (nonatomic, copy) void (^onCue)(uint8_t cue);
/// `image` is a CGImageRef (as id, ready for CALayer.contents). Size and hot spot in points,
/// hot spot measured from the top-left corner. Main thread.
@property (nonatomic, copy) void (^onCursorImage)(id image, NSSize size, NSPoint hotSpot);

- (instancetype)initWithLayer:(AVSampleBufferDisplayLayer *)layer
                  screenWidth:(int)width
                 screenHeight:(int)height
                        scale:(double)scale;

/// Binds the port and starts the accept thread. Call on the main thread.
- (BOOL)start:(NSError **)error;

/// The person at this Mac approved the pairing shown on screen (Return key). Any thread.
/// `code` is the code that was on screen (the `detail` of RDServerStatePairingNeedsApproval):
/// the approval applies only to that pairing attempt.
- (void)approvePendingPairingWithCode:(NSString *)code;

/// Keyboard & mouse of this Mac, forwarded to the host while it accepts them (any thread;
/// sent in order from a background queue, dropped when no session accepts input).
/// Movements in stream pixels; flags are NSEventModifierFlags (same bits as CGEventFlags).
- (void)sendMouseMoveSeq:(uint32_t)seq dx:(int16_t)dx dy:(int16_t)dy flags:(uint32_t)flags;
- (void)sendMouseButton:(uint8_t)button down:(BOOL)down clicks:(uint8_t)clicks flags:(uint32_t)flags;
- (void)sendScrollContinuous:(BOOL)continuous phase:(uint8_t)phase momentum:(uint8_t)momentum
                          dy:(int32_t)dy dx:(int32_t)dx flags:(uint32_t)flags;
- (void)sendKey:(uint16_t)keyCode down:(BOOL)down repeat:(BOOL)isRepeat
   keyboardType:(uint8_t)keyboardType flags:(uint32_t)flags;
/// Asks the host to release every key and button this Mac is holding.
- (void)sendInputReset;
/// Waits until every input message queued so far has been written (used when quitting).
- (void)flushInput;

@end
