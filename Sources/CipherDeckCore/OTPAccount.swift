import Foundation

/// One 2FA account. `secret` is the raw shared key (already Base32-decoded).
public struct OTPAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var issuer: String
    public var name: String
    public var secret: Data
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var kind: OTPKind
    /// TOTP step in seconds.
    public var period: Int
    /// HOTP moving counter (the value used for the *next* code).
    public var counter: UInt64
    public var pinned: Bool
    public var note: String
    public var createdAt: Date

    public init(id: UUID = UUID(), issuer: String, name: String, secret: Data,
                algorithm: OTPAlgorithm = .sha1, digits: Int = 6, kind: OTPKind = .totp,
                period: Int = 30, counter: UInt64 = 0, pinned: Bool = false, note: String = "",
                createdAt: Date = Date()) {
        self.id = id
        self.issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.kind = kind
        self.period = period
        self.counter = counter
        self.pinned = pinned
        self.note = note
        self.createdAt = createdAt
    }

    // Forward/backward compatible decoding: every field except the secret has a default,
    // so older or newer vault files always load (reliability pillar).
    enum CodingKeys: String, CodingKey {
        case id, issuer, name, secret, algorithm, digits, kind, period, counter, pinned, note, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        secret = try c.decode(Data.self, forKey: .secret)
        algorithm = (try? c.decodeIfPresent(OTPAlgorithm.self, forKey: .algorithm)) ?? .sha1
        digits = try c.decodeIfPresent(Int.self, forKey: .digits) ?? 6
        kind = (try? c.decodeIfPresent(OTPKind.self, forKey: .kind)) ?? .totp
        period = try c.decodeIfPresent(Int.self, forKey: .period) ?? 30
        counter = try c.decodeIfPresent(UInt64.self, forKey: .counter) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// The label shown in lists: issuer when present, else the account name.
    public var title: String {
        if !issuer.isEmpty { return issuer }
        return name.isEmpty ? "Unnamed" : name
    }

    public var subtitle: String { issuer.isEmpty ? "" : name }

    public var isValid: Bool {
        !secret.isEmpty
            && OTPGenerator.allowedDigits.contains(digits)
            && OTPGenerator.allowedPeriods.contains(period)
    }

    /// Current code. For HOTP this is the code for the current counter (it only changes
    /// when the user advances the counter).
    public func code(at date: Date = Date()) -> String {
        switch kind {
        case .totp:
            return OTPGenerator.totp(secret: secret, at: date, period: period,
                                     digits: digits, algorithm: algorithm)
        case .hotp:
            return OTPGenerator.hotp(secret: secret, counter: counter,
                                     digits: digits, algorithm: algorithm)
        }
    }

    /// The code that will appear after the current one rotates.
    public func nextCode(at date: Date = Date()) -> String {
        switch kind {
        case .totp:
            return OTPGenerator.totp(secret: secret, at: date.addingTimeInterval(Double(period)),
                                     period: period, digits: digits, algorithm: algorithm)
        case .hotp:
            return OTPGenerator.hotp(secret: secret, counter: counter &+ 1,
                                     digits: digits, algorithm: algorithm)
        }
    }

    /// Identity used for de-duplication on import: same secret + same kind + same label.
    public var dedupeKey: String {
        "\(kind.rawValue)|\(secret.base64EncodedString())|\(issuer.lowercased())|\(name.lowercased())"
    }

    /// Search matching against issuer, name and note.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return issuer.localizedCaseInsensitiveContains(q)
            || name.localizedCaseInsensitiveContains(q)
            || note.localizedCaseInsensitiveContains(q)
    }
}

extension String {
    /// "123456" → "123 456", "12345678" → "1234 5678", "1234567" → "123 4567".
    public var groupedCode: String {
        guard count >= 6 else { return self }
        let split = count / 2
        let head = prefix(split)
        let tail = suffix(count - split)
        return "\(head) \(tail)"
    }
}
