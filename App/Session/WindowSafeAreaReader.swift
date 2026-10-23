import SwiftUI
import UIKit

/// The window's safe area - the Dynamic Island or notch, the rounded corners,
/// the home indicator - as the system reports it for this device and
/// rotation.
///
/// Read from UIKit because the workspace lays itself out edge to edge, and
/// below `ignoresSafeArea` SwiftUI reports the insets as zero.
struct WindowSafeAreaReader: UIViewRepresentable {
    let onChange: (EdgeInsets) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    /// Laid out over the whole screen, so a rotation or a resize reaches it.
    final class ReaderView: UIView {
        var onChange: ((EdgeInsets) -> Void)?
        private var reported: UIEdgeInsets?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        func report() {
            guard let window, window.safeAreaInsets != reported else { return }
            let insets = window.safeAreaInsets
            reported = insets
            let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let edges = EdgeInsets(
                top: insets.top,
                leading: rightToLeft ? insets.right : insets.left,
                bottom: insets.bottom,
                trailing: rightToLeft ? insets.left : insets.right
            )
            // Reported after the pass that noticed it, not during it: the
            // change re-lays out the SwiftUI views around this one.
            DispatchQueue.main.async { [weak self] in self?.onChange?(edges) }
        }
    }
}

/// How far the on-screen keyboard, with its accessory bar, reaches up from
/// the window's bottom edge; zero while it is down or floating.
///
/// The workspace ignores the keyboard's safe area so the desktop keeps its
/// size; a terminal instead shrinks above the keyboard and asks for this.
struct KeyboardInsetReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

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

    /// Laid out over the whole screen, with a marker that ends where the
    /// keyboard layout guide begins.
    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private let marker = MarkerView()
        private var reported: CGFloat?

        override init(frame: CGRect) {
            super.init(frame: frame)
            marker.translatesAutoresizingMaskIntoConstraints = false
            marker.isUserInteractionEnabled = false
            marker.owner = self
            addSubview(marker)
            NSLayoutConstraint.activate([
                marker.topAnchor.constraint(equalTo: topAnchor),
                marker.leadingAnchor.constraint(equalTo: leadingAnchor),
                marker.trailingAnchor.constraint(equalTo: trailingAnchor),
                marker.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        fileprivate func report() {
            guard let window else { return }
            // With the keyboard down the guide is the bottom safe area, which
            // the workspace already knows; only the keyboard is reported.
            let guideHeight = window.bounds.maxY - marker.convert(marker.bounds, to: window).maxY
            let inset = guideHeight > window.safeAreaInsets.bottom + 1 ? guideHeight : 0
            guard inset != reported else { return }
            reported = inset
            DispatchQueue.main.async { [weak self] in self?.onChange?(inset) }
        }
    }

    final class MarkerView: UIView {
        weak var owner: ReaderView?

        override func layoutSubviews() {
            super.layoutSubviews()
            owner?.report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            owner?.report()
        }
    }
}
