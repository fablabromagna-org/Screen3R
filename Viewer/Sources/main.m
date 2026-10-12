//
//  main.m
//  Screen3R Viewer — runs on the old Mac (macOS 10.13 High Sierra or later).
//

#import <Cocoa/Cocoa.h>
#import "RDAppDelegate.h"

// NSApplication.delegate is not a strong reference, and ARC may release a local
// after its last use, so keep the delegate alive for the whole run.
static RDAppDelegate *gDelegate;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        gDelegate = [[RDAppDelegate alloc] init];
        app.delegate = gDelegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
