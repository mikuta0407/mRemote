import SwiftUI
import UIKit

/// Whether the window holding this view is the key window of the app in
/// front. On the Mac a scene stays `.active`, and UIKit posts nothing, while
/// another app is in front, so neither the scene phase nor UIApplication's
/// notifications can tell; AppKit's application can (`mr_mac_app_is_active`).
struct WindowKeyReader: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((Bool) -> Void)?
        private var reported: Bool?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let names = [
                UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
                // AppKit's, posted in this process under these names.
                Notification.Name("NSApplicationDidBecomeActiveNotification"),
                Notification.Name("NSApplicationDidResignActiveNotification"),
            ]
            for name in names {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: nil)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            changed()
        }

        @objc private func changed() {
            // Read once the notification has been handled, when the state it
            // announces is in place.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let inFront = window.isKeyWindow && mr_mac_app_is_active()
                guard inFront != self.reported else { return }
                self.reported = inFront
                self.onChange?(inFront)
            }
        }
    }
}
