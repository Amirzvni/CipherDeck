import Foundation

/// RFC 4648 Base32 — the encoding used for TOTP/HOTP shared secrets.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    private static let lookup: [UInt8: UInt8] = {
        var table: [UInt8: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            table[char] = UInt8(index)
            // lowercase
            if char >= 65 && char <= 90 { table[char + 32] = UInt8(index) }
        }
        return table
    }()

    /// Decodes Base32. Tolerates lowercase, spaces, dashes and missing/extra `=` padding
    /// (people paste secrets in every imaginable shape). Returns `nil` on invalid characters
    /// or an empty result.
    public static func decode(_ string: String) -> Data? {
        var out = Data()
        out.reserveCapacity(string.utf8.count * 5 / 8)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in string.utf8 {
            switch byte {
            case 32, 9, 10, 13, 45, 61: // space, tab, LF, CR, '-', '='
                continue
            default:
                guard let value = lookup[byte] else { return nil }
                buffer = (buffer << 5) | UInt32(value)
                bits += 5
                if bits >= 8 {
                    bits -= 8
                    out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
                }
                buffer &= (1 << UInt32(bits)) - 1
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Encodes to unpadded uppercase Base32 (the form used in `otpauth://` URIs).
    public static func encode(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
