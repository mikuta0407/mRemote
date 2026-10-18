import Foundation
import SessionCore

public struct SchemaVersion: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let v1 = SchemaVersion(1)
    /// Adds `globalSettings.softwareKeyboardMode`.
    public static let v2 = SchemaVersion(2)
    /// Adds `globalSettings.terminal` and SSH profiles. A build that knows
    /// only v2 refuses a v3 store as from the future instead of failing to
    /// decode an SSH profile and calling the file malformed.
    public static let v3 = SchemaVersion(3)
    /// Adds the saved proxies and `ConnectionProfile.proxyID`. A v3 build
    /// would drop the proxies it does not know when it next saves, so it
    /// refuses the store instead.
    public static let v4 = SchemaVersion(4)
    /// The version this build writes.
    public static let current = v4
}

/// One step of the upgrade path. Steps are single-version so the chain can be
/// replayed in order from whatever version is on disk.
public protocol SchemaMigration: Sendable {
    var source: SchemaVersion { get }
    var destination: SchemaVersion { get }
    func migrate(_ document: JSONValue) throws -> JSONValue
}

public enum StoreError: Error, Hashable, Sendable {
    /// Written by a newer build. Refused rather than partially read, because
    /// downgrading a store by dropping fields it does not understand loses the
    /// user's settings silently.
    case documentFromFutureVersion(found: SchemaVersion, supported: SchemaVersion)
    case missingSchemaVersion
    case noMigrationPath(from: SchemaVersion, to: SchemaVersion)
    case migrationFailed(from: SchemaVersion, to: SchemaVersion, detail: String)
    case malformedDocument(detail: String)
}

/// Replays migrations until the document reaches the current version.
public struct SchemaMigrator: Sendable {
    private let migrations: [SchemaVersion: any SchemaMigration]
    private let target: SchemaVersion

    /// Every step this build knows, oldest first.
    public static let standardMigrations: [any SchemaMigration] = [
        AddSoftwareKeyboardModeMigration(),
        AddTerminalDefaultsMigration(),
        AddProxiesMigration(),
    ]

    public init(
        migrations: [any SchemaMigration] = SchemaMigrator.standardMigrations,
        target: SchemaVersion = .current
    ) {
        self.migrations = Dictionary(
            migrations.map { ($0.source, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.target = target
    }

    public func migrate(_ document: JSONValue) throws -> JSONValue {
        guard let rawVersion = document["schemaVersion"]?.intValue else {
            throw StoreError.missingSchemaVersion
        }
        let version = SchemaVersion(rawVersion)
        guard version <= target else {
            throw StoreError.documentFromFutureVersion(found: version, supported: target)
        }

        var current = version
        var working = document
        while current < target {
            guard let migration = migrations[current] else {
                throw StoreError.noMigrationPath(from: current, to: target)
            }
            do {
                working = try migration.migrate(working)
            } catch {
                throw StoreError.migrationFailed(
                    from: current,
                    to: migration.destination,
                    detail: String(describing: error)
                )
            }
            // Trust the step's declared destination rather than the document's
            // own field, so a migration that forgets to stamp the version
            // cannot spin here forever.
            guard migration.destination > current else {
                throw StoreError.noMigrationPath(from: current, to: target)
            }
            current = migration.destination
            working = working.settingSchemaVersion(current)
        }
        return working
    }
}

extension JSONValue {
    func settingSchemaVersion(_ version: SchemaVersion) -> JSONValue {
        guard var object = objectValue else { return self }
        object["schemaVersion"] = .number(Double(version.rawValue))
        return .object(object)
    }
}

/// v1 -> v2: the global default software keyboard mode. Written explicitly
/// rather than defaulted at decode time, so the document says what it means
/// and a later default change cannot silently reinterpret an old file.
public struct AddSoftwareKeyboardModeMigration: SchemaMigration {
    public let source = SchemaVersion.v1
    public let destination = SchemaVersion.v2

    public init() {}

    public func migrate(_ document: JSONValue) throws -> JSONValue {
        guard var object = document.objectValue,
              var settings = object["globalSettings"]?.objectValue else {
            throw StoreError.malformedDocument(detail: "globalSettings is missing")
        }
        if settings["softwareKeyboardMode"] == nil {
            settings["softwareKeyboardMode"] = .string(SoftwareKeyboardMode.localIME.rawValue)
        }
        object["globalSettings"] = .object(settings)
        return .object(object)
    }
}

/// v2 -> v3: the terminal defaults SSH profiles inherit, written out for the
/// same reason as v2's keyboard mode. The literal values are this
/// migration's, not `TerminalDefaults.default`'s, so changing a default later
/// does not change what an upgraded v2 store says.
public struct AddTerminalDefaultsMigration: SchemaMigration {
    public let source = SchemaVersion.v2
    public let destination = SchemaVersion.v3

    public init() {}

    public func migrate(_ document: JSONValue) throws -> JSONValue {
        guard var object = document.objectValue,
              var settings = object["globalSettings"]?.objectValue else {
            throw StoreError.malformedDocument(detail: "globalSettings is missing")
        }
        if settings["terminal"] == nil {
            settings["terminal"] = .object([
                "fontSize": .number(13),
                "theme": .string("system"),
                "optionAsMeta": .bool(true),
                "cursorStyle": .string("block"),
                "scrollbackLines": .number(10_000),
                "keepAliveSeconds": .number(30),
                "exitBehavior": .string("keepScreen"),
            ])
        }
        object["globalSettings"] = .object(settings)
        return .object(object)
    }
}

/// v3 -> v4: an empty list of saved proxies. Profiles gain an optional
/// `proxyID`, absent meaning a direct connection, so they need nothing.
public struct AddProxiesMigration: SchemaMigration {
    public let source = SchemaVersion.v3
    public let destination = SchemaVersion.v4

    public init() {}

    public func migrate(_ document: JSONValue) throws -> JSONValue {
        guard var object = document.objectValue else {
            throw StoreError.malformedDocument(detail: "the document is not an object")
        }
        if object["proxies"] == nil {
            object["proxies"] = .array([])
        }
        return .object(object)
    }
}
