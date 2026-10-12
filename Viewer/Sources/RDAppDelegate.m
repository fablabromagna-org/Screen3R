//
//  RDAppDelegate.m
//  Screen3R Viewer
//
//  Full-screen black window with the video layer and a status overlay.
//
//  Keyboard & mouse: when the host accepts them, every key and mouse event of this Mac is
//  captured (a local event monitor, so menu shortcuts like ⌘Q go to the other Mac too; ⌘Tab
//  as well, via the presentation options) and forwarded. The mouse is detached from this
//  Mac's own pointer and sends movements, so it can travel to the other Mac's screens.
//  ⌃⌥⌘Q always quits the viewer. ⌃⌥⌘K pauses the capture (this Mac gets its keyboard and mouse
//  back, e.g. to answer a dialog); it also pauses by itself when another app's window opens on top
//  of the viewer. A click on the picture (or ⌃⌥⌘K again) resumes. The pointer is drawn ahead of the network: each movement
//  is applied at once on top of the last position the host confirmed (local prediction).
//

#import "RDAppDelegate.h"
#import "RDServer.h"
#import "RDProtocol.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static const NSApplicationPresentationOptions kPresentation =
    NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;

/// Mouse movements sent to the host whose effect it has not confirmed yet.
typedef struct { uint32_t seq; int dx, dy; } RDPendingMove;
#define RD_MAX_PENDING_MOVES 256

/// Left/right modifier keys -> their device-dependent bit in the event flags (IOLLEvent.h),
/// to tell from a "flags changed" event whether that key went down or up.
static NSEventModifierFlags modifierMaskForKey(unsigned short keyCode) {
    switch (keyCode) {
        case 59: return 0x0001;   // left control
        case 62: return 0x2000;   // right control
        case 56: return 0x0002;   // left shift
        case 60: return 0x0004;   // right shift
        case 55: return 0x0008;   // left command
        case 54: return 0x0010;   // right command
        case 58: return 0x0020;   // left option
        case 61: return 0x0040;   // right option
        // Not sent as keys: Caps Lock (posted events can't toggle it) and fn (on recent macOS
        // a lone fn press opens the emoji picker). Their state travels in the flags of every event.
        default: return 0;
    }
}

/// ⌃⌥⌘ + the key that types `letter` (any keyboard layout).
static BOOL isShortcut(NSEvent *event, NSString *letter) {
    NSEventModifierFlags want = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
    return event.type == NSEventTypeKeyDown && (event.modifierFlags & want) == want &&
           [[event.charactersIgnoringModifiers lowercaseString] isEqualToString:letter];
}
static BOOL isCryPanelShortcut(NSEvent *event) { return isShortcut(event, @"c"); }
static BOOL isPauseShortcut(NSEvent *event) { return isShortcut(event, @"k"); }

// Borderless windows refuse key status by default; we want ⌘Q and Return to work.
@interface RDWindow : NSWindow
@property (nonatomic, copy) void (^onReturn)(void);
@property (nonatomic, copy) void (^onCryPanel)(void);
/// ⌃⌥⌘K, or a click on the window: returns YES if it was used (resume the paused capture).
@property (nonatomic, copy) BOOL (^onResume)(NSEvent *event);
@end

@implementation RDWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)sendEvent:(NSEvent *)event {
    // Also sees the click that activates the app, which views don't get.
    if ((event.type == NSEventTypeLeftMouseDown || isPauseShortcut(event)) && self.onResume && self.onResume(event)) return;
    [super sendEvent:event];
}
- (void)keyDown:(NSEvent *)event {
    if (isCryPanelShortcut(event) && self.onCryPanel) {
        self.onCryPanel();
        return;
    }
    // Return or Enter: approve a pairing request shown on screen.
    if ((event.keyCode == 36 || event.keyCode == 76) && self.onReturn) {
        self.onReturn();
        return;
    }
    [super keyDown:event];
}
@end

