import XCTest
import SessionCore
@testable import Persistence

final class ProfileDocumentCodecTests: XCTestCase {
    /// One instance per test, with whole-second timestamps: the document is
    /// serialised as ISO 8601, which does not carry fractional seconds, so a
    /// sub-second `Date` would not survive the round trip.
    private let sample: ProfileDocument = {
        let timestamp = Date(timeIntervalSince1970: 1_760_000_000)
        let profile = ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            account: RemoteAccount(username: "user", domain: "CORP"),
            configuration: .rdp(RDPConfiguration(
                keyboardLayout: .explicit(.japanese),
                securityPolicy: .nlaRequired
            )),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let shell = ConnectionProfile(
            displayName: "build box",
            endpoint: RemoteEndpoint(host: "build.example", port: 22),
            account: RemoteAccount(username: "dev", credentialReference: CredentialReference()),
            configuration: .ssh(SSHConfiguration(
                authentication: SSHAuthentication(keyID: SSHKeyID(), allowsPassword: false),
                startupCommand: "tmux new -A -s main",
                fontSize: .explicit(15),
                portForwards: [SSHPortForward(localPort: 13389, remoteHost: "10.0.0.5", remotePort: 3389)]
            )),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return ProfileDocument(profiles: [profile, shell], globalSettings: .default)
    }()

    private func sampleDocument() -> ProfileDocument { sample }

    func testRoundTrip() throws {
        let codec = ProfileDocumentCodec()
        let decoded = try codec.decode(try codec.encode(sample))
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.schemaVersion, .current)
    }

    func testAVersionOneDocumentGainsTheSoftwareKeyboardDefault() throws {
        // A store written by the Phase 1 build: no softwareKeyboardMode key.
        let encoded = try ProfileDocumentCodec().encode(sample)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var settings = try XCTUnwrap(object["globalSettings"] as? [String: Any])
        settings.removeValue(forKey: "softwareKeyboardMode")
        object["globalSettings"] = settings
        object["schemaVersion"] = 1
        let v1 = try JSONSerialization.data(withJSONObject: object)

        let decoded = try ProfileDocumentCodec().decode(v1)
        XCTAssertEqual(decoded.schemaVersion, .current)
        XCTAssertEqual(decoded.globalSettings.softwareKeyboardMode, .localIME)
        XCTAssertEqual(decoded.profiles, sample.profiles)
    }

    func testAVersionTwoDocumentGainsTheTerminalDefaults() throws {
        // A store written before SSH: no terminal settings, no SSH profiles.
        var document = sample
        document.profiles.removeAll { $0.protocolKind == .ssh }
        let encoded = try ProfileDocumentCodec().encode(document)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var settings = try XCTUnwrap(object["globalSettings"] as? [String: Any])
        settings.removeValue(forKey: "terminal")
        object["globalSettings"] = settings
        object["schemaVersion"] = 2
        let v2 = try JSONSerialization.data(withJSONObject: object)

        let decoded = try ProfileDocumentCodec().decode(v2)
        XCTAssertEqual(decoded.schemaVersion, .v3)
        XCTAssertEqual(decoded.globalSettings.terminal, TerminalDefaults())
        XCTAssertEqual(decoded.profiles, document.profiles)
    }

    func testAnSSHProfileSurvivesTheRoundTrip() throws {
        let codec = ProfileDocumentCodec()
        let decoded = try codec.decode(try codec.encode(sample))
        let shell = try XCTUnwrap(decoded.profiles.first { $0.protocolKind == .ssh })
        let ssh = try XCTUnwrap(shell.configuration.ssh)
        XCTAssertEqual(ssh.authentication.allowsPassword, false)
        XCTAssertEqual(ssh.effectiveStartupCommand, "tmux new -A -s main")
        XCTAssertEqual(ssh.portForwards?.first?.remotePort, 3389)
        XCTAssertEqual(ssh.reconnectPolicy, .explicit(.disabled))
    }

    func testEncodingIsStable() throws {
        let codec = ProfileDocumentCodec()
        XCTAssertEqual(try codec.encode(sample), try codec.encode(sample))
    }

    func testNoPasswordIsEncodable() throws {
        // The model has nowhere to put a password, so this is a compile-time
        // guarantee; the test states it so a future field cannot quietly add
        // one to the document.
        let encoded = try ProfileDocumentCodec().encode(sampleDocument())
        let text = String(decoding: encoded, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("secret"))
    }

