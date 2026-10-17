import XCTest
import SessionCore
@testable import SSHProtocol

final class SSHSignInPlannerTests: XCTestCase {
    private let all: SSHSignInMethods = [.publicKey, .keyboardInteractive, .password]

    private func planner(
        key: Bool = true, encrypted: Bool = false, passphrase: String? = nil,
        password: String? = nil, keyboardInteractive: Bool = true, allowsPassword: Bool = true
    ) -> SSHSignInPlanner {
        SSHSignInPlanner(
            authentication: SSHAuthentication(
                keyID: key ? SSHKeyID() : nil,
                allowsKeyboardInteractive: keyboardInteractive,
                allowsPassword: allowsPassword),
            hasKey: key, keyIsEncrypted: encrypted,
            storedPassphrase: passphrase, storedPassword: password)
    }

    func testTheKeyComesFirstThenKeyboardInteractiveThenThePassword() {
        var p = planner(password: "pw")
        XCTAssertEqual(p.next(offered: all, rejected: []), .publicKey(passphrase: nil))
        XCTAssertEqual(p.next(offered: all, rejected: .publicKey), .keyboardInteractive)
        XCTAssertEqual(p.next(offered: all, rejected: .keyboardInteractive), .keyboardInteractive)
        XCTAssertEqual(p.next(offered: all, rejected: .keyboardInteractive), .keyboardInteractive)
        XCTAssertEqual(p.next(offered: all, rejected: .keyboardInteractive), .password("pw"))
    }

    /// The stored password is sent once. After the server refuses it the user
    /// types one, and the stored one is never sent again.
    func testARejectedStoredPasswordIsNotRetried() {
        var p = planner(key: false, password: "old", keyboardInteractive: false)
        XCTAssertEqual(p.next(offered: .password, rejected: []), .password("old"))
        XCTAssertEqual(p.next(offered: .password, rejected: .password), .askPassword(storedWasRejected: true))
        XCTAssertEqual(p.next(offered: .password, rejected: .password), .askPassword(storedWasRejected: false))
    }

    func testAnEncryptedKeyAsksForItsPassphraseAndRetriesAfterAWrongOne() {
        var p = planner(encrypted: true, keyboardInteractive: false, allowsPassword: false)
        XCTAssertEqual(p.next(offered: all, rejected: []), .askPassphrase(previousWasRejected: false))
        XCTAssertEqual(p.passphraseProvided("wrong"), .publicKey(passphrase: "wrong"))
        XCTAssertEqual(p.next(offered: all, rejected: .publicKey), .askPassphrase(previousWasRejected: true))
        XCTAssertEqual(p.passphraseProvided("right"), .publicKey(passphrase: "right"))
    }

    func testAStoredPassphraseIsTriedOnceThenAskedFor() {
        var p = planner(encrypted: true, passphrase: "stored")
        XCTAssertEqual(p.next(offered: all, rejected: []), .publicKey(passphrase: "stored"))
        XCTAssertEqual(p.next(offered: all, rejected: .publicKey), .askPassphrase(previousWasRejected: true))
    }

    func testThePassphraseIsAskedAFewTimesAtMost() {
        var p = planner(encrypted: true, keyboardInteractive: false, allowsPassword: false)
        _ = p.next(offered: all, rejected: [])
        for _ in 0..<SSHSignInPlanner.maximumPassphraseTries {
            _ = p.passphraseProvided("x")
            _ = p.next(offered: all, rejected: .publicKey)
        }
        XCTAssertEqual(p.next(offered: all, rejected: .publicKey), .giveUp)
    }

    func testSkippingThePassphraseMovesOn() {
        var p = planner(encrypted: true, password: "pw", keyboardInteractive: false)
        _ = p.next(offered: all, rejected: [])
        XCTAssertEqual(p.keySkipped(offered: all), .password("pw"))
    }

