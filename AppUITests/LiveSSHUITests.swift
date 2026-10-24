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
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
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
            XCTAssertTrue(element("session-terminal-paste").waitForExistence(timeout: 5))
            shot("5-menu")
            // To the list and back: the same terminal, with what it showed.
            element("session-return-to-list").tap()
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
    }
}
