import XCTest

/// The Phase 1 exit criterion: list, connect, full screen, back to the list,
/// disconnect. It runs against `FakeRemoteSession` and an in-memory store, so
/// it needs no Windows host and leaves nothing behind.
final class ConnectionFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // The editor sheets here are where the app was seen to stall
        // (UITestConfiguration.withoutAnimationsArgument).
        app.launchArguments = ["-mremote-ui-testing", "-mremote-ui-testing-without-animations"]
        app.launch()
    }

    /// SwiftUI decides for itself whether a row becomes a button, a cell or a
    /// plain element, and that changes between OS versions. Matching on the
    /// identifier across every type keeps the test about the flow rather than
    /// about SwiftUI's current accessibility shape.
    /// Scrolls the session menu until `target` can be tapped. The drag
    /// starts in the sheet's left margin: one through the middle can land on
    /// a picker, which takes it as a press instead of a scroll.
    private func scrollMenu(to target: XCUIElement) {
        let menu = element("session-menu")
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: menu.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3)))
        }
    }

    /// Scrolls the connection editor until `target` can be tapped, in short
    /// drags along the sheet's left margin: with the keyboard up the sheet is
    /// small, and a whole swipe carries a row past before it is seen.
    private func scrollEditor(to target: XCUIElement) {
        let cancel = element("profile-cancel-button")
        guard cancel.waitForExistence(timeout: 5) else { return }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = cancel.frame.minX + 2
        let top = cancel.frame.maxY
        // The bar stays put over the form (keepsNavigationBarOnScroll), so a
        // row just under it reads as hittable while a tap there lands on the
        // bar: it has to be clear of it, and a row carried past comes back.
        // Likewise at the foot: the bar of suggestions over the keyboard
        // lives in a window of its own and doesn't count against hittable.
        let assistant = app.otherElements["SystemInputAssistantView"].firstMatch
        let keyboard = app.keyboards.element
        func bottom() -> CGFloat {
            if assistant.exists { return assistant.frame.minY }
            if keyboard.exists { return keyboard.frame.minY }
            return app.frame.maxY
        }
        for _ in 0..<15 {
            let clear = target.exists && target.isHittable && target.frame.minY >= top + 8
                && target.frame.maxY <= bottom()
            if clear { break }
            if target.exists && target.frame.minY < top + 8 {
                origin.withOffset(CGVector(dx: x, dy: top + 80))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: top + 160)))
            } else {
                origin.withOffset(CGVector(dx: x, dy: top + 220))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: top + 80)))
            }
        }
        // A tap while the form still glides only stops it: wait for it to
        // come to rest.
        var last = target.exists ? target.frame : .zero
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = target.exists ? target.frame : .zero
            if now == last { break }
            last = now
        }
    }

    /// Back from the screen titled `title`. Its own bar's first button: on
    /// an iPad the list behind a sheet has a navigation bar too. On a wide
    /// iPhone (the iPhone Duo open) the back button moves to the side bar
    /// and the bar's first button is whatever else it carries.
    private func goBack(from title: String) {
        let back = app.buttons["BackButton"].firstMatch
        if back.exists {
            back.tap()
        } else {
            app.navigationBars[title].buttons.element(boundBy: 0).tap()
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertAppears(
        _ identifier: String,
        timeout: TimeInterval = 15,
        _ message: String,
        line: UInt = #line
    ) -> XCUIElement {
        let target = element(identifier)
        XCTAssertTrue(
            target.waitForExistence(timeout: timeout),
            "\(message)\n\(app.debugDescription)",
            file: #filePath,
            line: line
        )
        return target
    }

    func testListConnectWorkspaceReturnAndDisconnect() {
        let row = assertAppears("profile-row-テスト接続先", "the seeded profile should be listed")
        row.tap()

        _ = assertAppears("session-workspace", "connecting presents the full-screen workspace")
        _ = assertAppears("session-status", "the workspace reports the session state")

        element("session-menu-button").tap()
        _ = assertAppears("session-return-to-list", "the floating menu opens")
        element("session-return-to-list").tap()

        // SES-02: leaving the workspace must not disconnect, so the session is
        // still listed as running.
        let running = assertAppears(
            "running-session-テスト接続先",
            "the session stays connected after returning to the list"
        )
        running.tap()

        _ = assertAppears("session-workspace", "a running session can be re-entered")
        element("session-menu-button").tap()
        _ = assertAppears("session-disconnect", "the floating menu opens")
        element("session-disconnect").tap()
        // Disconnecting names the session and asks first; returning does not.
        let confirm = app.buttons["切断"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "disconnect asks for confirmation")
        confirm.tap()

        _ = assertAppears("profile-row-テスト接続先", "disconnecting returns to the list")
        XCTAssertFalse(
            element("running-session-テスト接続先").exists,
            "a disconnected session is no longer running"
        )
    }

    func testAddingAProfileFromTheList() {
        element("add-profile-button").tap()

        let host = assertAppears("profile-host-field", "the editor sheet opens")
        element("profile-name-field").tap()
        app.typeText("新しい接続先")
        host.tap()
        app.typeText("192.168.0.10")

        element("profile-save-button").tap()
        _ = assertAppears("profile-row-新しい接続先", "the saved profile appears in the list")
    }

    /// A gateway and a shared folder are saved with the connection and
    /// come back in the editor.
    func testAGatewayAndASharedFolderAreKept() {
        element("add-profile-button").tap()
        let host = assertAppears("profile-host-field", "the editor sheet opens")
        element("profile-name-field").tap()
        app.typeText("社内PC")
        host.tap()
        app.typeText("pc.internal")

        let gateway = element("profile-gateway-toggle")
        scrollEditor(to: gateway)
        gateway.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let gatewayHost = assertAppears("profile-gateway-host-field", "the gateway's fields appear")
        gatewayHost.tap()
        app.typeText("gw.example.com")
        // Put the keyboard away: while the field holds the focus, the form
        // may scroll back to it as the folder menu opens, and the menu goes.
        app.typeText("\n")
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5))

        let folder = element("profile-shared-folder-picker")
        scrollEditor(to: folder)
        folder.tap()
        let appFolder = app.buttons["このアプリのフォルダ"].firstMatch
        XCTAssertTrue(appFolder.waitForExistence(timeout: 5), "the folder choices are listed")
        appFolder.tap()
        element("profile-save-button").tap()

        let row = assertAppears("profile-row-社内PC", "the connection is saved")
        row.swipeLeft()
        let edit = app.buttons["編集"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let reopened = element("profile-gateway-host-field")
        scrollEditor(to: reopened)
        XCTAssertEqual(reopened.value as? String, "gw.example.com", "the gateway comes back")
        let reopenedFolder = element("profile-shared-folder-picker")
        scrollEditor(to: reopenedFolder)
        XCTAssertTrue(
            (reopenedFolder.value as? String)?.contains("このアプリのフォルダ") == true
                || app.staticTexts["このアプリのフォルダ"].exists,
            "the shared folder comes back\n\(app.debugDescription)"
        )
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["MREMOTE_UITEST_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// A proxy is saved once, from the editor, picked for the connection,
    /// comes back with it, and the settings list says who uses it.
    func testAProxyIsSavedOnceAndPickedPerConnection() {
        element("add-profile-button").tap()
        let host = assertAppears("profile-host-field", "the editor sheet opens")
        element("profile-name-field").tap()
        app.typeText("プロキシ越し")
        host.tap()
        app.typeText("desk.internal")

        // A tap right after typing can be spent on the keyboard; try twice.
        let manage = element("profile-manage-proxies")
        manage.tap()
        if !element("proxy-add").waitForExistence(timeout: 3) { manage.tap() }
        _ = assertAppears("proxy-add", "the proxy list opens")
        element("proxy-add").tap()
        let proxyHost = assertAppears("proxy-host-field", "the proxy sheet opens")
        element("proxy-name-field").tap()
        app.typeText("社内プロキシ")
        proxyHost.tap()
        app.typeText("socks.example")
        element("proxy-port-field").tap()
        app.typeText("1081")
        shot("proxy-1-editor")
        // On iPad the number pad floats in a popover, and the first tap
        // outside it only closes the popover.
        let save = element("proxy-save")
        save.tap()
        if save.waitForExistence(timeout: 2), save.isHittable { save.tap() }
        _ = assertAppears("proxy-row", "the saved proxy is listed")
        shot("proxy-2-list")
        goBack(from: "プロキシ")

        let picker = assertAppears("profile-proxy-picker", "back on the connection editor")
        picker.tap()
        let choice = app.buttons["社内プロキシ"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the saved proxy can be picked\n\(app.debugDescription)")
        choice.tap()
        shot("proxy-3-picked")
        element("profile-save-button").tap()

        let row = assertAppears("profile-row-プロキシ越し", "the connection is saved")
        row.swipeLeft()
        let edit = app.buttons["編集"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let reopened = assertAppears("profile-proxy-picker", "the editor reopens")
        XCTAssertTrue(
            (reopened.value as? String)?.contains("社内プロキシ") == true
                || app.staticTexts["社内プロキシ"].exists,
            "the proxy comes back\n\(app.debugDescription)"
        )
        element("profile-cancel-button").tap()

        element("settings-button").tap()
        let link = element("settings-proxies")
        for _ in 0..<8 where !(link.exists && link.isHittable) {
            element("settings-screen").swipeUp()
        }
        link.tap()
        _ = assertAppears("proxy-row", "the settings list shows the proxy")
        XCTAssertTrue(app.staticTexts["1 件の接続先で使用中"].waitForExistence(timeout: 5),
                      "the list says it is in use\n\(app.debugDescription)")
        shot("proxy-4-settings")
    }

    /// Groups head their connections, favourites come first, and the
    /// search narrows the list.
    func testGroupsFavouritesAndSearch() {
        element("add-profile-button").tap()
        let host = assertAppears("profile-host-field", "the editor sheet opens")
        element("profile-name-field").tap()
        app.typeText("NAS")
        host.tap()
        app.typeText("nas.local")
        element("profile-group-field").tap()
        app.typeText("Home")
        element("profile-save-button").tap()
        _ = assertAppears("profile-row-NAS", "the connection is saved")
        XCTAssertTrue(app.staticTexts["HOME"].exists || app.staticTexts["Home"].exists, "its group heads it")

        // Favourite from the leading swipe.
        element("profile-row-テスト接続先").swipeRight()
        let favourite = app.buttons["お気に入り"].firstMatch
        XCTAssertTrue(favourite.waitForExistence(timeout: 5))
        favourite.tap()
        XCTAssertTrue(app.staticTexts["お気に入り"].waitForExistence(timeout: 5), "favourites get their own section")

        // On a wide iPhone the search sits behind a button in the side bar.
        let search = app.searchFields.firstMatch
        let searchButton = app.buttons["検索"].firstMatch
        if !search.exists, searchButton.exists { searchButton.tap() }
        if !search.waitForExistence(timeout: 2) { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        app.typeText("nas")
        XCTAssertTrue(element("profile-row-NAS").waitForExistence(timeout: 5))
        XCTAssertTrue(element("profile-row-テスト接続先").waitForNonExistence(timeout: 5), "the search narrows the list")
    }

    /// Wake-on-LAN refuses an address that is not six bytes.
    func testWakeOnLANNeedsAWholeMACAddress() {
        element("add-profile-button").tap()
        let host = assertAppears("profile-host-field", "the editor sheet opens")
        host.tap()
        app.typeText("pc.local")
        let wake = element("profile-wake-toggle")
        scrollEditor(to: wake)
        wake.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let mac = assertAppears("profile-mac-field", "the address field appears")
        mac.tap()
        app.typeText("AA:BB:CC")
        XCTAssertFalse(element("profile-save-button").isEnabled, "half an address cannot be saved")
        app.typeText(":01:02:03")
        XCTAssertTrue(element("profile-save-button").isEnabled)
    }

    /// iPad: a connection opens in a window of its own and is listed as
    /// running; it is never shown over the list as well.
    func testAConnectionOpensInItsOwnWindow() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        let row = assertAppears("profile-row-テスト接続先", "the list is up")
        row.press(forDuration: 1.2)
        let newWindow = element("connect-new-window")
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5), "the context menu offers a window")
        newWindow.tap()
        _ = assertAppears("session-workspace", timeout: 20, "the session window shows the desktop")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "session-window"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheSoftwareKeyboardOpensFromTheMenuAndCloses() {
        element("profile-row-テスト接続先").tap()
        _ = assertAppears("session-workspace", "connecting presents the workspace")
        element("session-menu-button").tap()
        let show = assertAppears("session-show-keyboard", "the menu offers the keyboard")
        show.tap()

        // The extended key bar rides on the keyboard as its accessory view.
        let escape = assertAppears("key-escape", "the extended key bar appears")
        XCTAssertTrue(element("modifier-control").exists)
        XCTAssertTrue(element("software-keyboard-mode").exists)
        XCTAssertTrue(escape.isHittable)

        element("modifier-control").tap()
        XCTAssertEqual(element("modifier-control").value as? String, "次の1キー")
        element("modifier-control").tap()
        XCTAssertEqual(element("modifier-control").value as? String, "固定")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "software-keyboard"
        shot.lifetime = .keepAlways
        add(shot)

        element("software-keyboard-close").tap()
        XCTAssertTrue(
            element("key-escape").waitForNonExistence(timeout: 5),
            "closing removes the bar"
        )
    }

    /// Any device can put the PC keyboard on screen from the menu's action
    /// list, and take it away again, without hunting for the picker.
    /// The button above the menu button, as in the Windows App: it brings
    /// the iOS keyboard up, and takes whichever keyboard is up away.
    func testTheKeyboardButtonShowsAndHidesTheKeyboard() {
        element("profile-row-テスト接続先").tap()
        _ = assertAppears("session-workspace", "connecting presents the workspace")

        let button = assertAppears("session-keyboard-button", "the keyboard button is beside the menu")
        button.tap()
        _ = assertAppears("key-escape", "the iOS keyboard comes up with its key bar")
        button.tap()
        XCTAssertTrue(element("key-escape").waitForNonExistence(timeout: 5), "and goes away")

        // A deck that is up is what the button takes away.
        element("session-menu-button").tap()
        _ = assertAppears("session-menu", "the floating menu opens")
        element("session-toggle-laptop-deck").tap()
        _ = assertAppears("laptop-deck", "the deck takes the lower half")
        element("session-keyboard-button").tap()
        XCTAssertTrue(element("laptop-deck").waitForNonExistence(timeout: 5), "the button hides the deck")
    }

    /// Tucked, the buttons leave a sliver at the edge; the first tap only
    /// brings them back.
    func testTuckedButtonsComeBackOnTheFirstTap() {
        element("profile-row-テスト接続先").tap()
        _ = assertAppears("session-workspace", "connecting presents the workspace")
        element("session-menu-button").tap()
        let style = element("session-buttons-idle-style")
        scrollMenu(to: style)
        style.tap()
        let tuck = app.buttons["画面の端に寄せる"].firstMatch
        XCTAssertTrue(tuck.waitForExistence(timeout: 5), "the styles are listed")
        tuck.tap()
        element("session-menu-close").tap()

        let button = element("session-menu-button")
        let screen = app.windows.firstMatch.frame
        let tucked = expectation(for: NSPredicate { _, _ in button.frame.maxX > screen.maxX + 20 }, evaluatedWith: nil)
        wait(for: [tucked], timeout: 8)
        // The sliver left on screen.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.maxX - 6, dy: button.frame.midY))
            .tap()
        let back = expectation(for: NSPredicate { _, _ in button.frame.maxX <= screen.maxX }, evaluatedWith: nil)
        wait(for: [back], timeout: 3)
        XCTAssertFalse(element("session-menu").exists, "the tap that brings them back opens nothing")
    }

    /// The user's shortcuts ride on the key bar and the deck, and the list
    /// is edited from the session menu.
    func testShortcutsAppearOnTheBarsAndCanBeAdded() {
        element("profile-row-テスト接続先").tap()
        _ = assertAppears("session-workspace", "connecting presents the workspace")

        element("session-keyboard-button").tap()
        let barShortcut = assertAppears("shortcut-Ctrl+Alt+Delete", "the key bar carries the standard shortcuts")
        barShortcut.tap()
        element("software-keyboard-close").tap()

        element("session-menu-button").tap()
        let edit = element("session-edit-shortcuts")
        scrollMenu(to: edit)
        edit.tap()
        let suggestion = assertAppears("shortcut-suggestion-Win+D", "the editor offers common shortcuts")
        suggestion.tap()
        _ = assertAppears("shortcut-row-Win+D", "a suggestion joins the list")
        goBack(from: "ショートカット")
        _ = assertAppears("session-menu-close", "back in the menu")
        element("session-menu-close").tap()

        element("session-menu-button").tap()
        _ = assertAppears("session-menu", "the floating menu opens")
        element("session-toggle-laptop-deck").tap()
        _ = assertAppears("deck-shortcut-Win+D", "the deck carries the new shortcut")
    }

    func testTheMenuShowsAndHidesThePCKeyboard() {
        element("profile-row-テスト接続先").tap()
        _ = assertAppears("session-workspace", "connecting presents the workspace")

        element("session-menu-button").tap()
        _ = assertAppears("session-menu", "the floating menu opens")
        element("session-toggle-laptop-deck").tap()
        _ = assertAppears("laptop-deck", "the deck takes the lower half")
        XCTAssertTrue(element("laptop-key-a").exists)

        element("session-menu-button").tap()
        _ = assertAppears("session-menu", "the floating menu opens again")
        element("session-toggle-laptop-deck").tap()
        XCTAssertTrue(element("laptop-deck").waitForNonExistence(timeout: 5), "hiding takes it away")
    }

    /// The laptop deck can be forced on from the menu, which is how it is
    /// reached on a device - or a Simulator - that is not folded.
    func testTheLaptopDeckCanBeShownFromTheMenu() {
        element("profile-row-テスト接続先").tap()
        _ = assertAppears("session-workspace", "connecting presents the workspace")
        // Whether the deck is already up depends on the Simulator's hinge,
        // which the test cannot set; forcing it on is what is under test.

        element("session-menu-button").tap()
        _ = assertAppears("session-menu", "the floating menu opens")
        let picker = element("session-laptop-deck-picker")
        // The input section sits below the sheet's medium detent.
        scrollMenu(to: picker)
        XCTAssertTrue(picker.isHittable, "the menu offers the deck\n\(app.debugDescription)")
        picker.tap()
        let always = app.buttons["常に表示"].firstMatch
        XCTAssertTrue(always.waitForExistence(timeout: 5), "the picker lists its options")
        always.tap()
        element("session-menu-close").tap()

        _ = assertAppears("laptop-deck", "the deck takes the lower half")
        XCTAssertTrue(element("laptop-trackpad").exists)
        XCTAssertTrue(element("laptop-button-left").exists)
        XCTAssertTrue(element("laptop-key-a").exists)
        XCTAssertTrue(element("laptop-key-kana").exists, "the seeded profile is Japanese")
        XCTAssertTrue(element("session-menu-button").isHittable, "the menu stays reachable above the deck")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "laptop-deck"
        shot.lifetime = .keepAlways
        add(shot)

        // Keyboard only: the pad and its buttons go, the keys stay.
        element("session-menu-button").tap()
        let arrangement = element("session-laptop-deck-arrangement")
        scrollMenu(to: arrangement)
        arrangement.tap()
        let keyboardOnly = app.buttons["キーボードのみ（画面を触って操作）"].firstMatch
        XCTAssertTrue(keyboardOnly.waitForExistence(timeout: 5), "the arrangement picker lists its options")
        keyboardOnly.tap()
        element("session-menu-close").tap()
        XCTAssertTrue(element("laptop-key-a").waitForExistence(timeout: 5))
        XCTAssertFalse(element("laptop-trackpad").isHittable, "keyboard only hides the pad")
        XCTAssertFalse(element("laptop-button-left").isHittable)

        // Put the stored arrangement back for the next run.
        element("session-menu-button").tap()
        scrollMenu(to: arrangement)
        arrangement.tap()
        app.buttons["キーボード / トラックパッド"].firstMatch.tap()
        element("session-menu-close").tap()
    }
}
