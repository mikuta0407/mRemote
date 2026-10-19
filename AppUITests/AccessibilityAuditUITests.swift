import XCTest

/// Runs Xcode's accessibility audit over each screen against the fake
/// session (docs/ui-flow.md section 10). Every issue is attached to the
/// test with the element it was found on, and fails the test unless it is
/// listed in `knownIssues` with a reason.
final class AccessibilityAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        // It opens sheet after sheet, where the app was seen to stall
        // (UITestConfiguration.withoutAnimationsArgument).
        app.launchArguments = ["-mremote-ui-testing", "-mremote-ui-testing-without-animations"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Issues that are accepted on purpose, by the element identifier they
    /// are found on (a trailing `*` matches any identifier starting with the
    /// rest) and the audit type.
    private static let knownIssues: [(identifier: String, type: XCUIAccessibilityAuditType)] = [
        // The remote desktop is a picture of another computer: its contrast
        // and text are the remote's, not ours to fix.
        ("remote-desktop-surface", .contrast),
        ("remote-desktop-surface", .textClipped),
        // A navigation bar caps its buttons' text size; the system does it,
        // and the audit calls that "partially unsupported".
        ("profile-cancel-button", .dynamicType),
        // A key cap's text grows with the text setting only as far as the
        // key, which is a fixed share of the deck as on a real keyboard;
        // VoiceOver reads each key by name instead.
        ("laptop-key-cap", .dynamicType),
        // A full PC keyboard, function row included, across a phone held
        // as a laptop: on the iPhone Duo its keys come out smaller than the
        // audit's minimum. Fewer, bigger keys would no longer be a PC
        // keyboard; the iOS keyboard, with its own key size, is one tap away.
        ("laptop-key-*", .hitRegion),
        // Plain Text in a List, which follows the text setting. The audit
        // grows text where it stands, so rows it pushes below the screen
        // come back as "partially unsupported", which rows depending on
        // where the list is scrolled.
        ("help-row", .dynamicType),
    ]

    /// Collects what the audit handler saw; the handler may not touch the
    /// test case itself.
    private final class IssueLog: @unchecked Sendable {
        var lines: [String] = []
    }

    private func audit(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let log = IssueLog()
        let known = Self.knownIssues
        do {
            try app.performAccessibilityAudit { issue in
                let identifier = issue.element?.identifier ?? ""
                let label = issue.element?.label ?? ""
                let isKnown = known.contains {
                    let matches = $0.identifier.hasSuffix("*")
                        ? identifier.hasPrefix(String($0.identifier.dropLast()))
                        : identifier == $0.identifier
                    return matches && $0.type == issue.auditType
                }
                log.lines.append("\(issue.compactDescription) id=\(identifier) label=\(label) known=\(isKnown)")
                return isKnown
            }
        } catch {
            XCTFail("[\(screen)] \(error)", file: file, line: line)
        }
        for entry in log.lines {
            print("A11Y [\(screen)] \(entry)")
        }
        if !log.lines.isEmpty {
            let attachment = XCTAttachment(string: log.lines.joined(separator: "\n"))
            attachment.name = "a11y-\(screen)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testEveryScreenPassesTheAudit() {
        XCTAssertTrue(element("profile-list").waitForExistence(timeout: 10))
        audit("list")

        element("add-profile-button").tap()
        XCTAssertTrue(element("profile-host-field").waitForExistence(timeout: 5))
        audit("editor")
        element("profile-cancel-button").tap()

        element("settings-button").tap()
        XCTAssertTrue(element("settings-screen").waitForExistence(timeout: 5))
        audit("settings")
        let help = element("help-link")
        for _ in 0..<6 where !(help.exists && help.isHittable) {
            element("settings-screen").swipeUp()
        }
        help.tap()
        XCTAssertTrue(element("help-screen").waitForExistence(timeout: 5))
        audit("help")
        // On a wide iPhone the back button sits in the side bar, not on
        // the navigation bar.
        let back = app.buttons["BackButton"].firstMatch
        if back.exists {
            back.tap()
        } else {
            app.navigationBars["ヘルプ"].buttons.firstMatch.tap()
        }
        element("settings-done-button").tap()

        element("profile-row-テスト接続先").tap()
        XCTAssertTrue(element("session-workspace").waitForExistence(timeout: 15))
        audit("workspace")

        element("session-menu-button").tap()
        XCTAssertTrue(element("session-menu").waitForExistence(timeout: 5))
        audit("session-menu")

        // The laptop deck, forced on so it is there whatever the hinge does.
        let picker = element("session-laptop-deck-picker")
        for _ in 0..<6 where !(picker.exists && picker.isHittable) {
            element("session-menu").swipeUp()
        }
        picker.tap()
        app.buttons["常に表示"].firstMatch.tap()
        element("session-menu-close").tap()
        XCTAssertTrue(element("laptop-deck").waitForExistence(timeout: 5))
        audit("laptop-deck")
    }
}