    func testOnlyWhatTheServerOffersAndTheProfileAllowsIsTried() {
        var p = planner(key: true, password: nil, keyboardInteractive: false)
        XCTAssertEqual(p.next(offered: .password, rejected: []), .askPassword(storedWasRejected: false))
        var q = planner(key: false, keyboardInteractive: false, allowsPassword: false)
        XCTAssertEqual(q.next(offered: all, rejected: []), .giveUp)
    }
}

final class TerminalKeyEncoderTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    func testArrowsFollowTheCursorMode() {
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .up)), "\u{1B}[A")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .up, applicationCursor: true)), "\u{1B}OA")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .left, modifiers: .control)), "\u{1B}[1;5D")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .right, modifiers: [.shift, .meta])), "\u{1B}[1;4C")
    }

    func testFunctionAndEditingKeys() {
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .function(1))), "\u{1B}OP")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .function(4))), "\u{1B}OS")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .function(5))), "\u{1B}[15~")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .function(6))), "\u{1B}[17~")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .function(10))), "\u{1B}[21~")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .function(11))), "\u{1B}[23~")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .function(12))), "\u{1B}[24~")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .delete)), "\u{1B}[3~")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .pageUp, modifiers: .shift)), "\u{1B}[5;2~")
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .tab, modifiers: .shift)), "\u{1B}[Z")
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .backspace), [0x7F])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .enter), [0x0D])
    }

    func testControlAndMeta() {
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .character("c"), modifiers: .control), [0x03])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .character("C"), modifiers: .control), [0x03])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .character("["), modifiers: .control), [0x1B])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .character(" "), modifiers: .control), [0x00])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .character("b"), modifiers: .meta), [0x1B, UInt8(ascii: "b")])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .character("x"), modifiers: [.control, .meta]), [0x1B, 0x18])
        XCTAssertEqual(text(TerminalKeyEncoder.bytes(for: .character("あ"))), "あ")
    }

    func testPasteIsBracketedAndCannotEndItselfEarly() {
        let bytes = TerminalKeyEncoder.paste("ls\n\u{1B}[201~rm -rf ~\n", bracketed: true)
        XCTAssertEqual(text(bytes), "\u{1B}[200~ls\rrm -rf ~\r\u{1B}[201~")
        XCTAssertEqual(text(TerminalKeyEncoder.paste("a\r\nb", bracketed: false)), "a\rb")
        // A marker split around another one is removed too.
        let nested = TerminalKeyEncoder.paste("\u{1B}[20\u{1B}[201~1~rm -rf ~\n", bracketed: true)
        XCTAssertEqual(text(nested), "\u{1B}[200~rm -rf ~\r\u{1B}[201~")
    }

    func testOnlyAnUnbracketedMultiLinePasteNeedsConfirmation() {
        XCTAssertTrue(TerminalKeyEncoder.pasteNeedsConfirmation("echo a\necho b", bracketed: false))
        XCTAssertFalse(TerminalKeyEncoder.pasteNeedsConfirmation("echo a\necho b", bracketed: true))
        XCTAssertFalse(TerminalKeyEncoder.pasteNeedsConfirmation("echo a", bracketed: false))
    }
}

final class SSHFailureTests: XCTestCase {
    func testEveryBridgeFailureHasAMeaning() {
        for failure in SSHBridgeFailure.allCases {
            XCTAssertEqual(failure.sessionError(detail: 0) == nil, failure == .none, "\(failure)")
        }
        XCTAssertEqual(SSHBridgeFailure.hostKeyRejected.sessionError(detail: 0), .hostKeyRejected)
        XCTAssertFalse(RemoteSessionError.hostKeyRejected.isRetriable)
        XCTAssertFalse(SSHBridgeFailure.authentication.sessionError(detail: 0)!.isRetriable)
    }

    func testTheFingerprintMatchesOpenSSH() {
        // ssh-keygen -lf on the public key below prints this fingerprint.
        let blob = Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")!
        XCTAssertEqual(HostKeyFingerprint.sha256(of: blob), "SHA256:" + HostKeyFingerprintTests.expected(blob))
        XCTAssertFalse(HostKeyFingerprint.sha256(of: blob).hasSuffix("="))
    }
}

