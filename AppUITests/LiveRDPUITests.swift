import UIKit
import XCTest

/// Connects the real app to a real Windows host, then holds the session open
/// so it can be driven and inspected from outside the test - by hand, or by
/// a script tapping the Simulator and reading the host over SSH.
///
/// Skipped unless the host is given. Nothing about the host is in the
/// repository; pass it to `xcodebuild test` as
///
///     TEST_RUNNER_MREMOTE_LIVE_HOST=192.0.2.10
///     TEST_RUNNER_MREMOTE_LIVE_USER=someone
///     TEST_RUNNER_MREMOTE_LIVE_PASSWORD=...
///     TEST_RUNNER_MREMOTE_LIVE_HOLD=600      # seconds to keep the session
///     TEST_RUNNER_MREMOTE_LIVE_COMMANDS=/path/commands.txt   # optional
///     TEST_RUNNER_MREMOTE_APP_<NAME>=<value>                  # app environment
///
/// With a command file, lines appended to it while the session is held are
/// carried out in order, and `<file>.done` gets one line per finished
/// command. Elements are named by accessibility identifier; fractions are
/// of the element's size.
///
///     tap <id>                         tap
///     twotap <id|window>               two-finger tap
///     pinch <id|window> <scale>        pinch, apart above 1
///     fingers <id> <seconds> <fx1> <fy1> <fx2> <fy2> [<dx> <dy> [<late>]]
///                                      two fingers down together (the second
///                                      <late> seconds after), moved by dx, dy
///                                      (fractions) over the time, lifted
///     doubletap <id>                   double tap
///     hold <id> <seconds>              press and hold
///     tapat <id> <fx> <fy>             tap at a point
///     drag <id> <fx1> <fy1> <fx2> <fy2> [holdSeconds]
///     tapdrag <id> <fx1> <fy1> <fx2> <fy2>  tap, then at once press and drag
///     keys <id> <id> ...               tap each in turn
///     sleep <seconds>
///     value <id>                       report the element's value
///     frame <id>                       report the element's frame
///     swipeup <id>                     swipe up on an element
///     button <label>                   tap the button with this label
///     back                             the navigation bar's back button
///     setpasteboard <base64>           put UTF-8 text on the device pasteboard
///     pasteboard                       report the pasteboard text, base64
///     type <text>                      type into the focused field
///     scroll <id> <dx> <dy>            a pointer scroll over an element
///     key <label>                      tap a key of the iOS software keyboard
///     textfield <label>                tap the text field with this label
///     orient <portrait|left|right>     rotate the device
///
/// The password is typed into the credential prompt and not saved.
final class LiveRDPUITests: XCTestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment
    /// TEST_RUNNER_MREMOTE_LIVE_PROFILE picks another name, so a second host
    /// (a Mac, say) keeps its own profile beside the Windows one.
    private var profileName: String { environment["MREMOTE_LIVE_PROFILE"] ?? "Live RDP" }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testConnectAndHold() throws {
        guard let host = environment["MREMOTE_LIVE_HOST"],
              let user = environment["MREMOTE_LIVE_USER"],
              let password = environment["MREMOTE_LIVE_PASSWORD"] else {
            throw XCTSkip("MREMOTE_LIVE_HOST, _USER and _PASSWORD are not set")
        }
        let hold = TimeInterval(environment["MREMOTE_LIVE_HOLD"] ?? "") ?? 300
        continueAfterFailure = false
        app = XCUIApplication()
        // TEST_RUNNER_MREMOTE_APP_<NAME>=value reaches the app as <NAME>:
        // FreeRDP's WLOG_LEVEL and WLOG_APPENDER, for instance.
        for (key, value) in environment where key.hasPrefix("MREMOTE_APP_") {
            app.launchEnvironment[String(key.dropFirst("MREMOTE_APP_".count))] = value
        }
        // TEST_RUNNER_MREMOTE_LIVE_ARGS: launch arguments, space separated,
        // such as -mremote-fake-external-display.
        app.launchArguments += (environment["MREMOTE_LIVE_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launch()

        let row = element("profile-row-\(profileName)")
        if !row.waitForExistence(timeout: 5) {
            addProfile(host: host, user: user)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the profile is listed")
        row.tap()
        XCTAssertTrue(element("session-workspace").waitForExistence(timeout: 15))

        answerChallenges(password: password)
        XCTAssertTrue(
            element("session-status").waitForNonExistence(timeout: 60),
            "the desktop replaces the status text\n\(app.debugDescription)"
        )
        // Held for whoever is driving: the session stays up until this ends.
        let commandPath = environment["MREMOTE_LIVE_COMMANDS"]
        var performed = 0
        let deadline = Date().addingTimeInterval(hold)
        while Date() < deadline {
            // Prompts can come back, after a reconnect for instance.
            answerChallenges(password: password, wait: 0)
            if let commandPath {
                let lines = ((try? String(contentsOfFile: commandPath, encoding: .utf8)) ?? "")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                while performed < lines.count {
                    let result = perform(lines[performed])
                    performed += 1
                    append("\(performed) \(result) \(lines[performed - 1])\n", to: commandPath + ".done")
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func perform(_ line: String) -> String {
        let words = line.split(separator: " ").map(String.init)
        guard let verb = words.first else { return "empty" }
        let arguments = Array(words.dropFirst())
        func target(_ index: Int = 0) -> XCUIElement? {
            guard arguments.count > index else { return nil }
            let found = element(arguments[index])
            return found.exists ? found : nil
        }
        func number(_ index: Int) -> CGFloat {
            arguments.count > index ? CGFloat(Double(arguments[index]) ?? 0) : 0
        }
        switch verb {
        case "tap":
            // The rest of the line, so identifiers with spaces work.
            let found = element(arguments.joined(separator: " "))
            guard found.waitForExistence(timeout: 3) else { return "missing" }
            found.tap()
        case "back":
            let back = app.navigationBars.buttons.firstMatch
            guard back.waitForExistence(timeout: 3) else { return "missing" }
            back.tap()
        case "doubletap":
            guard let target = target() else { return "missing" }
            target.doubleTap()
        case "twotap":
            // "window": the window's centre, for a surface whose floating
            // buttons stop XCUI computing a point on it.
            let tapped = arguments.first == "window" ? app.windows.firstMatch : target()
            guard let tapped else { return "missing" }
            tapped.twoFingerTap()
        case "pinch":
            let pinched = arguments.first == "window" ? app.windows.firstMatch : target()
            guard let pinched else { return "missing" }
            pinched.pinch(withScale: number(1), velocity: number(1) < 1 ? -1 : 1)
        case "hold":
            // Everything before the duration is the identifier.
            let held = element(arguments.dropLast().joined(separator: " "))
            guard held.waitForExistence(timeout: 3) else { return "missing" }
            held.press(forDuration: TimeInterval(Double(arguments.last ?? "") ?? 1))
        case "tapat":
            guard let target = target() else { return "missing" }
            target.coordinate(withNormalizedOffset: CGVector(dx: number(1), dy: number(2))).tap()
        case "drag":
            guard let target = target() else { return "missing" }
            let from = target.coordinate(withNormalizedOffset: CGVector(dx: number(1), dy: number(2)))
            let to = target.coordinate(withNormalizedOffset: CGVector(dx: number(3), dy: number(4)))
            from.press(forDuration: max(TimeInterval(number(5)), 0.05), thenDragTo: to)
        case "tapdrag":
            // Tap-and-a-half: the drag starts within the double-tap interval.
            guard let target = target() else { return "missing" }
            let from = target.coordinate(withNormalizedOffset: CGVector(dx: number(1), dy: number(2)))
            let to = target.coordinate(withNormalizedOffset: CGVector(dx: number(3), dy: number(4)))
            from.tap()
            from.press(forDuration: 0.05, thenDragTo: to)
        case "fingers":
            guard let target = target() else { return "missing" }
            let size = target.frame.size
            let points = [CGVector(dx: number(2), dy: number(3)), CGVector(dx: number(4), dy: number(5))]
                .map { target.coordinate(withNormalizedOffset: $0).screenPoint }
            let shift = CGVector(dx: number(6) * size.width, dy: number(7) * size.height)
            return synthesizeFingers(at: points, moving: shift, over: Double(number(1)), secondLate: Double(number(8)))
        case "paths":
            // paths <target> <seconds> x0 y0 x1 y1 [x0 y0 x1 y1 ...]: each
            // finger from one normalized point to another, all together -
            // three fingers swiping, two spreading.
            guard let target = target() else { return "missing" }
            var starts: [CGPoint] = []
            var ends: [CGPoint] = []
            var index = 2
            while arguments.count >= index + 4 {
                starts.append(target.coordinate(withNormalizedOffset: CGVector(dx: number(index), dy: number(index + 1))).screenPoint)
                ends.append(target.coordinate(withNormalizedOffset: CGVector(dx: number(index + 2), dy: number(index + 3))).screenPoint)
                index += 4
            }
            return synthesizeFingers(at: starts, moving: .zero, over: Double(number(1)), secondLate: 0, to: ends)
        case "keys":
            for identifier in arguments {
                let key = element(identifier)
                guard key.exists else { return "missing \(identifier)" }
                key.tap()
            }
        case "swipeup":
            guard let target = target() else { return "missing" }
            target.swipeUp()
        case "button":
            let button = app.buttons[arguments.joined(separator: " ")].firstMatch
            guard button.waitForExistence(timeout: 3) else { return "missing" }
            button.tap()
        case "setpasteboard":
            guard let data = Data(base64Encoded: arguments.first ?? ""),
                  let text = String(data: data, encoding: .utf8) else { return "bad base64" }
            UIPasteboard.general.string = text
        case "springboard":
            // A system alert, such as the microphone permission prompt.
            let button = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                .buttons[arguments.joined(separator: " ")].firstMatch
            guard button.waitForExistence(timeout: 5) else { return "missing" }
            button.tap()
        case "setpasteboardimage":
            // 120x80, red on the left and blue on the right, to recognise
            // on the other side.
            let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
                UIColor.blue.setFill()
                context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
            }
            UIPasteboard.general.image = image
        case "pasteboard":
            let text = UIPasteboard.general.string ?? ""
            return "pasteboard=" + Data(text.utf8).base64EncodedString()
        case "textfield":
            let field = app.textFields[arguments.joined(separator: " ")].firstMatch
            guard field.waitForExistence(timeout: 3) else { return "missing" }
            field.tap()
        case "key":
            let key = app.keys[arguments.joined(separator: " ")].firstMatch
            guard key.waitForExistence(timeout: 3) else { return "missing" }
            key.tap()
        case "scroll":
            guard let target = target() else { return "missing" }
            target.scroll(byDeltaX: number(1), deltaY: number(2))
        case "type":
            // "\n" in the command is the return key, "\b" backspace.
            app.typeText(arguments.joined(separator: " ")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\b", with: XCUIKeyboardKey.delete.rawValue))
        case "frame":
            let target = element(arguments.joined(separator: " "))
            guard target.waitForExistence(timeout: 3) else { return "missing" }
            return "frame=\(target.frame) window=\(app.windows.firstMatch.frame)"
        case "value":
            let target = element(arguments.joined(separator: " "))
            guard target.waitForExistence(timeout: 3) else { return "missing" }
            return "value=\(target.value.map { "\($0)" } ?? "nil") label=\(target.label)"
        case "orient":
            let orientations: [String: UIDeviceOrientation] = [
                "portrait": .portrait, "left": .landscapeLeft, "right": .landscapeRight,
            ]
            guard let orientation = orientations[arguments.first ?? ""] else { return "unknown orientation" }
            XCUIDevice.shared.orientation = orientation
        case "chord":
            // chord <modifiers> <key>: cmd+shift+ctrl+opt, e.g. "chord cmd k",
            // as a hardware keyboard event.
            var flags: XCUIElement.KeyModifierFlags = []
            for part in (arguments.first ?? "").split(separator: "+") {
                switch part {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "ctrl": flags.insert(.control)
                case "opt": flags.insert(.option)
                default: break
                }
            }
            let key = arguments.count > 1 ? arguments[1] : ""
            let special: [String: String] = [
                "return": XCUIKeyboardKey.return.rawValue, "space": XCUIKeyboardKey.space.rawValue,
                "up": XCUIKeyboardKey.upArrow.rawValue, "down": XCUIKeyboardKey.downArrow.rawValue,
                "left": XCUIKeyboardKey.leftArrow.rawValue, "right": XCUIKeyboardKey.rightArrow.rawValue,
                "tab": XCUIKeyboardKey.tab.rawValue, "escape": XCUIKeyboardKey.escape.rawValue,
            ]
            app.typeKey(special[key] ?? key, modifierFlags: flags)
        case "sleep":
            Thread.sleep(forTimeInterval: TimeInterval(number(0)))
        default:
            return "unknown"
        }
        return "ok"
    }

    /// Fingers that go down together, which XCUIElement's twoFingerTap does
    /// not manage on the desktop surface. XCTest's own event synthesizer,
    /// reached through the runtime: XCPointerEventPath and
    /// XCSynthesizedEventRecord are not public API.
    private func synthesizeFingers(
        at points: [CGPoint], moving shift: CGVector, over duration: Double, secondLate: Double,
        to ends: [CGPoint]? = nil
    ) -> String {
        guard let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type
        else { return "no synthesizer" }
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias MoveTo = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias LiftUp = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool
        func call<T>(_ object: AnyObject, _ name: String, as type: T.Type) -> T? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            return unsafeBitCast(method, to: type)
        }
        let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
        guard let recordAlloc = recordClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let makeRecord = call(recordAlloc, "initWithName:interfaceOrientation:", as: InitRecord.self)
        else { return "no record" }
        let record = makeRecord(recordAlloc, initRecord, "fingers", UIInterfaceOrientation.portrait.rawValue)
        let steps = 10
        for (index, point) in points.enumerated() {
            let start = index == 0 ? 0 : secondLate
            guard let pathAlloc = pathClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
                  let makePath = call(pathAlloc, "initForTouchAtPoint:offset:", as: InitPath.self)
            else { return "no path" }
            let path = makePath(pathAlloc, NSSelectorFromString("initForTouchAtPoint:offset:"), point, start)
            let travel = ends.map { CGVector(dx: $0[index].x - point.x, dy: $0[index].y - point.y) } ?? shift
            if travel != .zero, let move = call(path, "moveToPoint:atOffset:", as: MoveTo.self) {
                for step in 1...steps {
                    let fraction = Double(step) / Double(steps)
                    let to = CGPoint(x: point.x + travel.dx * fraction, y: point.y + travel.dy * fraction)
                    move(path, NSSelectorFromString("moveToPoint:atOffset:"), to, start + (duration - start) * fraction)
                }
            }
            guard let lift = call(path, "liftUpAtOffset:", as: LiftUp.self),
                  let add = call(record, "addPointerEventPath:", as: AddPath.self)
            else { return "no lift" }
            lift(path, NSSelectorFromString("liftUpAtOffset:"), max(duration, start + 0.05))
            add(record, NSSelectorFromString("addPointerEventPath:"), path)
        }
        guard let synthesize = call(record, "synthesizeWithError:", as: Synthesize.self) else { return "no synthesize" }
        var error: NSError?
        return synthesize(record, NSSelectorFromString("synthesizeWithError:"), &error)
            ? "ok" : "failed \(error.map { "\($0)" } ?? "")"
    }

    private func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
    }

    private func addProfile(host: String, user: String) {
        let add = element("add-profile-button").exists
            ? element("add-profile-button") : element("empty-add-profile-button")
        add.tap()
        let name = element("profile-name-field")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        // A Japanese simulator types into the romaji keyboard, which turns
        // a host name into kana: move on to a Latin keyboard first.
        let globe = app.keyboards.buttons["次のキーボード"].firstMatch
        for _ in 0..<3 where globe.exists && ((globe.value as? String) ?? "").contains("日本語") {
            globe.tap()
        }
        app.typeText(profileName)
        element("profile-host-field").tap()
        app.typeText(host)
        // TEST_RUNNER_MREMOTE_LIVE_PORT: a forwarded port, for instance.
        if let port = environment["MREMOTE_LIVE_PORT"] {
            let field = element("profile-port-field")
            field.tap()
            let current = (field.value as? String) ?? ""
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + port)
        }
        let username = app.textFields["ユーザー名"].firstMatch
        // On a short screen (the iPhone Duo folded) the row is built only
        // once the form scrolls to it.
        let editor = app.collectionViews
            .matching(NSPredicate(format: "identifier != 'profile-list'")).firstMatch
        // Dragged high up: the keyboard's bar of suggestions covers the middle.
        for _ in 0..<10 where !(username.exists && username.isHittable) {
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        username.tap()
        app.typeText(user)
        // TEST_RUNNER_MREMOTE_LIVE_PLATFORM=macOS: a Mac running macos-rdp-server.
        if environment["MREMOTE_LIVE_PLATFORM"] == "macOS" {
            let picker = element("profile-platform-picker")
            // The form builds rows as they scroll in: scroll the list itself
            // (the keyboard from the fields may still be up).
            let form = app.collectionViews
                .matching(NSPredicate(format: "identifier != 'profile-list'")).firstMatch
            for _ in 0..<15 where !(picker.exists && picker.isHittable) {
                form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                    .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
            }
            picker.tap()
            let option = app.buttons["macOS（macos-rdp-server）"].firstMatch
            if option.waitForExistence(timeout: 3) { option.tap() }
        }
        element("profile-save-button").tap()
    }

    /// Certificate review and credentials, in whichever order the host asks.
    private func answerChallenges(password: String, wait: TimeInterval = 30) {
        // Each answer restarts the wait: the next prompt can take a while,
        // as the certificate does when the host asks for credentials first.
        var deadline = Date().addingTimeInterval(wait)
        repeat {
            if element("certificate-trust-always").exists {
                element("certificate-trust-always").tap()
                deadline = Date().addingTimeInterval(wait)
            } else if app.navigationBars["サーバー証明書の確認"].exists {
                // A long warning pushes the buttons below the sheet, and the
                // form does not build rows it has not scrolled to.
                app.collectionViews.firstMatch.swipeUp()
            } else if element("challenge-password").exists {
                element("challenge-password").tap()
                app.typeText(password)
                element("challenge-connect").tap()
                deadline = Date().addingTimeInterval(wait)
            } else if wait > 0, !element("session-status").exists {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
    }
}
