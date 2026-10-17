import XCTest
import SessionCore
@testable import AppleAdapters

/// The data-protection keychain needs a signed host app, so these cover the
/// shared decision logic and the in-memory implementations; its queries are
/// exercised on device. The login keychain is covered below.
final class TrustRepositoryTests: XCTestCase {
    private func record(host: String = "desk.example", fingerprint: String) -> TrustRecord {
        TrustRecord(
            host: host,
            port: 3389,
            leafSHA256: fingerprint,
            subject: "CN=desk",
            issuer: "CN=desk",
            notBefore: Date(timeIntervalSince1970: 0),
            notAfter: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }

    func testUnknownEndpointHasNoRecord() throws {
        let repository = InMemoryTrustRepository()
        let decision = try repository.decision(host: "desk.example", port: 3389, leafSHA256: "aa")
        XCTAssertEqual(decision, .noRecord)
    }

    func testMatchingFingerprintIsAccepted() throws {
        let repository = InMemoryTrustRepository()
        let stored = record(fingerprint: "aa")
        try repository.store(stored)
        let decision = try repository.decision(host: "desk.example", port: 3389, leafSHA256: "aa")
        XCTAssertEqual(decision, .matches(stored))
    }

    func testChangedFingerprintIsFlaggedRatherThanReplaced() throws {
        let repository = InMemoryTrustRepository()
        try repository.store(record(fingerprint: "aa"))
        let decision = try repository.decision(host: "desk.example", port: 3389, leafSHA256: "bb")
        guard case .fingerprintChanged(let previous) = decision else {
            return XCTFail("expected a changed-fingerprint decision")
        }
        XCTAssertEqual(previous.leafSHA256, "aa")
    }

    func testApprovalDoesNotCarryToAnotherEndpoint() throws {
        let repository = InMemoryTrustRepository()
        try repository.store(record(fingerprint: "aa"))
        let otherHost = try repository.decision(host: "other.example", port: 3389, leafSHA256: "aa")
        let otherPort = try repository.decision(host: "desk.example", port: 3390, leafSHA256: "aa")
        XCTAssertEqual(otherHost, .noRecord)
        XCTAssertEqual(otherPort, .noRecord)
    }

    func testRemoveDropsTheApproval() throws {
        let repository = InMemoryTrustRepository()
        try repository.store(record(fingerprint: "aa"))
        try repository.remove(host: "desk.example", port: 3389)
        XCTAssertEqual(try repository.allRecords().count, 0)
    }
}

final class CredentialRepositoryTests: XCTestCase {
    func testStoreReadAndDelete() throws {
        let repository = InMemoryCredentialRepository()
        let reference = CredentialReference()
        XCTAssertNil(try repository.password(for: reference))

        try repository.store(password: "secret", for: reference)
        XCTAssertEqual(try repository.password(for: reference), "secret")

        try repository.store(password: "rotated", for: reference)
        XCTAssertEqual(try repository.password(for: reference), "rotated")

        try repository.delete(reference)
        XCTAssertNil(try repository.password(for: reference))
    }
}

final class RedactionTests: XCTestCase {
    func testEndpointHidesTheHostButKeepsThePort() {
        let redacted = Redaction.endpoint(host: "desk.corp.example", port: 3389)
        XCTAssertFalse(redacted.contains("desk"))
        XCTAssertFalse(redacted.contains("corp"))
        XCTAssertTrue(redacted.hasSuffix(":3389"))
    }

    func testSameHostRedactsToTheSameToken() {
        XCTAssertEqual(
            Redaction.endpoint(host: "desk.example", port: 3389),
            Redaction.endpoint(host: "desk.example", port: 3389)
        )
        XCTAssertNotEqual(
            Redaction.endpoint(host: "desk.example", port: 3389),
            Redaction.endpoint(host: "other.example", port: 3389)
        )
    }

    func testTextPayloadReportsOnlyLength() {
        let redacted = Redaction.textPayload("パスワード")
        XCTAssertEqual(redacted, "text(chars=5)")
    }

    func testUsernameIsRedacted() {
        XCTAssertEqual(Redaction.username(nil), "user#none")
        XCTAssertFalse(Redaction.username("mikuta").contains("mikuta"))
    }
}

/// The login keychain, as the ad-hoc signed Mac app uses it. The test runner
/// has no application identifier either, so it can only write there.
final class LoginKeychainTests: XCTestCase {
    func testWithoutAnApplicationIdentifierTheLoginKeychainIsUsed() {
        XCTAssertEqual(KeychainStore.detect(), .login)
    }

