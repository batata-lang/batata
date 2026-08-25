#import <objc/objc.h>
#include <stdint.h>

@interface NSString
- (const char *)UTF8String;
@end

@interface NSException
@property (readonly, copy) NSString *name;
@property (nullable, readonly, copy) NSString *reason;
@end

typedef void *(*BatataObjCInvoke)(void *context);

int32_t batata_objc_exception_fence(
    BatataObjCInvoke invoke,
    void *context,
    void **result,
    const char **name,
    const char **reason)
{
    @try {
        *result = invoke(context);
        *name = NULL;
        *reason = NULL;
        return 0;
    } @catch (NSException *exception) {
        *result = NULL;
        *name = exception.name.UTF8String;
        *reason = exception.reason.UTF8String;
        return -1;
    }
}
