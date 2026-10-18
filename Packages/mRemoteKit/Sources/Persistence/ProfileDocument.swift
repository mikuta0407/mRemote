import Foundation
import SessionCore

/// The whole persisted store: every profile plus the global settings that
/// `inherit` resolves against.
///
/// docs/data-and-security.md named SwiftData as the first candidate. This is a
/// versioned JSON document instead, because the store holds tens of records
/// rather than a queryable dataset, an explicit migration chain is far easier
/// to test than a SwiftData migration plan, and the whole thing can be tested
/// on the development host without a Simulator. The file still gets the same
/// data protection class, which was the actual security requirement.
public struct ProfileDocument: Hashable, Sendable, Codable {
    public var schemaVersion: SchemaVersion
    public var profiles: [ConnectionProfile]
    public var globalSettings: GlobalSettings
    /// Schema v4. The saved proxies profiles pick from.
    public var proxies: [ProxyServer]

    public init(
        schemaVersion: SchemaVersion = .current,
        profiles: [ConnectionProfile] = [],
        globalSettings: GlobalSettings = .default,
        proxies: [ProxyServer] = []
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.globalSettings = globalSettings
        self.proxies = proxies
    }
}

/// Encodes and decodes the document, running the migration chain on the way in.
public struct ProfileDocumentCodec: Sendable {
    private let migrator: SchemaMigrator

    public init(migrator: SchemaMigrator = SchemaMigrator()) {
        self.migrator = migrator
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Stable key order keeps a diff of the store readable and makes the
        // encoded bytes reproducible in tests.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encode(_ document: ProfileDocument) throws -> Data {
        var stamped = document
        stamped.schemaVersion = .current
        return try Self.makeEncoder().encode(stamped)
    }

    public func decode(_ data: Data) throws -> ProfileDocument {
        let decoder = Self.makeDecoder()
        let raw: JSONValue
        do {
            raw = try decoder.decode(JSONValue.self, from: data)
        } catch {
            throw StoreError.malformedDocument(detail: String(describing: error))
        }
        let migrated = try migrator.migrate(raw)
        do {
            return try decoder.decode(
                ProfileDocument.self,
                from: try Self.makeEncoder().encode(migrated)
            )
        } catch {
            throw StoreError.malformedDocument(detail: String(describing: error))
        }
    }
}
