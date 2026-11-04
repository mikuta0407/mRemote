import XCTest
import SwiftUI
import SessionCore
@testable import mRemote

final class WorkspaceLayoutTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 874)
    private let island = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)

    private func layout(
        _ deck: DeckLayout,
        policy: FoldResolutionPolicy = .resizeToFit,
        lockedDeck: DeckLayout = .docked(fraction: 0.5)
    ) -> WorkspaceLayout {
        WorkspaceLayout(size: phone, safeArea: island, deck: deck, foldPolicy: policy, lockedDeck: lockedDeck)
    }

    func testADockedDeckTakesTheDraggedShareWithinItsRange() {
        XCTAssertEqual(layout(.docked(fraction: 0.4)).deckHeight, 350)
        XCTAssertEqual(layout(.docked(fraction: 0.9)).deckHeight, (874 * 0.75).rounded())
        XCTAssertEqual(layout(.docked(fraction: 0.1)).deckHeight, (874 * 0.25).rounded())
        XCTAssertEqual(layout(.atHinge).desktopFrameHeight, 437)
        XCTAssertEqual(layout(.floating).deckHeight, 0, "a floating deck leaves the desktop the screen")
        XCTAssertEqual(layout(.fullScreen).desktopFrameHeight, 0, "with the desktop on a monitor the deck is the screen")
    }

    func testTheDeckTakesTheBottomEdgeSoOnlyTheTopIsGivenUp() {
        XCTAssertEqual(layout(.docked(fraction: 0.5)).desktopInsets.bottom, 0)
        XCTAssertEqual(layout(.hidden).desktopInsets.bottom, 34)
        XCTAssertEqual(layout(.floating).desktopInsets.top, 62)
        XCTAssertEqual(layout(.atHinge).desktopInsets.bottom, DeckLayout.hingeGap,
                       "at a hinge the desktop stops short of the crease")
    }

    func testOnlyALockedSizeOutlivesTheDeck() {
        XCTAssertNil(layout(.docked(fraction: 0.5)).renderSizeOverride)
        XCTAssertEqual(layout(.docked(fraction: 0.5), policy: .keepAndScale).renderSizeOverride,
                       CGSize(width: 402, height: 874 - 62 - 34))
        XCTAssertNil(layout(.hidden, policy: .keepAndScale).renderSizeOverride)

        let shown = layout(.docked(fraction: 0.5), policy: .lockToDeck).renderSizeOverride
        XCTAssertEqual(shown, CGSize(width: 402, height: 437 - 62))
        XCTAssertEqual(layout(.hidden, policy: .lockToDeck).renderSizeOverride, shown,
                       "hiding the deck keeps the shape it had")
        XCTAssertEqual(layout(.hidden, policy: .lockToDeck, lockedDeck: .atHinge).renderSizeOverride,
                       CGSize(width: 402, height: 437 - 62 - DeckLayout.hingeGap))
    }

    func testAFloatingFrameStaysOnScreenAndUsable() {
        let frame = FloatingDeckFrame(centerX: 1.2, centerY: -0.3, width: 0.1, height: 2)
        let rect = frame.rect(in: phone)
        XCTAssertEqual(rect.width, 320)
        XCTAssertEqual(rect.height, 874)
        XCTAssertEqual(rect.maxX, 402)
        XCTAssertEqual(rect.minY, 0)
        XCTAssertEqual(FloatingDeckFrame(rawValue: frame.rawValue), frame)
        XCTAssertNil(FloatingDeckFrame(rawValue: "1,2,nan,4"))
    }

    func testResizingByTheTopRightCornerKeepsTheBottomLeftCorner() {
        let ipad = CGSize(width: 1_032, height: 1_376)
        let before = FloatingDeckFrame.standard.rect(in: ipad)
        let after = FloatingDeckFrame.standard
            .resized(byDraggingTopRight: CGSize(width: 40, height: -60), in: ipad)
            .rect(in: ipad)
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.001)
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 0.001)
        XCTAssertEqual(after.width, before.width + 40, accuracy: 0.001)
        XCTAssertEqual(after.height, before.height + 60, accuracy: 0.001)
    }
}