@implementation RDAppDelegate {
    RDWindow *_window;
    AVSampleBufferDisplayLayer *_videoLayer;
    NSView *_cursorView;
    CALayer *_cursorLayer;
    int _streamWidth, _streamHeight;
    NSTextField *_overlay;
    RDServer *_server;
    id<NSObject> _activity;
    IOPMAssertionID _systemSleepAssertion;
    IOPMAssertionID _displaySleepAssertion;
    BOOL _cursorHidden;
    BOOL _awaitingApproval;
    NSString *_approvalCode;   // code on screen while _awaitingApproval
    NSString *_notice;   // shown on the waiting screen (e.g. why the last attempt failed)
    NSString *_hostName;

    // Keyboard & mouse capture
    BOOL _streaming;
    BOOL _inputEnabled;      // the host accepts our input
    BOOL _capturing;
    BOOL _panelOpen;         // the ⌃⌥⌘C panel is on screen: this Mac keeps its keyboard and mouse
    BOOL _inputPaused;       // ⌃⌥⌘K or another app's window: keyboard and mouse back to this Mac
    NSTimer *_windowWatch;   // while capturing: looks for other apps' windows above the viewer
    NSSet<NSNumber *> *_knownWindows;
    id _eventMonitor;
    double _accX, _accY;     // sub-pixel remainders of mouse movements
    uint32_t _moveSeq;

    // Pointer: last position confirmed by the host + movements not confirmed yet
    int _hostX, _hostY;
    BOOL _hostVisible;
    RDPendingMove _pending[RD_MAX_PENDING_MOVES];
    int _pendingCount;

    NSView *_toastView;
    NSTextField *_toast;
    NSUInteger _toastToken;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenu];
    [self buildWindow];

    // Never let App Nap or idle sleep throttle us while the viewer is open.
    _activity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
                          reason:@"Receiving a display stream"];
    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn,
                                CFSTR("Screen3R Viewer is waiting for a Mac"), &_systemSleepAssertion);

    NSScreen *screen = _window.screen ?: [NSScreen mainScreen];
    // v0.1: always a 1x (non-Retina) display, sized in points.
    int width = (int)lround(screen.frame.size.width);
    int height = (int)lround(screen.frame.size.height);

    _streamWidth = width;
    _streamHeight = height;
    _server = [[RDServer alloc] initWithLayer:_videoLayer screenWidth:width screenHeight:height
                                        scale:screen.backingScaleFactor];
    __weak RDAppDelegate *weakSelf = self;
    _server.onStateChange = ^(RDServerState state, NSString *detail) {
        [weakSelf serverStateChanged:state detail:detail];
    };
    _server.onCursorImage = ^(id image, NSSize size, NSPoint hotSpot) {
        [weakSelf setCursorImage:image size:size hotSpot:hotSpot];
    };
    _server.onCursorPosition = ^(int x, int y, BOOL visible, BOOL hasSeq, uint32_t seq) {
        [weakSelf hostCursorX:x y:y visible:visible hasSeq:hasSeq seq:seq];
    };
    _server.onInputControl = ^(BOOL enabled) {
        [weakSelf inputControlChanged:enabled];
    };
    _server.onCue = ^(uint8_t cue) {
        // Some hosts like to let the old Mac express its feelings.
        if ([RDCryMode() isEqualToString:@"never"]) return;
        NSSound *sound = [NSSound soundNamed:@"cry"];
        [sound stop];
        [sound play];
    };
    _window.onReturn = ^{ [weakSelf returnPressed]; };
    _window.onCryPanel = ^{ [weakSelf showCryPanel]; };
    _window.onResume = ^BOOL(NSEvent *event) { return [weakSelf resumeInputWithEvent:event]; };

    NSError *error = nil;
    if (![_server start:&error]) {
        [self showOverlay:[NSString stringWithFormat:@"Screen3R Viewer\n\n%@\n\n⌘Q to quit",
                           error.localizedDescription]];
        return;
    }
    [self serverStateChanged:RDServerStateWaiting detail:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self updateCapture];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    [self updateCapture];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopCapture];     // gives the pointer back to this Mac
    [_server flushInput];   // the "release everything" message goes out before we exit
}

#pragma mark - UI

- (void)buildMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Screen3R Viewer" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [NSApp setMainMenu:mainMenu];
}

