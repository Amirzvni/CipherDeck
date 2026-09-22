import CommonCrypto
import CryptoKit
import Foundation

public enum BackupError: Error, LocalizedError, Equatable {
    case notABackup
    case unsupportedVersion(Int)
    case wrongPassword
    case weakPassword
    case keyDerivationFailed

    public var errorDescription: String? {
        switch self {
        case .notABackup: return "This file is not a CipherDeck backup."
        case .unsupportedVersion(let v): return "Backup format \(v) needs a newer CipherDeck."
        case .wrongPassword: return "Wrong password, or the backup file is damaged."
        case .weakPassword: return "Use a password of at least 8 characters."
        case .keyDerivationFailed: return "Could not derive the encryption key."
        }
    }
}

/// Portable, password-encrypted backup (`.cipherdeck` file):
/// PBKDF2-HMAC-SHA256 (600k iterations, 16-byte salt) → AES-256-GCM.
/// The header is authenticated as AAD, so tampering with KDF parameters fails decryption.
public enum EncryptedBackup {
    public static let formatName = "cipherdeck-backup"
    public static let currentVersion = 1
    public static let defaultIterations = 600_000
    public static let minimumPasswordLength = 8
    public static let fileExtension = "cipherdeck"

    struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: Data
        var cipher: String
        var sealed: Data
        var createdAt: Date
        var accountCount: Int
    }

    public static func export(_ accounts: [OTPAccount], password: String,
                              iterations: Int = defaultIterations, now: Date = Date()) throws -> Data {
        guard password.count >= minimumPasswordLength else { throw BackupError.weakPassword }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupError.keyDerivationFailed }

        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(VaultPayload(accounts: accounts))

        var envelope = Envelope(format: formatName, version: currentVersion, kdf: "PBKDF2-HMAC-SHA256",
                                iterations: iterations, salt: salt, cipher: "AES-256-GCM",
                                sealed: Data(), createdAt: now, accountCount: accounts.count)
        envelope.sealed = try VaultCrypto.seal(plaintext, key: key, aad: aad(for: envelope))
        let out = JSONEncoder()
        out.dateEncodingStrategy = .iso8601
        out.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try out.encode(envelope)
    }

    public static func isBackup(_ data: Data) -> Bool {
        (try? decodeEnvelope(data)) != nil
    }

    public static func `import`(_ data: Data, password: String) throws -> [OTPAccount] {
        let envelope = try decodeEnvelope(data)
        guard envelope.version <= currentVersion else { throw BackupError.unsupportedVersion(envelope.version) }
        guard envelope.kdf == "PBKDF2-HMAC-SHA256", envelope.cipher == "AES-256-GCM",
              (10_000...10_000_000).contains(envelope.iterations), envelope.salt.count >= 16
        else { throw BackupError.notABackup }

        let key = try deriveKey(password: password, salt: envelope.salt, iterations: envelope.iterations)
        let plaintext: Data
        do {
            plaintext = try VaultCrypto.open(envelope.sealed, key: key, aad: aad(for: envelope))
        } catch {
            throw BackupError.wrongPassword
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(VaultPayload.self, from: plaintext) else {
            throw BackupError.wrongPassword
        }
        return payload.accounts
    }

    private static func decodeEnvelope(_ data: Data) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.format == formatName
        else { throw BackupError.notABackup }
        return envelope
    }

    private static func aad(for e: Envelope) -> Data {
        Data("\(e.format)|\(e.version)|\(e.kdf)|\(e.iterations)|\(e.salt.base64EncodedString())|\(e.cipher)".utf8)
    }

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPtr in
            passwordBytes.withUnsafeBufferPointer { pwPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    passwordBytes.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw BackupError.keyDerivationFailed }
        defer { for i in derived.indices { derived[i] = 0 } }
        return SymmetricKey(data: derived)
    }
}
