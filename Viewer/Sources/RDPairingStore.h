//
//  RDPairingStore.h
//  Screen3R Viewer
//
//  Pairing keys of the Macs this viewer trusts, in
//  ~/Library/Application Support/Screen3R Viewer/pairings.plist (readable only by you).
//  Delete that file to forget all paired Macs.
//

#import <Foundation/Foundation.h>

@interface RDPairingStore : NSObject

/// This viewer's stable identifier (created on first launch).
@property (nonatomic, readonly) NSString *viewerID;
@property (nonatomic, readonly) NSUInteger pairedCount;

- (NSData *)keyForHost:(NSString *)hostID;
- (BOOL)setKey:(NSData *)key forHost:(NSString *)hostID name:(NSString *)name;

@end