    func testCredentialsRoundTripInTheLoginKeychain() throws {
        let repository = KeychainCredentialRepository(
            service: "com.mikuta0407.mRemote.tests.\(UUID().uuidString)",
            store: .login
        )
        let reference = CredentialReference()
        defer { try? repository.delete(reference) }

        try repository.store(password: "secret", for: reference)
        XCTAssertEqual(try repository.password(for: reference), "secret")
        try repository.store(password: "rotated", for: reference)
        XCTAssertEqual(try repository.password(for: reference), "rotated")
        try repository.delete(reference)
        XCTAssertNil(try repository.password(for: reference))
    }

    func testTrustRoundTripsInTheLoginKeychain() throws {
        let repository = KeychainTrustRepository(
            service: "com.mikuta0407.mRemote.tests.\(UUID().uuidString)",
            store: .login
        )
        defer { try? repository.remove(host: "desk.example", port: 3389) }

        try repository.store(TrustRecord(
            host: "desk.example",
            port: 3389,
            leafSHA256: "aa",
            subject: "CN=desk",
            issuer: "CN=desk",
            notBefore: Date(timeIntervalSince1970: 0),
            notAfter: Date(timeIntervalSince1970: 4_000_000_000)
        ))
        guard case .matches(let stored) = try repository.decision(
            host: "desk.example", port: 3389, leafSHA256: "aa"
        ) else {
            return XCTFail("the stored approval was not found")
        }
        XCTAssertEqual(stored.leafSHA256, "aa")
        XCTAssertEqual(try repository.allRecords().count, 1)
        try repository.remove(host: "desk.example", port: 3389)
        XCTAssertEqual(try repository.allRecords().count, 0)
    }

    func testKnownHostsRoundTripInTheLoginKeychain() throws {
        let repository = KeychainKnownHostRepository(
            service: "com.mikuta0407.mRemote.tests.\(UUID().uuidString)",
            store: .login
        )
        defer { try? repository.remove(host: "shell.example", port: 22) }

        XCTAssertEqual(try repository.decision(host: "shell.example", port: 22, fingerprint: "SHA256:a"), .unknown)
        try repository.store(KnownHost(host: "Shell.Example", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:a"))
        guard case .matches = try repository.decision(host: "shell.example", port: 22, fingerprint: "SHA256:a") else {
            return XCTFail("the trusted key was not found")
        }
        guard case .changed(let previous) = try repository.decision(host: "shell.example", port: 22, fingerprint: "SHA256:b") else {
            return XCTFail("a different key was not flagged")
        }
        XCTAssertEqual(previous.fingerprint, "SHA256:a")
        XCTAssertEqual(try repository.decision(host: "shell.example", port: 2222, fingerprint: "SHA256:a"), .unknown)
        XCTAssertEqual(try repository.allHosts().count, 1)
        try repository.remove(host: "shell.example", port: 22)
        XCTAssertEqual(try repository.allHosts().count, 0)
    }

    func testSSHKeysRoundTripInTheLoginKeychain() throws {
        let repository = KeychainSSHKeyRepository(
            service: "com.mikuta0407.mRemote.tests.\(UUID().uuidString)",
            store: .login
        )
        let metadata = SSHKeyMetadata(
            name: "laptop", keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAA test",
            fingerprint: "SHA256:x", isEncrypted: true)
        defer { try? repository.delete(metadata.id) }

        try repository.store(metadata, privateKey: Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8))
        try repository.storePassphrase("pass phrase", for: metadata.id)
        XCTAssertEqual(try repository.allKeys().map(\.id), [metadata.id])
        XCTAssertEqual(try repository.privateKey(for: metadata.id), Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8))
        XCTAssertEqual(try repository.passphrase(for: metadata.id), "pass phrase")
        try repository.rename(metadata.id, to: "work")
        XCTAssertEqual(try repository.metadata(for: metadata.id)?.name, "work")
        try repository.storePassphrase(nil, for: metadata.id)
        XCTAssertNil(try repository.passphrase(for: metadata.id))
        try repository.delete(metadata.id)
        XCTAssertEqual(try repository.allKeys().count, 0)
        XCTAssertNil(try repository.privateKey(for: metadata.id))
    }
}
