#import <objc/objc.h>

@interface NSString
@end

@interface NSException
+ (void)raise:(NSString *)name format:(NSString *)format, ...;
@end

void *batata_objc_exception_probe(void *context)
{
    (void)context;
    [NSException raise:@"BatataProbe" format:@"closed Objective-C exception"];
    return NULL;
}
