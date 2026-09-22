import CryptoKit
import Foundation

public enum VaultError: Error, LocalizedError, Equatable {
    case corrupted
    case cannotDecrypt
    case unsupportedVersion(Int)
    case writeVerificationFailed
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .corrupted: return "The vault file is damaged."
        case .cannotDecrypt: return "The vault could not be decrypted with the key in your Keychain."
        case .unsupportedVersion(let v): return "The vault was written by a newer CipherDeck (format \(v)). Please update."
        case .writeVerificationFailed: return "Saving failed verification; your previous vault was kept."
        case .io(let message): return "File error: \(message)"
        }
    }
}

/// The plaintext inside the encrypted vault. Never written to disk as-is.
public struct VaultPayload: Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var accounts: [OTPAccount]

    public init(accounts: [OTPAccount]) {
        self.version = Self.currentVersion
        self.accounts = accounts
    }
}

/// On-disk envelope: `{"format":"cipherdeck-vault","version":1,"sealed":"<AES-GCM combined>"}`.
struct VaultEnvelope: Codable {
    static let formatName = "cipherdeck-vault"
    static let currentVersion = 1
    var format: String
    var version: Int
    var sealed: Data
}

/// Symmetric AES-256-GCM helpers (CryptoKit).
public enum VaultCrypto {
    static let vaultAAD = Data("cipherdeck-vault-v1".utf8)

    public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined else { throw VaultError.corrupted }
        return combined
    }

    public static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }
}

/// The encrypted vault on disk, with atomic writes and a rolling `.bak` of the last good
/// version (reliability pillar).
public struct VaultFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var backupURL: URL { url.appendingPathExtension("bak") }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: backupURL.path)
    }

    public struct LoadResult: Sendable {
        public var accounts: [OTPAccount]
        /// True when the main file was unreadable and the `.bak` copy was used.
        public var recoveredFromBackup: Bool
    }

    public func load(key: SymmetricKey) throws -> LoadResult {
        do {
            return LoadResult(accounts: try Self.read(url, key: key), recoveredFromBackup: false)
        } catch let primaryError {
            if case VaultError.unsupportedVersion = primaryError { throw primaryError }
            guard FileManager.default.fileExists(atPath: backupURL.path),
                  let accounts = try? Self.read(backupURL, key: key)
            else { throw primaryError }
            return LoadResult(accounts: accounts, recoveredFromBackup: true)
        }
    }

    public func save(_ accounts: [OTPAccount], key: SymmetricKey) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw VaultError.io(error.localizedDescription)
        }

        let data = try Self.encode(accounts, key: key)

        // Keep the current file as .bak — but only if it is actually readable, so a
        // damaged main file never overwrites a good backup.
        if fm.fileExists(atPath: url.path), (try? Self.read(url, key: key)) != nil {
            let tmpBak = dir.appendingPathComponent(".\(backupURL.lastPathComponent).tmp")
            try? fm.removeItem(at: tmpBak)
            do {
                try fm.copyItem(at: url, to: tmpBak)
                _ = try fm.replaceItemAt(backupURL, withItemAt: tmpBak)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            } catch {
                try? fm.removeItem(at: tmpBak)
            }
        }

        do {
            try data.write(to: url, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw VaultError.io(error.localizedDescription)
        }

        // Verify what landed on disk round-trips.
        guard let readBack = try? Self.read(url, key: key),
              readBack.map(\.id) == accounts.map(\.id),
              readBack.map(\.dedupeKey) == accounts.map(\.dedupeKey)
        else {
            throw VaultError.writeVerificationFailed
        }
    }

    static func encode(_ accounts: [OTPAccount], key: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(VaultPayload(accounts: accounts))
        let sealed = try VaultCrypto.seal(plaintext, key: key, aad: VaultCrypto.vaultAAD)
        let envelope = VaultEnvelope(format: VaultEnvelope.formatName,
                                     version: VaultEnvelope.currentVersion, sealed: sealed)
        return try JSONEncoder().encode(envelope)
    }

    static func read(_ url: URL, key: SymmetricKey) throws -> [OTPAccount] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw VaultError.io(error.localizedDescription) }
        guard let envelope = try? JSONDecoder().decode(VaultEnvelope.self, from: data),
              envelope.format == VaultEnvelope.formatName
        else { throw VaultError.corrupted }
        guard envelope.version <= VaultEnvelope.currentVersion else {
            throw VaultError.unsupportedVersion(envelope.version)
        }
        let plaintext: Data
        do {
            plaintext = try VaultCrypto.open(envelope.sealed, key: key, aad: VaultCrypto.vaultAAD)
        } catch {
            throw VaultError.cannotDecrypt
        }
        guard let payload = try? JSONDecoder().decode(VaultPayload.self, from: plaintext) else {
            throw VaultError.corrupted
        }
        guard payload.version <= VaultPayload.currentVersion else {
            throw VaultError.unsupportedVersion(payload.version)
        }
        return payload.accounts
    }
}
