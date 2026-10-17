import Foundation
import CryptoKit
import Security

/// A private key file, read far enough to list it: its type, public key and
/// fingerprint. The private part is never decoded here - libssh2 does that
/// at sign-in - so an encrypted key is accepted without its passphrase.
public struct OpenSSHKey: Hashable, Sendable {
    public enum ParseError: Error, Hashable, Sendable {
        /// Not a private key file this app can use.
        case unrecognised
        /// A PEM key encrypted the legacy way; OpenSSH can rewrite it
        /// (`ssh-keygen -p -f <file>`) in its own format, which works.
        case legacyEncryptedPEM
        case unsupportedKeyType(String)
        case malformed
    }

    /// "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"...
    public let keyType: String
    /// The SSH public key blob.
    public let publicBlob: Data
    public let comment: String
    public let isEncrypted: Bool
    /// The file as given, which is what libssh2 is handed.
    public let privateKeyFile: Data

    public var fingerprint: String { HostKeyFingerprint.sha256(of: publicBlob) }

    /// The authorized_keys line.
    public var publicKeyLine: String {
        let base = "\(keyType) \(publicBlob.base64EncodedString())"
        return comment.isEmpty ? base : "\(base) \(comment)"
    }

    static let supportedTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]

    public init(parsing file: Data) throws {
        guard let text = String(data: file, encoding: .utf8) else { throw ParseError.unrecognised }
        if let body = Self.pemBody(text, label: "OPENSSH PRIVATE KEY") {
            try self.init(openSSH: body, file: file)
        } else if let body = Self.pemBody(text, label: "RSA PRIVATE KEY") {
            if text.contains("Proc-Type: 4,ENCRYPTED") { throw ParseError.legacyEncryptedPEM }
            try self.init(pkcs1RSA: body, file: file)
        } else if text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----") {
            throw text.contains("ENCRYPTED") ? ParseError.legacyEncryptedPEM : ParseError.unrecognised
        } else {
            throw ParseError.unrecognised
        }
    }

    private init(openSSH body: Data, file: Data) throws {
        var reader = SSHReader(body)
        guard reader.readMagic("openssh-key-v1\0") else { throw ParseError.malformed }
        guard let cipher = reader.readString(), reader.readString() != nil /* kdf */,
              reader.readString() != nil /* kdf options */, let count = reader.readUInt32(), count == 1,
              let blob = reader.readString(), let encryptedSection = reader.readString() else {
            throw ParseError.malformed
        }
        var blobReader = SSHReader(blob)
        guard let typeData = blobReader.readString(), let type = String(data: typeData, encoding: .utf8) else {
            throw ParseError.malformed
        }
        guard Self.supportedTypes.contains(type) else { throw ParseError.unsupportedKeyType(type) }
        let encrypted = String(data: cipher, encoding: .utf8) != "none"
        var comment = ""
        if !encrypted {
            // checkint ×2, type, the key's own fields, comment.
            var section = SSHReader(encryptedSection)
            guard let a = section.readUInt32(), let b = section.readUInt32(), a == b else { throw ParseError.malformed }
            _ = section.readString()
            let fields = type == "ssh-rsa" ? 6 : (type == "ssh-ed25519" ? 2 : 3)
            for _ in 0..<fields { guard section.readString() != nil else { throw ParseError.malformed } }
            comment = section.readString().flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        self.keyType = type
        self.publicBlob = blob
        self.comment = comment
        self.isEncrypted = encrypted
        self.privateKeyFile = file
    }

    /// The traditional `ssh-keygen -m PEM` RSA file. Its public half is
    /// derived through the Security framework.
    private init(pkcs1RSA der: Data, file: Data) throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let (modulus, exponent) = DER.rsaPublicKey(publicDER) else {
            throw ParseError.malformed
        }
        var blob = SSHWriter()
        blob.writeString("ssh-rsa")
        blob.writeMPInt(exponent)
        blob.writeMPInt(modulus)
        self.keyType = "ssh-rsa"
        self.publicBlob = blob.data
        self.comment = ""
        self.isEncrypted = false
        self.privateKeyFile = file
    }

    /// A new Ed25519 key in OpenSSH's own format, unencrypted (it is kept in
    /// the Keychain, which already protects it).
    public static func generateEd25519(comment: String) -> OpenSSHKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let seed = privateKey.rawRepresentation
        let publicKey = privateKey.publicKey.rawRepresentation

        var blob = SSHWriter()
        blob.writeString("ssh-ed25519")
        blob.writeString(publicKey)

        var section = SSHWriter()
        let check = UInt32.random(in: .min ... .max)
        section.writeUInt32(check)
        section.writeUInt32(check)
        section.writeString("ssh-ed25519")
        section.writeString(publicKey)
        section.writeString(seed + publicKey)
        section.writeString(comment)
        var pad: UInt8 = 1
        while section.data.count % 8 != 0 {
            section.data.append(pad)
            pad += 1
        }

        var body = SSHWriter()
        body.data.append(contentsOf: Array("openssh-key-v1\0".utf8))
        body.writeString("none")
        body.writeString("none")
        body.writeString(Data())
        body.writeUInt32(1)
        body.writeString(blob.data)
        body.writeString(section.data)

        let base64 = body.data.base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        let file = Data((lines.joined(separator: "\n") + "\n").utf8)
        // Built from known parts, so it parses.
        return try! OpenSSHKey(parsing: file)
    }

    static func pemBody(_ text: String, label: String) -> Data? {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let inner = text[start.upperBound..<stop.lowerBound]
            .split(whereSeparator: \.isNewline)
            .filter { !$0.contains(":") }   // PEM headers
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: inner)
    }
}

