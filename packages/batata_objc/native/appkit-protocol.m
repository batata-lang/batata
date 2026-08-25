#import <objc/objc.h>

@class NSApplication;
@class NSNotification;

@protocol NSApplicationDelegate
@optional
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender;
@end

Protocol *batata_objc_ns_application_delegate_protocol(void)
{
    return @protocol(NSApplicationDelegate);
}