/// Key files: generated here and checked with ssh-keygen, and ssh-keygen's
/// own files parsed here.
final class OpenSSHKeyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mr-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "ssh-keygen", code: Int(process.terminationStatus)) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAGeneratedKeyIsOneOpenSSHAccepts() throws {
        let key = OpenSSHKey.generateEd25519(comment: "mRemote@test")
        let path = directory.appendingPathComponent("generated").path
        try key.privateKeyFile.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        // ssh-keygen -y derives the public key from the private file: it only
        // succeeds if the file is well formed and the halves match.
        XCTAssertTrue(try run(["-y", "-f", path]).hasPrefix("ssh-ed25519 \(key.publicBlob.base64EncodedString())"))
        XCTAssertTrue(try run(["-l", "-f", path]).contains(key.fingerprint))
        XCTAssertEqual(key.publicKeyLine, "ssh-ed25519 \(key.publicBlob.base64EncodedString()) mRemote@test")
        XCTAssertFalse(key.isEncrypted)
    }

    func testKeysFromSSHKeygenAreRead() throws {
        for (type, bits, expected) in [("ed25519", nil, "ssh-ed25519"), ("rsa", "2048", "ssh-rsa"), ("ecdsa", "384", "ecdsa-sha2-nistp384")] {
            let path = directory.appendingPathComponent(type).path
            var arguments = ["-q", "-t", type, "-N", "", "-C", "c-\(type)", "-f", path]
            if let bits { arguments += ["-b", bits] }
            try run(arguments)
            let key = try OpenSSHKey(parsing: try Data(contentsOf: URL(fileURLWithPath: path)))
            XCTAssertEqual(key.keyType, expected)
            XCTAssertEqual(key.comment, "c-\(type)")
            let publicLine = try String(contentsOfFile: path + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(key.publicKeyLine, publicLine)
        }
    }

    func testAnEncryptedKeyIsReadWithoutItsPassphrase() throws {
        let path = directory.appendingPathComponent("encrypted").path
        try run(["-q", "-t", "ed25519", "-N", "secret phrase", "-f", path])
        let key = try OpenSSHKey(parsing: try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(key.isEncrypted)
        XCTAssertTrue(try String(contentsOfFile: path + ".pub", encoding: .utf8).hasPrefix(key.publicKeyLine))
    }

    func testALegacyPEMRSAKeyIsRead() throws {
        let path = directory.appendingPathComponent("pem").path
        try run(["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-f", path])
        let key = try OpenSSHKey(parsing: try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(key.keyType, "ssh-rsa")
        let publicLine = try String(contentsOfFile: path + ".pub", encoding: .utf8)
        XCTAssertTrue(publicLine.hasPrefix(key.publicKeyLine), "\(key.publicKeyLine) vs \(publicLine)")
    }

    func testAnEncryptedPEMKeyIsRefusedWithAWayOut() throws {
        let path = directory.appendingPathComponent("pem-encrypted").path
        try run(["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "secret phrase", "-f", path])
        XCTAssertThrowsError(try OpenSSHKey(parsing: try Data(contentsOf: URL(fileURLWithPath: path)))) {
            XCTAssertEqual($0 as? OpenSSHKey.ParseError, .legacyEncryptedPEM)
        }
    }

    func testSomethingElseIsRefused() {
        XCTAssertThrowsError(try OpenSSHKey(parsing: Data("ssh-ed25519 AAAA public only".utf8)))
        XCTAssertThrowsError(try OpenSSHKey(parsing: Data([0xFF, 0xFE])))
    }
}

enum HostKeyFingerprintTests {
    static func expected(_ blob: Data) -> String {
        // Independent of HostKeyFingerprint: shell out to the same math.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \"$0\" | base64 -d | shasum -a 256 | cut -d' ' -f1 | xxd -r -p | base64 | tr -d '='", blob.base64EncodedString()]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
