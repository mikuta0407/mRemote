import XCTest

/// The real app against a real sshd, through the screens: list, host key
/// sheet, terminal, typing, the menu. Skipped unless the sshd is given;
/// bridge/ssh/tests/run_live_ui_tests.sh starts a throwaway one and passes it
/// in. Screenshots are kept as attachments, and written to
/// TEST_RUNNER_MREMOTE_UITEST_SHOTS when set.
final class LiveSSHUITests: XCTestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment

    private func element(_ identifier: String) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        // A view on its way out of the hierarchy can linger with no frame.
        if matches.count > 1, let shown = matches.allElementsBoundByIndex.first(where: { $0.frame.width > 0 }) {
            return shown
        }
        return matches.firstMatch
    }

    private func shot(_ name: String) {
        // The app's window rather than the main screen: on the iPhone Duo
        // open, the main screen is the cover display, dark.
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["MREMOTE_UITEST_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func terminalText() -> String {
        // A wide character's second cell reads back as NUL.
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

    private func launchAndConnect(arguments: [String] = []) throws {
        let environment = self.environment
        guard let port = environment["MREMOTE_UITEST_SSH_PORT"],
              let user = environment["MREMOTE_UITEST_SSH_USER"],
              let key = environment["MREMOTE_UITEST_SSH_KEY"] else {
            throw XCTSkip("no test sshd (bridge/ssh/tests/run_live_ui_tests.sh)")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-mremote-ui-testing")
        app.launchArguments += arguments
        app.launchEnvironment["MREMOTE_UITEST_SSH_PORT"] = port
        app.launchEnvironment["MREMOTE_UITEST_SSH_USER"] = user
        app.launchEnvironment["MREMOTE_UITEST_SSH_KEY"] = key
        app.launchEnvironment["MREMOTE_UITEST_SSH_STARTUP"] = "echo welcome-$((40+2))"
        app.launch()
        let row = element("profile-row-テスト SSH")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let trust = element("host-key-trust-always")
        if trust.waitForExistence(timeout: 5) { trust.tap() }
        XCTAssertTrue(element("terminal-surface").waitForExistence(timeout: 15))
        // The shell is up: typing before it would go nowhere.
        let up = waitForTerminal(containing: "welcome-42")
        if !up { shot("connect-failed") }
        XCTAssertTrue(waitForTerminal(containing: "welcome-42"), "the startup command ran\n\(terminalText())")
    }

    /// Opens the session menu and picks one of its tab and pane items.
    private func menu(_ item: String) {
        let menuButton = element("session-menu-button")
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        menuButton.tap()
        let entry = menuEntry(item)
        if !entry.exists { shot("menu-without-\(item)") }
        XCTAssertTrue(entry.exists, "\(item) in the menu\n\(app.debugDescription)")
        entry.tap()
    }

    /// An item of the open session menu, scrolled to. On a short sheet (the
    /// Duo open) the list can be carried past it, and rows out of sight are
    /// not there at all: back up again.
    private func menuEntry(_ item: String) -> XCUIElement {
        let entry = element(item)
        let sheet = element("session-menu")
        _ = sheet.waitForExistence(timeout: 5)
        for _ in 0..<6 where !(entry.exists && entry.isHittable) {
            sheet.swipeUp(velocity: .slow)
        }
        for _ in 0..<6 where !(entry.exists && entry.isHittable) {
            sheet.swipeDown(velocity: .slow)
        }
        return entry
    }

    /// Tabs and panes on one connection (docs/ssh-design.md section 16):
    /// each its own shell, switched from the bar, and closed again.
    func testTabsAndPanesShareTheConnection() throws {
        try launchAndConnect()
        let terminal = element("terminal-surface")
        terminal.tap()
        app.typeText("echo first-$((1+1))\n")
        XCTAssertTrue(waitForTerminal(containing: "first-2"))

        menu("terminal-new-tab")
        let bar = element("terminal-tab-bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "a second tab brings the bar")
        XCTAssertTrue(element("terminal-tab-1").waitForExistence(timeout: 5))
        element("terminal-surface").tap()
        app.typeText("echo second-$((2+2))\n")
        XCTAssertTrue(waitForTerminal(containing: "second-4"), "the new tab is a shell\n\(terminalText())")
        XCTAssertFalse(terminalText().contains("first-2"), "the new tab has its own screen")
        shot("t1-second-tab")

        element("terminal-tab-0").tap()
        XCTAssertTrue(waitForTerminal(containing: "first-2"), "back on the first tab")
        XCTAssertFalse(terminalText().contains("second-4"))

        // A pane beside it. A narrow screen shows one at a time, with
        // numbers in the bar; a wide one shows both.
        menu("terminal-split-horizontal")
        let chip = element("terminal-pane-chip-1")
        let narrow = chip.waitForExistence(timeout: 5)
        element("terminal-surface").tap()
        app.typeText("echo pane-$((3+3))\n")
        XCTAssertTrue(waitForTerminal(containing: "pane-6"), "the pane is a shell\n\(terminalText())")
        shot("t2-pane")
        if narrow {
            element("terminal-pane-chip-0").tap()
            XCTAssertTrue(waitForTerminal(containing: "first-2"), "the first pane again")
        } else {
            XCTAssertTrue(element("terminal-pane").exists, "both panes on a wide screen")
        }

        menu("terminal-close-pane")
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5))
        XCTAssertFalse(element("terminal-pane").exists, "one pane left")

        // Closing the first tab leaves the second, and the bar goes with it.
        element("terminal-tab-close").tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "one tab: no bar")
        XCTAssertTrue(waitForTerminal(containing: "second-4"), "the second tab is what is left\n\(terminalText())")
        shot("t3-one-tab")
        element("terminal-surface").tap()
        app.typeText("exit\n")
        XCTAssertTrue(element("session-end-reason").waitForExistence(timeout: 15), "its exit ends the session")
    }

    /// Splits shown whatever the room (no iPad runs this simulator runtime):
    /// both panes on screen, the divider dragged, a tap moving the keyboard.
    func testPanesSideBySide() throws {
        try launchAndConnect(arguments: ["-mremote-terminal-splits", "always"])
        element("terminal-surface").tap()
        app.typeText("echo left-$((1+1))\n")
        XCTAssertTrue(waitForTerminal(containing: "left-2"))
        menu("terminal-split-horizontal")
        let other = element("terminal-pane")
        XCTAssertTrue(other.waitForExistence(timeout: 10), "both panes on screen\n\(app.debugDescription)")
        let right = element("terminal-surface")
        XCTAssertGreaterThan(right.frame.minX, other.frame.minX, "the new pane is on the right")
        right.tap()
        app.typeText("echo right-$((2+2))\n")
        XCTAssertTrue(waitForTerminal(containing: "right-4"))
        let before = other.frame.width
        let divider = element("terminal-pane-divider")
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 60, dy: 0)))
        XCTAssertGreaterThan(element("terminal-pane").frame.width, before + 20, "the divider moved")
        shot("p1-side-by-side")
        // A tap on the left pane gives it the keyboard.
        element("terminal-pane").tap()
        app.typeText("echo again-$((3+3))\n")
        XCTAssertTrue(waitForTerminal(containing: "again-6"), "the left pane types now\n\(terminalText())")
        XCTAssertTrue(terminalText().contains("left-2"), "it is the left pane's screen")
        shot("p2-focus-left")
    }

    /// The iPhone Duo as it comes, splits shown where each pane gets room.
    /// Closed (466pt across): one above the other, not side by side. Open
    /// (951pt across): side by side too.
    func testPanesOnTheDuo() throws {
        try launchAndConnect()
        let width = app.windows.firstMatch.frame.width
        let closed = (440...520).contains(width)
        let open = (900...1000).contains(width)
        try XCTSkipUnless(closed || open, "not an iPhone Duo (\(width)pt)")
        let other = element("terminal-pane")
        element("terminal-surface").tap()
        if closed {
            menu("terminal-split-vertical")
            XCTAssertTrue(other.waitForExistence(timeout: 10), "one above the other fits\n\(app.debugDescription)")
            XCTAssertLessThan(other.frame.minY, element("terminal-surface").frame.minY, "the new pane is below")
            shot("d1-closed-stacked")
            menu("terminal-split-horizontal")
            XCTAssertTrue(element("terminal-pane-chip-2").waitForExistence(timeout: 10), "three panes to choose from")
            XCTAssertFalse(other.exists, "side by side does not fit: one pane at a time")
            shot("d2-closed-one-at-a-time")
        } else {
            menu("terminal-split-horizontal")
            XCTAssertTrue(other.waitForExistence(timeout: 10), "side by side fits\n\(app.debugDescription)")
            XCTAssertGreaterThan(element("terminal-surface").frame.minX, other.frame.minX, "the new pane is on the right")
            app.typeText("echo open-$((5+5))\n")
            XCTAssertTrue(waitForTerminal(containing: "open-10"))
            shot("d1-open-side-by-side")
            menu("terminal-split-vertical")
            // Even with the keyboard up, the right half has room for two
            // above one another.
            let panes = app.descendants(matching: .any).matching(identifier: "terminal-pane")
            XCTAssertEqual(panes.allElementsBoundByIndex.filter { $0.frame.width > 0 }.count, 2, "all three on screen")
            XCTAssertFalse(element("terminal-pane-chip-2").exists, "nothing to choose between")
            shot("d2-open-three")
        }
    }

    private func value(of identifier: String) -> String {
        ((element(identifier).value as? String) ?? "").replacingOccurrences(of: "\u{0}", with: "")
    }

    private func wait(for needle: String, in identifier: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if value(of: identifier).contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// tmux control mode (docs/ssh-design.md 16.5), against the Linux
    /// container only: it starts and ends tmux sessions, which on this Mac
    /// could be the developer's own.
    func testTmuxControlModeShowsWindowsAndPanes() throws {
        guard environment["MREMOTE_UITEST_TMUX_HOST"] == "isolated" else {
            throw XCTSkip("needs MR_SSH_LINUX=1 (a host of its own for tmux)")
        }
        guard let port = environment["MREMOTE_UITEST_SSH_PORT"],
              let user = environment["MREMOTE_UITEST_SSH_USER"],
              let key = environment["MREMOTE_UITEST_SSH_KEY"] else {
            throw XCTSkip("no test sshd")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-mremote-ui-testing")
        app.launchEnvironment["MREMOTE_UITEST_SSH_PORT"] = port
        app.launchEnvironment["MREMOTE_UITEST_SSH_USER"] = user
        app.launchEnvironment["MREMOTE_UITEST_SSH_KEY"] = key
        app.launchEnvironment["MREMOTE_UITEST_SSH_TMUX"] = "auto-cc:mr-cc"
        app.launch()
        element("profile-row-テスト SSH").tap()
        let trust = element("host-key-trust-always")
        if trust.waitForExistence(timeout: 10) { trust.tap() }

        let bar = element("tmux-window-bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "control mode shows tmux's windows\n\(app.debugDescription)")
        let pane = element("tmux-pane-active")
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "and its pane")
        pane.tap()
        app.typeText("echo cc-$((3*3))\n")
        XCTAssertTrue(wait(for: "cc-9", in: "tmux-pane-active"), "typing reaches the pane\n\(value(of: "tmux-pane-active"))")
        shot("c1-control-mode")

        // A pane beside it, made by tmux.
        element("tmux-menu").tap()
        element("tmux-split-horizontal").tap()
        XCTAssertTrue(element("tmux-pane").waitForExistence(timeout: 10), "tmux's split shows as two panes")
        element("tmux-pane-active").tap()
        app.typeText("echo second-$((4*4))\n")
        XCTAssertTrue(wait(for: "second-16", in: "tmux-pane-active"), "the new pane types\n\(value(of: "tmux-pane-active"))")
        XCTAssertTrue(value(of: "tmux-pane").contains("cc-9"), "the first pane keeps its screen")
        shot("c2-split")

        // A second window, as a second tab.
        element("tmux-menu").tap()
        element("tmux-new-window").tap()
        XCTAssertTrue(element("tmux-window-1").waitForExistence(timeout: 10), "a new tmux window is a tab")
        element("tmux-window-0").tap()
        XCTAssertTrue(element("tmux-pane").waitForExistence(timeout: 10), "back to the split window")

        // Detached, the shell is back; attached again, all of it returns.
        element("tmux-menu").tap()
        element("tmux-detach").tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "detaching leaves control mode")
        // Control mode prints no "[detached]": the shell's prompt is back.
        XCTAssertTrue(element("terminal-surface").waitForExistence(timeout: 10), "the shell is back")
        element("terminal-surface").tap()
        app.typeText("tmux -CC attach -t mr-cc\n")
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "attached again")
        XCTAssertTrue(element("tmux-window-1").waitForExistence(timeout: 10), "with both windows")
        element("tmux-window-0").tap()
        XCTAssertTrue(wait(for: "cc-9", in: "tmux-pane-active") || wait(for: "cc-9", in: "tmux-pane"),
                      "and the panes' history")
        shot("c3-attached-again")
    }

    func testConnectTrustTypeAndUseTheMenu() throws {
        guard let port = environment["MREMOTE_UITEST_SSH_PORT"],
              let user = environment["MREMOTE_UITEST_SSH_USER"],
              let key = environment["MREMOTE_UITEST_SSH_KEY"] else {
            throw XCTSkip("no test sshd (bridge/ssh/tests/run_live_ui_tests.sh)")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-mremote-ui-testing")
        app.launchEnvironment["MREMOTE_UITEST_SSH_PORT"] = port
        app.launchEnvironment["MREMOTE_UITEST_SSH_USER"] = user
        app.launchEnvironment["MREMOTE_UITEST_SSH_KEY"] = key
        app.launchEnvironment["MREMOTE_UITEST_SSH_STARTUP"] = "echo welcome-$((40+2))"
        app.launch()

        let row = element("profile-row-テスト SSH")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        shot("1-list")
        row.tap()

        let trust = element("host-key-trust-always")
        XCTAssertTrue(trust.waitForExistence(timeout: 15), "the host key is asked about\n\(app.debugDescription)")
        XCTAssertTrue(element("host-key-fingerprint").label.hasPrefix("SHA256:") ||
                      (element("host-key-fingerprint").value as? String ?? "").hasPrefix("SHA256:") ||
                      app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'SHA256:'")).count > 0)
        shot("2-host-key")
        trust.tap()

        XCTAssertTrue(element("terminal-surface").waitForExistence(timeout: 15))
        XCTAssertTrue(waitForTerminal(containing: "welcome-42"), "the startup command ran\n\(terminalText())")

        let terminal = element("terminal-surface")
        terminal.tap()
        app.typeText("echo typed-$((7*6)) あいう\n")
        XCTAssertTrue(waitForTerminal(containing: "typed-42"), "typing reaches the shell\n\(terminalText())")
        shot("3-terminal")

        // Japanese being composed is shown at the cursor, and reaches the
        // shell only when committed. Needs the kana keyboard, as on a
        // Japanese simulator; skipped with another.
        let ka = app.keys["か"]
        if ka.exists {
            app.typeText("echo ")
            ka.tap()
            app.keys["な"].tap()
            shot("3c-composing")
            XCTAssertFalse(terminalText().contains("かな"), "composed text is not sent before it is committed")
            let commit = app.buttons["確定"].exists ? app.buttons["確定"] : app.keys["確定"]
            if commit.exists { commit.tap() }
            app.typeText("\n")
            XCTAssertTrue(waitForTerminal(containing: "\nかな"), "the committed text reaches the shell\n\(terminalText())")
            shot("3d-committed")
        }

        // A screenful later the prompt is on the bottom row: the terminal
        // ends above the keyboard and its key bar, not behind them.
        app.typeText("seq 1 120; echo bottom-$((5*5))\n")
        XCTAssertTrue(waitForTerminal(containing: "bottom-25"), "the output arrives\n\(terminalText())")
        let bar = element("terminal-key-Esc")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            terminal.frame.maxY, bar.frame.minY + 1,
            "the terminal \(terminal.frame) stays above the key bar \(bar.frame)"
        )
        shot("3b-terminal-full")

        // The key bar. With DECCKM on, as full-screen programs set it, PgUp
        // goes to the remote program; the tty echoes what arrives.
        app.typeText("printf '\\033[?1h'; cat -v\n")
        element("terminal-key-PgUp").tap()
        XCTAssertTrue(waitForTerminal(containing: "^[[5~"), "PgUp is sent\n\(terminalText())")
        element("terminal-key-Ctrl").tap()
        element("terminal-key-PgDn").tap()
        XCTAssertTrue(waitForTerminal(containing: "^[[6;5~"), "Ctrl+PgDn is sent\n\(terminalText())")
        // F5 is past the screen's edge until the bar is scrolled.
        let f5 = element("terminal-key-F5")
        for _ in 0..<4 where !f5.isHittable {
            element("terminal-key-Del").swipeLeft()
        }
        f5.tap()
        XCTAssertTrue(waitForTerminal(containing: "^[[15~"), "F5 is sent\n\(terminalText())")
        shot("4-key-bar")
        // Sticky Ctrl applies to the next typed key: ^C ends cat.
        element("terminal-key-Ctrl").tap()
        app.typeText("c")
        app.typeText("printf '\\033[?1l'; echo after-ctrl-c-$((1+1))\n")
        XCTAssertTrue(waitForTerminal(containing: "after-ctrl-c-2"), "Ctrl+C reaches the shell\n\(terminalText())")

        // The menu: an SSH session shows its own items.
        let menuButton = element("session-menu-button")
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            XCTAssertTrue(menuEntry("session-terminal-paste").exists)
            shot("5-menu")
            // To the list and back: the same terminal, with what it showed.
            menuEntry("session-return-to-list").tap()
            let running = element("running-session-テスト SSH")
            XCTAssertTrue(running.waitForExistence(timeout: 10))
            running.tap()
            XCTAssertTrue(element("terminal-surface").waitForExistence(timeout: 10))
            XCTAssertTrue(waitForTerminal(containing: "after-ctrl-c-2", timeout: 5),
                          "the terminal survives a trip to the list\n\(terminalText())")
            element("terminal-surface").tap()
        }

        app.typeText("exit\n")
        XCTAssertTrue(element("session-end-reason").waitForExistence(timeout: 15), "the shell's exit is shown")
        shot("6-exited")

        // Reconnect from the banner: a new shell, which runs the startup
        // command again.
        let reconnect = element("session-end-reconnect")
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5), "the banner offers to reconnect\n\(app.debugDescription)")
        XCTAssertTrue(reconnect.isHittable, "the reconnect button can be pressed\n\(app.debugDescription)")
        reconnect.tap()
        XCTAssertTrue(waitForTerminal(containing: "Last login", timeout: 15) && element("session-end-reason").waitForNonExistence(timeout: 15),
                      "the session comes back\n\(app.debugDescription)")
        shot("7-reconnected")
    }
}