- (void)buildWindow {
    NSScreen *screen = [NSScreen mainScreen];
    NSRect frame = screen.frame;

    _window = [[RDWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO
                                             screen:screen];
    _window.backgroundColor = [NSColor blackColor];
    _window.releasedWhenClosed = NO;
    _window.acceptsMouseMovedEvents = YES;   // needed to forward mouse movements
    [_window setFrame:frame display:NO];

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    content.wantsLayer = YES;
    content.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    _window.contentView = content;

    NSView *videoView = [[NSView alloc] initWithFrame:content.bounds];
    videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    videoView.wantsLayer = YES;
    _videoLayer = [[AVSampleBufferDisplayLayer alloc] init];
    _videoLayer.frame = videoView.bounds;
    _videoLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _videoLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    [videoView.layer addSublayer:_videoLayer];
    [content addSubview:videoView];

    // The mouse pointer is drawn here, above the video, from separate position messages.
    _cursorView = [[NSView alloc] initWithFrame:content.bounds];
    _cursorView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _cursorView.wantsLayer = YES;
    _cursorLayer = [CALayer layer];
    _cursorLayer.hidden = YES;
    _cursorLayer.contentsGravity = kCAGravityResize;
    _cursorLayer.anchorPoint = CGPointMake(0, 1);
    [_cursorView.layer addSublayer:_cursorLayer];
    [content addSubview:_cursorView];

    _overlay = [NSTextField wrappingLabelWithString:@""];
    _overlay.alignment = NSTextAlignmentCenter;
    _overlay.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    _overlay.font = [NSFont systemFontOfSize:22 weight:NSFontWeightRegular];
    _overlay.frame = NSMakeRect(frame.size.width * 0.15, frame.size.height * 0.25,
                                frame.size.width * 0.7, frame.size.height * 0.5);
    _overlay.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [content addSubview:_overlay];   // added after the video view, so it is on top

    // Short notices at the bottom of the screen (keyboard & mouse on/off).
    _toastView = [[NSView alloc] initWithFrame:NSZeroRect];
    _toastView.wantsLayer = YES;
    _toastView.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:0.85].CGColor;
    _toastView.layer.cornerRadius = 10;
    _toastView.hidden = YES;
    _toast = [NSTextField labelWithString:@""];
    _toast.textColor = [NSColor colorWithWhite:0.95 alpha:1.0];
    _toast.font = [NSFont systemFontOfSize:16 weight:NSFontWeightRegular];
    [_toastView addSubview:_toast];
    [content addSubview:_toastView];

    [NSApp setPresentationOptions:kPresentation];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showOverlay:(NSString *)text {
    _overlay.stringValue = text;
    _overlay.hidden = NO;
}

- (void)serverStateChanged:(RDServerState)state detail:(NSString *)detail {
    switch (state) {
        case RDServerStateWaiting: {
            _streaming = NO;
            _inputEnabled = NO;
            _inputPaused = NO;
            _hostName = nil;
            [self updateCapture];
            [self setDisplaySleepAllowed:YES];
            [self setCursorHidden:NO];
            NSString *name = [[NSHost currentHost] localizedName] ?: @"this Mac";
            NSString *addresses = [[self localIPv4Addresses] componentsJoinedByString:@"  ·  "];
            if (addresses.length == 0) addresses = @"no network connection";
            _awaitingApproval = NO;
            NSString *notice = _notice ? [NSString stringWithFormat:@"%@\n\n", _notice] : @"";
            [self showOverlay:[NSString stringWithFormat:
                @"Screen3R Viewer\n\n"
                @"%@"
                @"Waiting for a Mac…\n\n"
                @"This screen: %@\n%@\n\n"
                @"On your Mac, click the Screen3R icon in the menu bar and choose this screen.\n\n"
                @"⌘Q to quit",
                notice, name, addresses]];
            break;
        }
        case RDServerStateConnected:
            _awaitingApproval = NO;
            _notice = nil;
            _hostName = detail;
            [self setDisplaySleepAllowed:NO];
            [self showOverlay:[NSString stringWithFormat:@"Connected to %@\n\nStarting…", detail]];
            break;
        case RDServerStateStreaming:
            _overlay.hidden = YES;
            [self setCursorHidden:YES];
            _streaming = YES;
            [self updateCapture];
            break;
        case RDServerStatePairing:
            _awaitingApproval = NO;
            [self setDisplaySleepAllowed:NO];
            [self showOverlay:[NSString stringWithFormat:
                @"Pairing with a Mac\n\n%@\n\n"
                @"Check that your Mac shows the same code, then confirm there.", detail]];
            break;
        case RDServerStatePairingNeedsApproval:
            _awaitingApproval = YES;
            _approvalCode = detail;
            [self setDisplaySleepAllowed:NO];
            [self showOverlay:[NSString stringWithFormat:
                @"A Mac wants to pair with this screen\n\n%@\n\n"
                @"If it shows the same code, confirm on that Mac and press Return here.\n"
                @"If you don't know this Mac, just wait: the request expires.", detail]];
            break;
        case RDServerStateRefused:
            _notice = detail.length ? detail : nil;
            break;
    }
}

#pragma mark - How this Mac takes it (not documented)

/// ⌃⌥⌘C: when a PC connects, the PC may show "Every time you do this, your iMac cries." and this
/// Mac then cries. Here the iMac decides how often (the PC reads it from our HELLO).
- (void)showCryPanel {
    if (_panelOpen) return;
    _panelOpen = YES;
    [self updateCapture];          // keyboard and mouse back to this Mac while the panel is open
    [self setCursorHidden:NO];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"How should this iMac take it?";
    alert.informativeText = @"When a Windows PC connects to this screen, the iMac…";
    alert.icon = [NSApp applicationIconImage];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSArray<NSString *> *modes = @[@"always", @"sometimes", @"never"];
    NSArray<NSString *> *titles = @[@"Cries every time", @"Cries now and then", @"Suffers in silence"];
    NSString *current = RDCryMode();
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 112)];
    NSMutableArray<NSButton *> *radios = [NSMutableArray array];
    for (NSUInteger i = 0; i < modes.count; i++) {
        // Radio buttons with the same superview and action form one group.
        NSButton *radio = [NSButton radioButtonWithTitle:titles[i] target:self action:@selector(cryModeRadio:)];
        radio.frame = NSMakeRect(0, 88 - 26 * (CGFloat)i, 260, 22);
        radio.state = [modes[i] isEqualToString:current] ? NSControlStateValueOn : NSControlStateValueOff;
        [box addSubview:radio];
        [radios addObject:radio];
    }
    NSButton *listen = [NSButton buttonWithTitle:@"▶︎ Listen" target:self action:@selector(playCry:)];
    [listen sizeToFit];
    listen.frame = NSMakeRect(0, 0, NSWidth(listen.frame) + 12, NSHeight(listen.frame));
    [box addSubview:listen];
    alert.accessoryView = box;

    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        for (NSUInteger i = 0; i < modes.count; i++) {
            if (radios[i].state == NSControlStateValueOn) {
                [[NSUserDefaults standardUserDefaults] setObject:modes[i] forKey:@"cryMode"];
            }
        }
    }
    _panelOpen = NO;
    [self setCursorHidden:_streaming];   // as for the current state (it may have changed meanwhile; paused: shown)
    [self updateCapture];
    [_window makeKeyAndOrderFront:nil];
}

