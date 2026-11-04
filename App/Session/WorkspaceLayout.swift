import SwiftUI
import SessionCore

/// What the keyboard button next to the menu button brings up when no
/// keyboard is showing: the keyboard used last.
enum KeyboardButtonTarget: String, CaseIterable {
    /// The system keyboard with the extended key bar, as in the Windows App.
    case softwareKeyboard
    case laptopDeck

    static let storageKey = "keyboard-button-target"
}

/// Where the laptop deck goes when it is not held at a foldable's hinge.
enum LaptopDeckPlacement: String, CaseIterable {
    /// Along the bottom, as tall as the user drags it.
    case docked
    /// A panel over the desktop that can be moved and resized. Only on an
    /// iPad or a foldable, where the screen has room for one.
    case floating

    static let storageKey = "laptop-deck-placement"
}

/// How the deck shares the screen with the desktop.
enum DeckLayout: Equatable {
    case hidden
    /// Below the hinge of a half-open foldable: the lower half, not movable.
    case atHinge
    /// Along the bottom, taking this fraction of the height.
    case docked(fraction: Double)
    /// Over the desktop, which keeps the whole screen.
    case floating
    /// The whole screen: the desktop is on a monitor.
    case fullScreen

    /// How much of the height a docked deck may take.
    static let fractionRange = 0.25...0.75
    static let standardFraction = 0.5
    static let standardSplitFraction = 0.3
    /// Where the dragged heights are kept: one per orientation, and one for
    /// the split deck, which needs less.
    static let portraitFractionKey = "laptop-deck-height-portrait"
    static let landscapeFractionKey = "laptop-deck-height-landscape"
    static let splitFractionKey = "laptop-deck-height-split"

    /// Every height and the floating frame back to where they started.
    static func resetSizes(in defaults: UserDefaults = .standard) {
        for key in [portraitFractionKey, landscapeFractionKey, splitFractionKey, FloatingDeckFrame.storageKey] {
            defaults.removeObject(forKey: key)
        }
    }
    /// The strip left dark above a foldable's hinge, so the desktop sits up
    /// on the standing half rather than running into the crease.
    static let hingeGap: CGFloat = 24

    var hingeClearance: CGFloat { self == .atHinge ? Self.hingeGap : 0 }

    /// The strip above a docked deck that is dragged to resize it.
    static let resizeHandleHeight: CGFloat = 20

    static func clampFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0.5 }
        return min(max(fraction, fractionRange.lowerBound), fractionRange.upperBound)
    }

    /// The height the deck takes from the bottom of a screen this tall.
    func deckHeight(in height: CGFloat) -> CGFloat {
        switch self {
        case .hidden, .floating:
            return 0
        case .atHinge:
            // The desktop takes the upper half, rounded, so the split meets
            // the hinge.
            return height - (height / 2).rounded()
        case .docked(let fraction):
            return (height * Self.clampFraction(fraction)).rounded()
        case .fullScreen:
            return height
        }
    }
}

/// The desktop's place on the screen: what the deck leaves it, less the
/// safe area it is to keep clear of, and the size to ask the server for.
struct WorkspaceLayout: Equatable {
    let size: CGSize
    /// Zero when the desktop is to use the screen edge to edge.
    let safeArea: EdgeInsets
    let deck: DeckLayout
    let foldPolicy: FoldResolutionPolicy
    /// The deck a locked size is measured against when the deck is not
    /// docked now: where it would go if it were shown.
    let lockedDeck: DeckLayout

    var deckHeight: CGFloat { deck.deckHeight(in: size.height) }

    /// The part of the screen above the deck.
    var desktopFrameHeight: CGFloat { size.height - deckHeight }

    /// The deck's own bottom edge is the deck's, so only the top and the
    /// sides are given up while it is docked. At a hinge the desktop also
    /// stops short of it: the crease bends the picture's bottom rows away
    /// from the user.
    var desktopInsets: EdgeInsets {
        EdgeInsets(
            top: safeArea.top,
            leading: safeArea.leading,
            bottom: deckHeight > 0 ? deck.hingeClearance : safeArea.bottom,
            trailing: safeArea.trailing
        )
    }

    /// Points to ask the server for instead of the surface's own size.
    var renderSizeOverride: CGSize? {
        switch foldPolicy {
        case .resizeToFit:
            return nil
        case .keepAndScale:
            // The whole screen, drawn smaller while the deck takes part of it.
            guard deckHeight > 0 else { return nil }
            return CGSize(
                width: size.width - safeArea.leading - safeArea.trailing,
                height: size.height - safeArea.top - safeArea.bottom
            )
        case .lockToDeck:
            let deck = deckHeight > 0 ? deck : lockedDeck
            return CGSize(
                width: size.width - safeArea.leading - safeArea.trailing,
                height: size.height - deck.deckHeight(in: size.height) - safeArea.top
                    - (deck.deckHeight(in: size.height) > 0 ? deck.hingeClearance : safeArea.bottom)
            )
        }
    }
}

/// A floating deck's place, as fractions of the screen so a rotation keeps
/// it in the same part of it.
struct FloatingDeckFrame: Equatable, RawRepresentable {
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double

    static let storageKey = "laptop-deck-floating-frame"
    static let minimumSize = CGSize(width: 320, height: 180)
    static let standard = FloatingDeckFrame(centerX: 0.5, centerY: 0.72, width: 0.62, height: 0.42)

    init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts.allSatisfy(\.isFinite) else { return nil }
        self.init(centerX: parts[0], centerY: parts[1], width: parts[2], height: parts[3])
    }

    var rawValue: String { "\(centerX),\(centerY),\(width),\(height)" }

    /// On a screen this size: no smaller than a usable keyboard, no larger
    /// than the screen, and wholly on it.
    func rect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = min(max(width * size.width, min(Self.minimumSize.width, size.width)), size.width)
        let height = min(max(height * size.height, min(Self.minimumSize.height, size.height)), size.height)
        let x = min(max(centerX * size.width - width / 2, 0), size.width - width)
        let y = min(max(centerY * size.height - height / 2, 0), size.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    init(_ rect: CGRect, in size: CGSize) {
        self.init(
            centerX: rect.midX / max(size.width, 1),
            centerY: rect.midY / max(size.height, 1),
            width: rect.width / max(size.width, 1),
            height: rect.height / max(size.height, 1)
        )
    }

    func moved(by translation: CGSize, in size: CGSize) -> FloatingDeckFrame {
        FloatingDeckFrame(rect(in: size).offsetBy(dx: translation.width, dy: translation.height), in: size)
    }

    /// Dragged by its top right corner: the bottom left corner stays put.
    func resized(byDraggingTopRight translation: CGSize, in size: CGSize) -> FloatingDeckFrame {
        let current = rect(in: size)
        let width = min(max(current.width + translation.width, min(Self.minimumSize.width, size.width)), size.width - current.minX)
        let height = min(max(current.height - translation.height, min(Self.minimumSize.height, size.height)), current.maxY)
        return FloatingDeckFrame(
            CGRect(x: current.minX, y: current.maxY - height, width: width, height: height),
            in: size
        )
    }
}
