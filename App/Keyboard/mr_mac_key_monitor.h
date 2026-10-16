/* AppKit's key and mouse-button events, for the Mac Catalyst build only. See
 * MacKeyboardCapture.swift for why the session needs them. */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The AppKit event types the monitor reports.
typedef NS_ENUM(NSUInteger, MRMacKeyEventType) {
    MRMacKeyEventTypeKeyDown = 10,
    MRMacKeyEventTypeKeyUp = 11,
    MRMacKeyEventTypeFlagsChanged = 12,
};

/// Called on the main thread for every key event sent to this app's windows.
/// Return YES to consume the event: no menu, no UIKit responder sees it.
typedef BOOL (^MRMacKeyHandler)(MRMacKeyEventType type, uint16_t keyCode,
                                uint64_t modifierFlags, BOOL isRepeat);

/// Installs an AppKit local event monitor. Returns nil where AppKit is not
/// loaded (every build but Mac Catalyst).
id _Nullable mr_mac_key_monitor_install(MRMacKeyHandler handler);

/// Called on the main thread for the right and other (middle) mouse buttons,
/// which UIKit on the Mac does not deliver as touches. `button` is AppKit's
/// buttonNumber: 1 right, 2 middle. Return YES to consume the event.
typedef BOOL (^MRMacMouseButtonHandler)(uint16_t button, BOOL pressed);

id _Nullable mr_mac_mouse_monitor_install(MRMacMouseButtonHandler handler);

/// Called on the main thread for every scroll-wheel event in this app's
/// windows, with NSEvent's scrollingDeltaX/Y, hasPreciseScrollingDeltas,
/// phase, momentumPhase, isDirectionInvertedFromDevice and modifierFlags.
/// Return YES to consume the event.
typedef BOOL (^MRMacScrollHandler)(double deltaX, double deltaY, BOOL precise,
                                   uint8_t phase, uint8_t momentumPhase,
                                   BOOL invertedFromDevice, uint64_t modifierFlags);

id _Nullable mr_mac_scroll_monitor_install(MRMacScrollHandler handler);

/// NSEvent.modifierFlags: the modifiers held right now. Zero off the Mac.
uint64_t mr_mac_current_modifier_flags(void);

/// NSApplication.isActive: this app is the one in front. A Catalyst scene
/// stays active, and UIKit posts nothing, when another app comes to the
/// front. Always true off the Mac.
bool mr_mac_app_is_active(void);

/// Removes a monitor from any install function.
void mr_mac_key_monitor_remove(id monitor);

NS_ASSUME_NONNULL_END