- (void)cryModeRadio:(NSButton *)sender {
    // Nothing to do: the choice is read when the panel closes.
}

- (void)playCry:(id)sender {
    NSSound *sound = [NSSound soundNamed:@"cry"];
    [sound stop];
    [sound play];
}

- (void)returnPressed {
    if (!_awaitingApproval) return;
    _awaitingApproval = NO;
    [_server approvePendingPairingWithCode:_approvalCode];
    [self showOverlay:@"Pairing approved on this Mac.\n\nWaiting for confirmation on the other Mac…"];
}

#pragma mark - Local mouse pointer

/// Where the video is drawn inside the window (aspect fit, like the video layer).
- (NSRect)videoRect {
    NSRect bounds = _cursorView.bounds;
    if (_streamWidth <= 0 || _streamHeight <= 0) return bounds;
    return AVMakeRectWithAspectRatioInsideRect(NSMakeSize(_streamWidth, _streamHeight), bounds);
}

- (void)setCursorImage:(id)image size:(NSSize)size hotSpot:(NSPoint)hotSpot {
    NSRect video = [self videoRect];
    CGFloat scale = _streamWidth > 0 ? video.size.width / _streamWidth : 1.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _cursorLayer.contents = image;
    _cursorLayer.bounds = CGRectMake(0, 0, size.width * scale, size.height * scale);
    // Layer coordinates are bottom-up; the hot spot is measured from the top.
    _cursorLayer.anchorPoint = CGPointMake(hotSpot.x / size.width, 1.0 - hotSpot.y / size.height);
    [CATransaction commit];
}

