/* The Mac window's close button and ⌘W, for the Mac Catalyst build only. See
 * MacWindowCloseGuard.swift for why a session window asks before it closes. */
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Called on the main thread when the user asks an AppKit window to close
/// (its close button, or File > Close), with the UIKit windows it hosts.
/// Return NO to keep the window open.
typedef BOOL (^MRMacWindowCloseHandler)(NSArray<UIWindow *> *windows);

/// Routes every window's performClose: through `handler`. Once per process;
/// does nothing where AppKit is not loaded (every build but Mac Catalyst).
void mr_mac_window_close_guard_install(MRMacWindowCloseHandler handler);

NS_ASSUME_NONNULL_END
