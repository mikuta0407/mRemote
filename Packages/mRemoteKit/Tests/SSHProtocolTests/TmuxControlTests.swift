import XCTest
@testable import SSHProtocol

final class TmuxControlTests: XCTestCase {
    func testTheStreamSplitsTerminalAndControlLinesAcrossChunks() {
        var stream = TmuxControlStream()
        var pieces: [TmuxControlStream.Piece] = []
        // The shell echoes the command, then tmux takes over; the marker
        // and a line are cut between chunks.
        for chunk in ["$ tmux -CC\r\n\u{1B}P10", "00p%begin 1 1 0\r\n%end 1 1", " 0\n%output %1 hi\\015\\012\n%exit\n\u{1B}", "\\$ "] {
            pieces += stream.feed(Array(chunk.utf8))
        }
        XCTAssertEqual(pieces, [
            .terminal(Array("$ tmux -CC\r\n".utf8)),
            .began,
            .line("%begin 1 1 0"),
            .line("%end 1 1 0"),
            .line("%output %1 hi\\015\\012"),
            .line("%exit"),
            .ended,
            .terminal(Array("$ ".utf8)),
        ])
        XCTAssertFalse(stream.inControlMode)
    }

    func testPlainOutputPassesThroughWhole() {
        var stream = TmuxControlStream()
        // An escape that is not the marker is held only while it could be.
        XCTAssertEqual(stream.feed(Array("ab\u{1B}P".utf8)), [.terminal(Array("ab".utf8))])
        XCTAssertEqual(stream.feed(Array("q".utf8)), [.terminal(Array("\u{1B}Pq".utf8))])
    }

    func testNotificationsParse() {
        XCTAssertEqual(TmuxNotification("%output %12 a\\134b\\033[m"), .output(pane: 12, bytes: Array("a\\b\u{1B}[m".utf8)))
        XCTAssertEqual(TmuxNotification("%output %3 日本"), .output(pane: 3, bytes: Array("日本".utf8)))
        XCTAssertEqual(TmuxNotification("%begin 1700000000 42 1"), .begin(command: 42, fromClient: true))
        XCTAssertEqual(TmuxNotification("%end 1700000000 42 0"), .end(command: 42, fromClient: false))
        XCTAssertEqual(TmuxNotification("%error 1700000000 43 1"), .error(command: 43, fromClient: true))
        XCTAssertEqual(TmuxNotification("%window-add @7"), .windowAdd(window: 7))
        XCTAssertEqual(TmuxNotification("%window-renamed @7 my editor"), .windowRenamed(window: 7, name: "my editor"))
        XCTAssertEqual(TmuxNotification("%layout-change @7 b25d,80x24,0,0,1 b25d,80x24,0,0,1 *"),
                       .layoutChange(window: 7, layout: "b25d,80x24,0,0,1"))
        XCTAssertEqual(TmuxNotification("%window-pane-changed @7 %3"), .windowPaneChanged(window: 7, pane: 3))
        XCTAssertEqual(TmuxNotification("%session-changed $1 main"), .sessionChanged(session: 1, name: "main"))
        XCTAssertEqual(TmuxNotification("%exit"), .exit(reason: nil))
        XCTAssertEqual(TmuxNotification("%exit detached"), .exit(reason: "detached"))
        XCTAssertEqual(TmuxNotification("hello"), .other("hello"))
    }

    func testLayoutsParse() throws {
        let layout = try XCTUnwrap(TmuxLayout("b25d,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}"))
        XCTAssertEqual(layout.frame, TmuxCellRect(x: 0, y: 0, width: 80, height: 24))
        XCTAssertEqual(layout.panes.map(\.id), [1, 2, 3])
        XCTAssertEqual(layout.panes[2].frame, TmuxCellRect(x: 41, y: 13, width: 39, height: 11))
        guard case let .split(sideBySide, _, children) = layout else { return XCTFail("not split") }
        XCTAssertTrue(sideBySide)
        guard case let .split(stacked, _, _) = children[1] else { return XCTFail("not split") }
        XCTAssertFalse(stacked)
        XCTAssertEqual(TmuxLayout("c0de,120x40,0,0,5"), .pane(id: 5, frame: TmuxCellRect(x: 0, y: 0, width: 120, height: 40)))
        XCTAssertNil(TmuxLayout("c0de,120x40,0,0{1"))
    }

    func testCommands() {
        XCTAssertEqual(TmuxControlCommands.sendKeys(pane: 4, Array("ls\r".utf8)), ["send-keys -t %4 -H 6c 73 0d"])
        XCTAssertEqual(TmuxControlCommands.sendKeys(pane: 1, Array(repeating: 0x61, count: 5), chunk: 2).count, 3)
        XCTAssertEqual(TmuxControlCommands.clientSize(columns: 100, rows: 30), "refresh-client -C 100x30")
        let windows = TmuxControlCommands.parseWindows(["@1 1 c0de,80x24,0,0,1 zsh", "@2 0 c0de,80x24,0,0,2 my editor", "junk"])
        XCTAssertEqual(windows.map(\.id), [1, 2])
        XCTAssertEqual(windows[1].name, "my editor")
        XCTAssertTrue(windows[0].isActive)
    }
}