/// A position from the host. With `hasSeq`, it already includes our movements up to `seq`:
/// those are no longer pending.
- (void)hostCursorX:(int)x y:(int)y visible:(BOOL)visible hasSeq:(BOOL)hasSeq seq:(uint32_t)seq {
    _hostX = x;
    _hostY = y;
    _hostVisible = visible;
    if (hasSeq) {
        int keep = 0;
        for (int i = 0; i < _pendingCount; i++) {
            if ((int32_t)(_pending[i].seq - seq) > 0) _pending[keep++] = _pending[i];
        }
        _pendingCount = keep;
    }
    [self redrawCursor];
}

/// Draws the pointer where the host last saw it plus our pending movements. While the pointer
/// is on another screen of the other Mac we can't know where it is: it reappears as soon as
/// the host reports it back on this screen.
- (void)redrawCursor {
    int x = _hostX, y = _hostY;
    for (int i = 0; i < _pendingCount; i++) {
        x += _pending[i].dx;
        y += _pending[i].dy;
    }
    x = MAX(0, MIN(_streamWidth - 1, x));
    y = MAX(0, MIN(_streamHeight - 1, y));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];   // no implicit animation: move instantly
    BOOL show = _hostVisible && _cursorLayer.contents != nil && _overlay.hidden
                && _streamWidth > 0 && _streamHeight > 0;
    _cursorLayer.hidden = !show;
    if (show) {
        NSRect video = [self videoRect];
        CGFloat sx = video.size.width / _streamWidth;
        CGFloat sy = video.size.height / _streamHeight;
        _cursorLayer.position = CGPointMake(NSMinX(video) + x * sx, NSMaxY(video) - y * sy);
    }
    [CATransaction commit];
}

#pragma mark - Keyboard & mouse capture

- (void)inputControlChanged:(BOOL)enabled {
    if (enabled == _inputEnabled) return;
    _inputEnabled = enabled;
    if (!enabled) [self setInputPaused:NO];
    if (!enabled && _capturing && _streaming) {
        [self showToast:[NSString stringWithFormat:@"This Mac's keyboard and mouse no longer control %@.",
                         _hostName ?: @"the other Mac"]];
    }
    [self updateCapture];
}

- (void)updateCapture {
    BOOL want = _inputEnabled && _streaming && [NSApp isActive] && !_panelOpen && !_inputPaused;
    if (want && !_capturing) [self startCapture];
    else if (!want && _capturing) [self stopCapture];
}

