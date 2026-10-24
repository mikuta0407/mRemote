import XCTest
import SessionCore
@testable import mRemote

final class TerminalTabsStateTests: XCTestCase {
    private let a = TerminalID()
    private let b = TerminalID()
    private let c = TerminalID()
    private let d = TerminalID()

    func testTabsOpenAfterTheSelectedOneAndCloseToTheirNeighbour() {
        var state = TerminalTabsState()
        state.addTab(a)
        state.addTab(b)
        state.select(state.tabs[0].id)
        state.addTab(c)
        XCTAssertEqual(state.tabs.map(\.focused), [a, c, b])
        XCTAssertEqual(state.focusedTerminal, c)

        state.remove(c)
        XCTAssertEqual(state.tabs.map(\.focused), [a, b])
        XCTAssertEqual(state.focusedTerminal, a, "the tab before the closed one is shown")
        state.selectTab(offset: -1)
        XCTAssertEqual(state.focusedTerminal, b, "wraps round")
        state.remove(b)
        state.remove(a)
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertNil(state.selected)
    }

    func testSplittingAndClosingPanes() {
        var state = TerminalTabsState()
        state.addTab(a)
        state.split(axis: .horizontal, with: b)
        state.split(axis: .vertical, with: c)
        XCTAssertEqual(state.selected?.root.leaves, [a, b, c])
        XCTAssertEqual(state.focusedTerminal, c, "the new pane types")
        guard case .split(let outer) = state.selected?.root, case .split(let inner) = outer.second else {
            return XCTFail("not split")
        }
        XCTAssertEqual(outer.axis, .horizontal)
        XCTAssertEqual(inner.axis, .vertical)

        state.setRatio(0.99, of: outer.id)
        guard case .split(let clamped) = state.selected?.root else { return XCTFail("not split") }
        XCTAssertEqual(clamped.ratio, PaneSplit.ratioRange.upperBound)

        state.remove(c)
        XCTAssertEqual(state.selected?.root.leaves, [a, b])
        XCTAssertEqual(state.focusedTerminal, b, "the pane before the closed one types")
        state.focusPane(offset: 1)
        XCTAssertEqual(state.focusedTerminal, a)
        state.remove(a)
        XCTAssertEqual(state.selected?.root, .leaf(b), "the last pane fills the tab")
    }

    func testPanesGoSideBySideOnlyWhereEachGetsRoom() {
        let cell = CGSize(width: 8, height: 16)
        let sideBySide = PaneNode.leaf(a).splitting(a, axis: .horizontal, with: b)
        let stacked = PaneNode.leaf(a).splitting(a, axis: .vertical, with: b)
        // An open Duo upright: too narrow for two columns of 40, tall enough
        // for two of 8 rows.
        let phone = CGSize(width: 382, height: 600)
        XCTAssertTrue(PaneNode.leaf(a).fits(phone, cell: cell, divider: 6))
        XCTAssertFalse(sideBySide.fits(phone, cell: cell, divider: 6))
        XCTAssertTrue(stacked.fits(phone, cell: cell, divider: 6))
        XCTAssertTrue(sideBySide.fits(CGSize(width: 700, height: 300), cell: cell, divider: 6))
        // Dragging a divider does not change the answer.
        guard case .split(let split) = sideBySide else { return XCTFail("not split") }
        XCTAssertTrue(sideBySide.settingRatio(0.15, of: split.id).fits(CGSize(width: 700, height: 300), cell: cell, divider: 6))
        // Each pane of a nested split counts.
        let three = stacked.splitting(b, axis: .vertical, with: c)
        XCTAssertFalse(three.fits(CGSize(width: 382, height: 300), cell: cell, divider: 6))
    }

    func testFocusingAPaneShowsItsTab() {
        var state = TerminalTabsState()
        state.addTab(a)
        state.addTab(b)
        state.split(axis: .horizontal, with: c)
        state.addTab(d)
        state.focus(b)
        XCTAssertEqual(state.selected?.root.leaves, [b, c])
        XCTAssertEqual(state.focusedTerminal, b)
        XCTAssertEqual(state.tab(containing: c)?.id, state.selected?.id)
        XCTAssertFalse(state.remove(TerminalID()), "a stranger is not removed")
        XCTAssertEqual(state.allTerminals, [a, b, c, d])
    }
}
