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
        (element("terminal-surface").value as? String) ?? ""
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

        // The menu: an SSH session shows its own items.
        let menuButton = element("session-menu-button")
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            XCTAssertTrue(element("session-terminal-paste").waitForExistence(timeout: 5))
            shot("4-menu")
            element("session-menu-close").tap()
        }

        app.typeText("exit\n")
        XCTAssertTrue(element("session-end-reason").waitForExistence(timeout: 15), "the shell's exit is shown")
        shot("5-exited")
    }
}