- (void)startCapture {
    _capturing = YES;
    _accX = _accY = 0;
    _pendingCount = 0;
    // Detach the mouse from this Mac's (hidden) pointer: it keeps sending movements, the
    // pointer stays put in the middle of the screen, away from hot corners.
    NSScreen *screen = _window.screen ?: [NSScreen mainScreen];
    NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
    CGRect bounds = CGDisplayBounds(screenNumber ? (CGDirectDisplayID)screenNumber.unsignedIntValue
                                                 : CGMainDisplayID());   // global coordinates
    CGWarpMouseCursorPosition(CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)));
    CGAssociateMouseAndMouseCursorPosition(false);
    // ⌘Tab reaches the app (and is forwarded) instead of switching apps on this Mac.
    [NSApp setPresentationOptions:kPresentation | NSApplicationPresentationDisableProcessSwitching];

    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged
        | NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged
        | NSEventMaskOtherMouseDragged | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp
        | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown
        | NSEventMaskOtherMouseUp | NSEventMaskScrollWheel;
    __weak RDAppDelegate *weakSelf = self;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        RDAppDelegate *strongSelf = weakSelf;
        return strongSelf ? [strongSelf capturedEvent:event] : event;
    }];
    [self showToast:[NSString stringWithFormat:@"This Mac's keyboard and mouse now control %@.     ⌃⌥⌘K: back to this Mac   ·   ⌃⌥⌘Q: quit",
                     _hostName ?: @"the other Mac"]];
    // Windows of other apps (an alert, a dialog…) that are already above the viewer don't count.
    _knownWindows = [self windowsAboveViewer];
    _windowWatch = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(watchWindows:)
                                                  userInfo:nil repeats:YES];
}

#pragma mark - Pause (⌃⌥⌘K, or another app's window)

/// Other apps' ordinary windows (alerts, dialogs, panels) on screen above the viewer.
/// The Dock, the menu bar, notification banners and the like are left out.
- (NSSet<NSNumber *> *)windowsAboveViewer {
    NSMutableSet *result = [NSMutableSet set];
    if (_window.windowNumber <= 0) return result;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenAboveWindow | kCGWindowListExcludeDesktopElements,
                                                 (CGWindowID)_window.windowNumber);
    if (!list) return result;
    pid_t me = [NSProcessInfo processInfo].processIdentifier;
    for (NSDictionary *info in (__bridge NSArray *)list) {
        NSNumber *pid = info[(__bridge NSString *)kCGWindowOwnerPID];
        NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
        NSNumber *number = info[(__bridge NSString *)kCGWindowNumber];
        NSNumber *alpha = info[(__bridge NSString *)kCGWindowAlpha];
        NSString *owner = info[(__bridge NSString *)kCGWindowOwnerName];
        CGRect bounds = CGRectZero;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], &bounds);
        if (!number || pid.intValue == me) continue;
        if (layer.intValue < 0 || layer.intValue >= kCGDockWindowLevel) continue;   // Dock, menu bar, overlays
        if (alpha && alpha.doubleValue < 0.1) continue;
        if (bounds.size.width < 80 || bounds.size.height < 40) continue;
        if ([owner isEqualToString:@"NotificationCenter"] || [owner isEqualToString:@"Window Server"]) continue;
        [result addObject:number];
    }
    CFRelease(list);
    return result;
}

- (void)watchWindows:(NSTimer *)timer {
    if (!_capturing) return;
    NSMutableSet *fresh = [[self windowsAboveViewer] mutableCopy];
    [fresh minusSet:_knownWindows ?: [NSSet set]];
    if (fresh.count == 0) return;
    [self setInputPaused:YES];
    [self showToast:[NSString stringWithFormat:@"A window opened on this Mac: its keyboard and mouse are back here.     "
                     @"Click the picture or press ⌃⌥⌘K to control %@ again.", _hostName ?: @"the other Mac"]];
}

- (void)setInputPaused:(BOOL)paused {
    if (paused == _inputPaused) return;
    _inputPaused = paused;
    [self updateCapture];
    // While paused this Mac's own pointer is needed (to click dialogs).
    [self setCursorHidden:_streaming && !paused];
}

/// From the window: ⌃⌥⌘K toggles; while paused, a click on the picture resumes (and is used up).
- (BOOL)resumeInputWithEvent:(NSEvent *)event {
    if (isPauseShortcut(event)) {
        if (!_inputEnabled || !_streaming) return NO;
        if (_inputPaused) {
            [self setInputPaused:NO];
        } else {
            [self setInputPaused:YES];
            [self showToast:[NSString stringWithFormat:@"Keyboard and mouse back on this Mac.     "
                             @"Click the picture or press ⌃⌥⌘K to control %@ again.", _hostName ?: @"the other Mac"]];
        }
        return YES;
    }
    if (_inputPaused && _inputEnabled && _streaming && !_panelOpen) {
        [NSApp activateIgnoringOtherApps:YES];
        [self setInputPaused:NO];
        return YES;
    }
    return NO;
}

