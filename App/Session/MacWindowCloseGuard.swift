import SwiftUI
import UIKit

/// Lets a Mac window ask before it closes. Closing a session window used to
/// leave the connection running behind the list without a word; now the
/// window can stop the close and ask whether to disconnect or keep it.
///
/// A window registers its scene with a handler; the close button and ⌘W reach
/// the handler through `mr_mac_window_close_guard_install`, which returns
/// false to keep the window open. Nothing happens on the iPad, where a window
/// cannot refuse to close.
@MainActor
final class MacWindowCloseGuard {
    static let shared = MacWindowCloseGuard()

    /// Returns true to let the window close now.
    typealias Handler = () -> Bool

    private struct Entry {
        weak var scene: UIWindowScene?
        let handler: Handler
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var isInstalled = false

    func register(_ scene: UIWindowScene, handler: @escaping Handler) {
        guard Platform.isMac else { return }
        installIfNeeded()
        entries = entries.filter { $0.value.scene != nil }
        entries[ObjectIdentifier(scene)] = Entry(scene: scene, handler: handler)
    }

    func unregister(_ scene: UIWindowScene) {
        entries[ObjectIdentifier(scene)] = nil
    }

    private func installIfNeeded() {
        guard !isInstalled else { return }
        isInstalled = true
        mr_mac_window_close_guard_install { windows in
            // AppKit calls performClose: on the main thread.
            MainActor.assumeIsolated {
                MacWindowCloseGuard.shared.shouldClose(windows)
            }
        }
    }

    private func shouldClose(_ windows: [UIWindow]) -> Bool {
        for window in windows {
            guard let scene = window.windowScene,
                  let entry = entries[ObjectIdentifier(scene)],
                  entry.scene === scene else { continue }
            return entry.handler()
        }
        return true
    }
}

/// Registers the scene of the window it is in with `MacWindowCloseGuard`.
private struct MacWindowCloseGuardView: UIViewRepresentable {
    let handler: MacWindowCloseGuard.Handler

    func makeUIView(context: Context) -> GuardView {
        let view = GuardView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: GuardView, context: Context) {
        view.handler = handler
        view.register()
    }

    static func dismantleUIView(_ view: GuardView, coordinator: ()) {
        view.unregister()
    }

    final class GuardView: UIView {
        var handler: MacWindowCloseGuard.Handler?
        private weak var registeredScene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { unregister() } else { register() }
        }

        func register() {
            guard Platform.isMac, let handler, let scene = window?.windowScene else { return }
            if let registeredScene, registeredScene !== scene {
                MacWindowCloseGuard.shared.unregister(registeredScene)
            }
            registeredScene = scene
            // Through the view, so the latest handler always answers.
            MacWindowCloseGuard.shared.register(scene) { [weak self] in
                self?.handler?() ?? true
            }
        }

        func unregister() {
            guard let registeredScene else { return }
            MacWindowCloseGuard.shared.unregister(registeredScene)
            self.registeredScene = nil
        }
    }
}

extension View {
    /// On the Mac, asks `shouldClose` when the user closes this view's window
    /// (close button or ⌘W); false keeps the window open.
    func macWindowCloseGuard(_ shouldClose: @escaping () -> Bool) -> some View {
        background(
            MacWindowCloseGuardView(handler: shouldClose)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}
