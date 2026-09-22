import CryptoKit
import Foundation

public enum OTPAlgorithm: String, Codable, CaseIterable, Sendable, Identifiable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    public var id: String { rawValue }

    public init?(loose: String) {
        switch loose.uppercased().replacingOccurrences(of: "-", with: "") {
        case "SHA1": self = .sha1
        case "SHA256": self = .sha256
        case "SHA512": self = .sha512
        default: return nil
        }
    }
}

public enum OTPKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case totp
    case hotp

    public var id: String { rawValue }
}

/// HOTP (RFC 4226) and TOTP (RFC 6238) code generation.
public enum OTPGenerator {
    public static let allowedDigits: ClosedRange<Int> = 6...8
    public static let allowedPeriods: ClosedRange<Int> = 1...300

    public static func hotp(secret: Data, counter: UInt64, digits: Int = 6,
                            algorithm: OTPAlgorithm = .sha1) -> String {
        let digits = min(max(digits, allowedDigits.lowerBound), allowedDigits.upperBound)
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)

        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // Dynamic truncation (RFC 4226 §5.3).
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])

        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = binary % modulus
        let string = String(value)
        return String(repeating: "0", count: digits - string.count) + string
    }

    public static func totpCounter(at date: Date, period: Int) -> UInt64 {
        let period = max(period, 1)
        let seconds = max(date.timeIntervalSince1970, 0)
        return UInt64(floor(seconds / Double(period)))
    }

    public static func totp(secret: Data, at date: Date, period: Int = 30, digits: Int = 6,
                            algorithm: OTPAlgorithm = .sha1) -> String {
        hotp(secret: secret, counter: totpCounter(at: date, period: period),
             digits: digits, algorithm: algorithm)
    }

    /// Seconds left before the TOTP code rotates (fractional, for smooth progress bars).
    public static func secondsRemaining(at date: Date, period: Int) -> Double {
        let period = Double(max(period, 1))
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return period - elapsed
    }
}