- (void)stopCapture {
    if (!_capturing) return;
    _capturing = NO;
    [_windowWatch invalidate];
    _windowWatch = nil;
    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _eventMonitor = nil;
    }
    CGAssociateMouseAndMouseCursorPosition(true);
    [NSApp setPresentationOptions:kPresentation];
    [_server sendInputReset];   // nothing we pressed stays down on the other Mac
    _pendingCount = 0;
    [self redrawCursor];
}

/// Local event monitor: forwards the event and swallows it (returns nil), so this Mac
/// does nothing with it, menu shortcuts included.
- (NSEvent *)capturedEvent:(NSEvent *)event {
    // Modifier flags: device-independent ones plus the left/right bits (same values as CGEventFlags).
    uint32_t flags = (uint32_t)(event.modifierFlags & (NSEventModifierFlagDeviceIndependentFlagsMask | 0x207F));
    switch (event.type) {
        case NSEventTypeKeyDown: {
            if (isCryPanelShortcut(event)) {
                // Open it after the monitor returns: it stops the capture, which removes the monitor.
                dispatch_async(dispatch_get_main_queue(), ^{ [self showCryPanel]; });
                return nil;
            }
            if (isPauseShortcut(event)) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self resumeInputWithEvent:event]; });
                return nil;
            }
            NSEventModifierFlags quit = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
            if ((event.modifierFlags & quit) == quit &&
                [[event.charactersIgnoringModifiers lowercaseString] isEqualToString:@"q"]) {
                [NSApp terminate:nil];
                return nil;
            }
            [_server sendKey:event.keyCode down:YES repeat:event.isARepeat
                keyboardType:[self keyboardTypeOf:event] flags:flags];
            return nil;
        }
        case NSEventTypeKeyUp:
            [_server sendKey:event.keyCode down:NO repeat:NO keyboardType:[self keyboardTypeOf:event] flags:flags];
            return nil;
        case NSEventTypeFlagsChanged: {
            NSEventModifierFlags mask = modifierMaskForKey(event.keyCode);
            if (mask) {
                [_server sendKey:event.keyCode down:(event.modifierFlags & mask) != 0 repeat:NO
                    keyboardType:[self keyboardTypeOf:event] flags:flags];
            }
            return nil;
        }
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged:
            [self capturedMove:event flags:flags];
            return nil;
        case NSEventTypeLeftMouseDown:
        case NSEventTypeRightMouseDown:
        case NSEventTypeOtherMouseDown:
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseUp: {
            BOOL down = event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown
                     || event.type == NSEventTypeOtherMouseDown;
            NSInteger clicks = MAX(1, MIN(3, event.clickCount));
            [_server sendMouseButton:(uint8_t)MAX(0, MIN(31, event.buttonNumber)) down:down
                              clicks:(uint8_t)clicks flags:flags];
            return nil;
        }
        case NSEventTypeScrollWheel: {
            CGEventRef cg = event.CGEvent;
            if (!cg) return nil;
            BOOL continuous = CGEventGetIntegerValueField(cg, kCGScrollWheelEventIsContinuous) != 0;
            int64_t dy = CGEventGetIntegerValueField(cg, continuous ? kCGScrollWheelEventPointDeltaAxis1
                                                                    : kCGScrollWheelEventDeltaAxis1);
            int64_t dx = CGEventGetIntegerValueField(cg, continuous ? kCGScrollWheelEventPointDeltaAxis2
                                                                    : kCGScrollWheelEventDeltaAxis2);
            int64_t phase = CGEventGetIntegerValueField(cg, kCGScrollWheelEventScrollPhase);
            int64_t momentum = CGEventGetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase);
            [_server sendScrollContinuous:continuous phase:(uint8_t)MAX(0, MIN(255, phase))
                                 momentum:(uint8_t)MAX(0, MIN(255, momentum))
                                       dy:(int32_t)MAX(-10000, MIN(10000, dy))
                                       dx:(int32_t)MAX(-10000, MIN(10000, dx)) flags:flags];
            return nil;
        }
        default:
            return event;
    }
}

