// CloudKit-only Objective-C shim. Compiles to empty on non-Apple platforms
// so SwiftPM can still walk this target in the manifest without dragging
// `Foundation/Foundation.h` into the Linux build.
#if __APPLE__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps an Objective-C `@try/@catch` so a Swift caller can detect whether
/// a block raised an `NSException`. Swift's own `do/catch` only handles
/// types conforming to `Error` and will let `NSException` terminate the
/// process — this shim is the only way to guard CKContainer construction
/// on a process without a valid CloudKit entitlement.
@interface ExceptionCatcher : NSObject
+ (nullable NSException *)catchException:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
#endif