    func testFutureVersionIsRefused() throws {
        let future = #"{"schemaVersion":99,"profiles":[],"globalSettings":{}}"#
        XCTAssertThrowsError(try ProfileDocumentCodec().decode(Data(future.utf8))) { error in
            guard case StoreError.documentFromFutureVersion(let found, let supported) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(found, SchemaVersion(99))
            XCTAssertEqual(supported, .current)
        }
    }

    func testMissingSchemaVersionIsRefused() {
        let noVersion = #"{"profiles":[]}"#
        XCTAssertThrowsError(try ProfileDocumentCodec().decode(Data(noVersion.utf8))) { error in
            guard case StoreError.missingSchemaVersion = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMalformedDocumentIsRefused() {
        XCTAssertThrowsError(try ProfileDocumentCodec().decode(Data("not json".utf8))) { error in
            guard case StoreError.malformedDocument = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}

/// Exercises the migration chain itself. Only v1 exists today, so the chain is
/// driven with a synthetic step: the point is that the replay machinery works
/// before a real migration has to depend on it.
final class SchemaMigratorTests: XCTestCase {
    private struct RenameStep: SchemaMigration {
        let source = SchemaVersion(1)
        let destination = SchemaVersion(2)

        func migrate(_ document: JSONValue) throws -> JSONValue {
            guard var object = document.objectValue else {
                throw StoreError.malformedDocument(detail: "expected an object")
            }
            object["renamed"] = object.removeValue(forKey: "legacy") ?? .null
            return .object(object)
        }
    }

    private struct FailingStep: SchemaMigration {
        let source = SchemaVersion(1)
        let destination = SchemaVersion(2)

        func migrate(_ document: JSONValue) throws -> JSONValue {
            throw StoreError.malformedDocument(detail: "boom")
        }
    }

    /// A step that claims not to advance the version. Without the guard in the
    /// migrator this would loop forever.
    private struct StallingStep: SchemaMigration {
        let source = SchemaVersion(1)
        let destination = SchemaVersion(1)

        func migrate(_ document: JSONValue) throws -> JSONValue { document }
    }

    private func document(version: Int) -> JSONValue {
        .object([
            "schemaVersion": .number(Double(version)),
            "legacy": .string("value"),
        ])
    }

    func testChainReplaysAndStampsTheNewVersion() throws {
        let migrator = SchemaMigrator(migrations: [RenameStep()], target: SchemaVersion(2))
        let migrated = try migrator.migrate(document(version: 1))
        XCTAssertEqual(migrated["renamed"]?.stringValue, "value")
        XCTAssertNil(migrated["legacy"])
        XCTAssertEqual(migrated["schemaVersion"]?.intValue, 2)
    }

    func testDocumentAlreadyAtTargetIsUntouched() throws {
        let migrator = SchemaMigrator(migrations: [RenameStep()], target: SchemaVersion(1))
        let migrated = try migrator.migrate(document(version: 1))
        XCTAssertEqual(migrated["legacy"]?.stringValue, "value")
    }

    func testMissingStepIsReported() {
        let migrator = SchemaMigrator(migrations: [], target: SchemaVersion(2))
        XCTAssertThrowsError(try migrator.migrate(document(version: 1))) { error in
            guard case StoreError.noMigrationPath(let from, let to) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(from, SchemaVersion(1))
            XCTAssertEqual(to, SchemaVersion(2))
        }
    }

    func testFailingStepReportsWhereItFailed() {
        let migrator = SchemaMigrator(migrations: [FailingStep()], target: SchemaVersion(2))
        XCTAssertThrowsError(try migrator.migrate(document(version: 1))) { error in
            guard case StoreError.migrationFailed(let from, let to, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(from, SchemaVersion(1))
            XCTAssertEqual(to, SchemaVersion(2))
        }
    }

    func testStepThatDoesNotAdvanceIsRefusedRatherThanLooping() {
        let migrator = SchemaMigrator(migrations: [StallingStep()], target: SchemaVersion(2))
        XCTAssertThrowsError(try migrator.migrate(document(version: 1))) { error in
            guard case StoreError.noMigrationPath = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}
