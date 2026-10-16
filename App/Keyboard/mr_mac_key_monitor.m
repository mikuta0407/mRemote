#import "mr_mac_key_monitor.h"

/* UIKit on the Mac runs inside an AppKit application, but a Catalyst target
 * cannot import AppKit. NSEvent is reached by name instead, through the few
 * public methods declared here; the selectors are AppKit's own. */
@protocol MRNSEventClass
+ (id)addLocalMonitorForEventsMatchingMask:(uint64_t)mask handler:(id _Nullable (^)(id event))block;
+ (void)removeMonitor:(id)monitor;
+ (NSUInteger)modifierFlags;
@end

@protocol MRNSApplicationClass
+ (id)sharedApplication;
@end

@protocol MRNSApplication
- (BOOL)isActive;
@end

@protocol MRNSEvent
- (NSUInteger)type;
- (unsigned short)keyCode;
- (NSUInteger)modifierFlags;
- (BOOL)isARepeat;
- (NSInteger)buttonNumber;
- (double)scrollingDeltaX;
- (double)scrollingDeltaY;
- (BOOL)hasPreciseScrollingDeltas;
- (NSUInteger)phase;
- (NSUInteger)momentumPhase;
- (BOOL)isDirectionInvertedFromDevice;
@end

id mr_mac_key_monitor_install(MRMacKeyHandler handler) {
#if TARGET_OS_MACCATALYST
    Class eventClass = NSClassFromString(@"NSEvent");
    if (eventClass == Nil) {
        return nil;
    }
    uint64_t mask = (1ULL << MRMacKeyEventTypeKeyDown) | (1ULL << MRMacKeyEventTypeKeyUp) |
                    (1ULL << MRMacKeyEventTypeFlagsChanged);
    return [(Class<MRNSEventClass>)eventClass
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^id _Nullable(id event) {
                                         id<MRNSEvent> key = event;
                                         NSUInteger type = [key type];
                                         /* isARepeat raises for flagsChanged. */
                                         BOOL repeat = type != MRMacKeyEventTypeFlagsChanged && [key isARepeat];
                                         BOOL consumed = handler((MRMacKeyEventType)type, [key keyCode],
                                                                 (uint64_t)[key modifierFlags], repeat);
                                         return consumed ? nil : event;
                                     }];
#else
    (void)handler;
    return nil;
#endif
}

id mr_mac_mouse_monitor_install(MRMacMouseButtonHandler handler) {
#if TARGET_OS_MACCATALYST
    Class eventClass = NSClassFromString(@"NSEvent");
    if (eventClass == Nil) {
        return nil;
    }
    /* NSEventTypeRightMouseDown/Up = 3/4, NSEventTypeOtherMouseDown/Up = 25/26. */
    uint64_t mask = (1ULL << 3) | (1ULL << 4) | (1ULL << 25) | (1ULL << 26);
    return [(Class<MRNSEventClass>)eventClass
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^id _Nullable(id event) {
                                         id<MRNSEvent> mouse = event;
                                         NSUInteger type = [mouse type];
                                         BOOL pressed = type == 3 || type == 25;
                                         BOOL consumed = handler((uint16_t)[mouse buttonNumber], pressed);
                                         return consumed ? nil : event;
                                     }];
#else
    (void)handler;
    return nil;
#endif
}

id mr_mac_scroll_monitor_install(MRMacScrollHandler handler) {
#if TARGET_OS_MACCATALYST
    Class eventClass = NSClassFromString(@"NSEvent");
    if (eventClass == Nil) {
        return nil;
    }
    /* NSEventTypeScrollWheel = 22. */
    return [(Class<MRNSEventClass>)eventClass
        addLocalMonitorForEventsMatchingMask:(1ULL << 22)
                                     handler:^id _Nullable(id event) {
                                         id<MRNSEvent> scroll = event;
                                         BOOL consumed = handler(
                                             [scroll scrollingDeltaX], [scroll scrollingDeltaY],
                                             [scroll hasPreciseScrollingDeltas],
                                             (uint8_t)[scroll phase], (uint8_t)[scroll momentumPhase],
                                             [scroll isDirectionInvertedFromDevice],
                                             (uint64_t)[scroll modifierFlags]);
                                         return consumed ? nil : event;
                                     }];
#else
    (void)handler;
    return nil;
#endif
}

uint64_t mr_mac_current_modifier_flags(void) {
#if TARGET_OS_MACCATALYST
    Class eventClass = NSClassFromString(@"NSEvent");
    return eventClass ? (uint64_t)[(Class<MRNSEventClass>)eventClass modifierFlags] : 0;
#else
    return 0;
#endif
}

bool mr_mac_app_is_active(void) {
#if TARGET_OS_MACCATALYST
    Class applicationClass = NSClassFromString(@"NSApplication");
    if (applicationClass == Nil) {
        return true;
    }
    return [(id<MRNSApplication>)[(Class<MRNSApplicationClass>)applicationClass sharedApplication] isActive];
#else
    return true;
#endif
}

void mr_mac_key_monitor_remove(id monitor) {
#if TARGET_OS_MACCATALYST
    [(Class<MRNSEventClass>)NSClassFromString(@"NSEvent") removeMonitor:monitor];
#else
    (void)monitor;
#endif
}
