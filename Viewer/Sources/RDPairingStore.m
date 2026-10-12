//
//  RDPairingStore.m
//  Screen3R Viewer
//

#import "RDPairingStore.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

@implementation RDPairingStore {
    NSString *_path;
    NSMutableDictionary *_hosts;   // hostID -> { key: NSData, name: NSString, paired: NSDate }
    NSString *_viewerID;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                                inDomain:NSUserDomainMask
                                                       appropriateForURL:nil create:YES error:NULL];
        NSString *dir = [support.path stringByAppendingPathComponent:@"Screen3R Viewer"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0700} error:NULL];
        _path = [dir stringByAppendingPathComponent:@"pairings.plist"];

        NSDictionary *stored = nil;
        NSData *data = [NSData dataWithContentsOfFile:_path];
        if (data) {
            stored = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                                format:NULL error:NULL];
        }
        if (![stored isKindOfClass:[NSDictionary class]]) stored = nil;
        NSString *viewerID = stored[@"viewerID"];
        NSDictionary *hosts = stored[@"hosts"];
        _viewerID = [viewerID isKindOfClass:[NSString class]] && viewerID.length ? viewerID
                                                                                  : [NSUUID UUID].UUIDString;
        _hosts = [hosts isKindOfClass:[NSDictionary class]] ? [hosts mutableCopy] : [NSMutableDictionary dictionary];
        if (!stored) [self save];
    }
    return self;
}

- (NSString *)viewerID { return _viewerID; }
- (NSUInteger)pairedCount { return _hosts.count; }

- (NSData *)keyForHost:(NSString *)hostID {
    NSDictionary *entry = _hosts[hostID];
    NSData *key = [entry isKindOfClass:[NSDictionary class]] ? entry[@"key"] : nil;
    return [key isKindOfClass:[NSData class]] && key.length == 32 ? key : nil;
}

- (BOOL)setKey:(NSData *)key forHost:(NSString *)hostID name:(NSString *)name {
    _hosts[hostID] = @{ @"key": key, @"name": name ?: @"", @"paired": [NSDate date] };
    return [self save];
}

- (BOOL)save {
    NSDictionary *plist = @{ @"viewerID": _viewerID, @"hosts": _hosts };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:NULL];
    if (!data) return NO;
    // Create the file with owner-only permissions before any secret is written into it.
    if (![[NSFileManager defaultManager] fileExistsAtPath:_path]) {
        int fd = open(_path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd >= 0) close(fd);
    }
    chmod(_path.fileSystemRepresentation, 0600);
    BOOL ok = [data writeToFile:_path options:0 error:NULL];   // in place: keeps the 0600 mode
    if (!ok) NSLog(@"Screen3R: could not save pairings to %@", _path);
    return ok;
}

@end
