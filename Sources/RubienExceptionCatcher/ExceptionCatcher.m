#import "ExceptionCatcher.h"

@implementation ExceptionCatcher
+ (nullable NSException *)catchException:(NS_NOESCAPE void (^)(void))block {
    @try { block(); return nil; }
    @catch (NSException *e) { return e; }
}
@end
