import XCTest

/// The App Store and AltStore screenshots: the list as someone might have it,
/// a connection's settings, and a real shell on the Linux test host
/// (bridge/ssh/tests/run_live_ui_tests.sh with MR_SSH_LINUX=1), one pane and
/// two. Skipped unless TEST_RUNNER_MREMOTE_UITEST_STORE_SHOTS names a
/// directory for the PNGs, so ordinary runs never take them.
final class StoreScreenshotsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment

    private func element(_ identifier: String) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        if matches.count > 1, let shown = matches.allElementsBoundByIndex.first(where: { $0.frame.width > 0 }) {
            return shown
        }
        return matches.firstMatch
    }

    private func shot(_ name: String, in directory: String) {
        // Let a sheet or the keyboard finish arriving.
        Thread.sleep(forTimeInterval: 1.5)
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func terminalText() -> String {
        ((element("terminal-surface").value as? String) ?? "").replacingOccurrences(of: "\u{0}", with: "")
    }

    private func waitForTerminal(containing needle: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if terminalText().contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// Picks an item of the session menu, scrolled to as LiveSSHUITests does:
    /// rows out of sight are not there at all.
    private func menu(_ item: String) {
        element("session-menu-button").tap()
        let sheet = element("session-menu")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the menu opens")
        let entry = element(item)
        func drag(_ element: XCUIElement, from: CGFloat, to: CGFloat) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        for _ in 0..<6 where !(entry.exists && entry.isHittable) {
            drag(sheet, from: 0.8, to: 0.3)
        }
        let list = sheet.descendants(matching: .collectionView).firstMatch
        for _ in 0..<6 where list.exists && !(entry.exists && entry.isHittable) {
            drag(list, from: 0.4, to: 0.8)
        }
        XCTAssertTrue(entry.exists, "\(item) in the menu")
        entry.tap()
    }

    func testStoreScreenshots() throws {
        guard let directory = environment["MREMOTE_UITEST_STORE_SHOTS"],
              let port = environment["MREMOTE_UITEST_SSH_PORT"],
              let user = environment["MREMOTE_UITEST_SSH_USER"],
              let key = environment["MREMOTE_UITEST_SSH_KEY"],
              environment["MREMOTE_UITEST_TMUX_HOST"] == "isolated" else {
            throw XCTSkip("store screenshots: MR_SSH_LINUX=1 bridge/ssh/tests/run_live_ui_tests.sh with MR_STORE_SHOTS")
        }
        continueAfterFailure = false
        let wide = UIDevice.current.userInterfaceIdiom == .pad
        if wide { XCUIDevice.shared.orientation = .landscapeLeft }
        app = XCUIApplication()
        app.launchArguments += ["-mremote-ui-testing", "-mremote-ui-testing-store-screenshots"]
        app.launchEnvironment["MREMOTE_UITEST_SSH_PORT"] = port
        app.launchEnvironment["MREMOTE_UITEST_SSH_USER"] = user
        app.launchEnvironment["MREMOTE_UITEST_SSH_KEY"] = key
        app.launchEnvironment["MREMOTE_UITEST_SSH_NAME"] = "Linux サーバー"
        // A plain prompt with no container ID in it, then something to look at.
        app.launchEnvironment["MREMOTE_UITEST_SSH_STARTUP"] = #"export PS1='\[\e[1;32m\]tester@linux\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '; cd /etc; clear; grep PRETTY_NAME os-release; ls --color=always -F | head -24"#
        app.launch()

        let row = element("profile-row-Linux サーバー")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        shot("01-list", in: directory)

        // A connection's settings.
        let windows = element("profile-row-Windows デスクトップ")
        windows.swipeLeft()
        let edit = app.buttons["編集"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(element("profile-host-field").waitForExistence(timeout: 5))
        shot("02-editor", in: directory)
        app.buttons["キャンセル"].firstMatch.tap()

        // A shell.
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let trust = element("host-key-trust-always")
        if trust.waitForExistence(timeout: 5) { trust.tap() }
        XCTAssertTrue(element("terminal-surface").waitForExistence(timeout: 15))
        XCTAssertTrue(waitForTerminal(containing: "PRETTY_NAME"), "the shell is up\n\(terminalText())")
        shot("03-terminal", in: directory)

        // Two panes, the second with its own work.
        menu("terminal-split-horizontal")
        element("terminal-surface").tap()
        app.typeText("clear; uname -srm; df -h / | tail -1; tmux -V\n")
        XCTAssertTrue(waitForTerminal(containing: "tmux "), "the pane is a shell\n\(terminalText())")
        shot("04-panes", in: directory)
    }
}