/// Mouse movement: whole pixels go out (the remainder is kept for the next one) and the
/// pointer moves here at once, without waiting for the other Mac.
- (void)capturedMove:(NSEvent *)event flags:(uint32_t)flags {
    // Points = stream pixels (1x display). Read from the CGEvent: positive y is down there,
    // like in the stream.
    CGEventRef cg = event.CGEvent;
    _accX += cg ? CGEventGetDoubleValueField(cg, kCGMouseEventDeltaX) : event.deltaX;
    _accY += cg ? CGEventGetDoubleValueField(cg, kCGMouseEventDeltaY) : event.deltaY;
    int dx = (int)_accX, dy = (int)_accY;
    if (dx == 0 && dy == 0) return;
    _accX -= dx;
    _accY -= dy;
    dx = MAX(-30000, MIN(30000, dx));
    dy = MAX(-30000, MIN(30000, dy));

    uint32_t seq = ++_moveSeq;
    if (_pendingCount == RD_MAX_PENDING_MOVES) {   // the host stopped answering: forget the oldest
        memmove(_pending, _pending + 1, sizeof(RDPendingMove) * (RD_MAX_PENDING_MOVES - 1));
        _pendingCount--;
    }
    _pending[_pendingCount++] = (RDPendingMove){ seq, dx, dy };
    [_server sendMouseMoveSeq:seq dx:(int16_t)dx dy:(int16_t)dy flags:flags];
    [self redrawCursor];
}

/// The keyboard type (ANSI, ISO, JIS…) lets the other Mac map the keys next to Shift and
/// below Esc correctly on international keyboards.
- (uint8_t)keyboardTypeOf:(NSEvent *)event {
    CGEventRef cg = event.CGEvent;
    int64_t type = cg ? CGEventGetIntegerValueField(cg, kCGKeyboardEventKeyboardType) : 0;
    return (uint8_t)MAX(0, MIN(255, type));
}

- (void)showToast:(NSString *)text {
    _toast.stringValue = text;
    [_toast sizeToFit];
    NSSize textSize = _toast.frame.size;
    NSRect bounds = _window.contentView.bounds;
    NSSize size = NSMakeSize(textSize.width + 40, textSize.height + 22);
    _toastView.frame = NSMakeRect(round((NSWidth(bounds) - size.width) / 2), 60, size.width, size.height);
    [_toast setFrameOrigin:NSMakePoint(20, 11)];
    _toastView.hidden = NO;
    NSUInteger token = ++_toastToken;
    __weak RDAppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        RDAppDelegate *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_toastToken == token) strongSelf->_toastView.hidden = YES;
    });
}

// NSCursor hide/unhide calls must be balanced.
- (void)setCursorHidden:(BOOL)hidden {
    if (_panelOpen || _inputPaused) hidden = NO;   // the ⌃⌥⌘C panel / a dialog needs the pointer
    if (hidden == _cursorHidden) return;
    _cursorHidden = hidden;
    if (hidden) [NSCursor hide]; else [NSCursor unhide];
}

- (void)setDisplaySleepAllowed:(BOOL)allowed {
    if (allowed && _displaySleepAssertion) {
        IOPMAssertionRelease(_displaySleepAssertion);
        _displaySleepAssertion = 0;
    } else if (!allowed && !_displaySleepAssertion) {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelOn,
                                    CFSTR("Screen3R Viewer is showing a stream"), &_displaySleepAssertion);
    }
}

- (NSArray<NSString *> *)localIPv4Addresses {
    NSMutableArray *result = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return result;
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
        if ((i->ifa_flags & IFF_LOOPBACK) || !(i->ifa_flags & IFF_UP)) continue;
        char buf[INET_ADDRSTRLEN];
        const struct sockaddr_in *sin = (const struct sockaddr_in *)i->ifa_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
            NSString *ip = [NSString stringWithUTF8String:buf];
            if (![ip hasPrefix:@"169.254."]) [result addObject:ip];
        }
    }
    freeifaddrs(list);
    return result;
}

@end
