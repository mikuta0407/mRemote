#import "mr_mac_window_close.h"
#import <objc/message.h>
#import <objc/runtime.h>

/* UIKit offers no way to stop a Mac window from closing: a scene is simply
 * destroyed. AppKit's NSWindow -performClose: is what the close button and
 * File > Close send, so it is replaced here, by name, as Catalyst cannot import
 * AppKit. Catalyst's NSWindow lists the UIWindows it hosts as -_uiWindows; a
 * window without it closes as before. */

static MRMacWindowCloseHandler mr_close_handler;
static IMP mr_original_perform_close;

static void mr_perform_close(id self, SEL _cmd, id sender) {
    SEL hosted = NSSelectorFromString(@"_uiWindows");
    if (mr_close_handler != nil && [self respondsToSelector:hosted]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(self, hosted);
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        if ([value conformsToProtocol:@protocol(NSFastEnumeration)]) {
            for (id window in (id<NSFastEnumeration>)value) {
                if ([window isKindOfClass:[UIWindow class]]) {
                    [windows addObject:window];
                }
            }
        }
        if (windows.count > 0 && !mr_close_handler(windows)) {
            return;
        }
    }
    ((void (*)(id, SEL, id))mr_original_perform_close)(self, _cmd, sender);
}

void mr_mac_window_close_guard_install(MRMacWindowCloseHandler handler) {
#if TARGET_OS_MACCATALYST
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class windowClass = NSClassFromString(@"NSWindow");
        SEL selector = NSSelectorFromString(@"performClose:");
        Method method = windowClass != Nil ? class_getInstanceMethod(windowClass, selector) : NULL;
        if (method == NULL) {
            return;
        }
        mr_close_handler = [handler copy];
        mr_original_perform_close = method_setImplementation(method, (IMP)mr_perform_close);
    });
#else
    (void)handler;
#endif
}