// MARK: - SSH wire encoding

struct SSHReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    mutating func readMagic(_ magic: String) -> Bool {
        let bytes = Array(magic.utf8)
        guard data.count - offset >= bytes.count, Array(data[offset..<offset + bytes.count]) == bytes else { return false }
        offset += bytes.count
        return true
    }

    mutating func readUInt32() -> UInt32? {
        guard data.count - offset >= 4 else { return nil }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readString() -> Data? {
        guard let length = readUInt32(), Int(length) <= data.count - offset else { return nil }
        let value = data[offset..<offset + Int(length)]
        offset += Int(length)
        return Data(value)
    }
}

struct SSHWriter {
    var data = Data()

    mutating func writeUInt32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func writeString(_ value: Data) {
        writeUInt32(UInt32(value.count))
        data.append(value)
    }

    mutating func writeString(_ value: String) { writeString(Data(value.utf8)) }

    /// An unsigned big-endian integer as an SSH mpint: no leading zeros, and
    /// one zero byte in front when the top bit is set.
    mutating func writeMPInt(_ magnitude: Data) {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        writeString(Data(bytes))
    }
}

/// Just enough DER to read a PKCS#1 RSAPublicKey: SEQUENCE { n, e }.
enum DER {
    static func rsaPublicKey(_ der: Data) -> (modulus: Data, exponent: Data)? {
        var bytes = ArraySlice(Array(der))
        guard let sequence = element(&bytes, tag: 0x30) else { return nil }
        var inner = sequence
        guard let modulus = element(&inner, tag: 0x02), let exponent = element(&inner, tag: 0x02) else { return nil }
        return (Data(modulus), Data(exponent))
    }

    private static func element(_ bytes: inout ArraySlice<UInt8>, tag: UInt8) -> ArraySlice<UInt8>? {
        guard bytes.count >= 2, bytes.first == tag else { return nil }
        bytes = bytes.dropFirst()
        var length = Int(bytes.removeFirst())
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, bytes.count >= count else { return nil }
            length = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
            bytes = bytes.dropFirst(count)
        }
        guard bytes.count >= length else { return nil }
        let value = bytes.prefix(length)
        bytes = bytes.dropFirst(length)
        return value
    }
}
