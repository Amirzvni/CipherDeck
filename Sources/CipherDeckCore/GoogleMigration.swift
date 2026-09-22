import Foundation

/// Google Authenticator "Transfer accounts" QR codes:
/// `otpauth-migration://offline?data=<base64 protobuf>`
///
/// ```proto
/// message MigrationPayload {
///   message OtpParameters {
///     bytes secret = 1; string name = 2; string issuer = 3;
///     Algorithm algorithm = 4;   // 0 unspecified, 1 SHA1, 2 SHA256, 3 SHA512, 4 MD5
///     DigitCount digits = 5;     // 0 unspecified, 1 SIX, 2 EIGHT
///     OtpType type = 6;          // 0 unspecified, 1 HOTP, 2 TOTP
///     int64 counter = 7;
///   }
///   repeated OtpParameters otp_parameters = 1;
///   int32 version = 2; int32 batch_size = 3; int32 batch_index = 4; int32 batch_id = 5;
/// }
/// ```
/// Large exports are split across several QR codes (batches) sharing one `batch_id`.
public enum GoogleMigration {
    public struct Batch: Sendable {
        public var accounts: [OTPAccount]
        public var version: Int
        public var batchSize: Int
        public var batchIndex: Int
        public var batchID: Int
        /// Entries we couldn't import (e.g. MD5, empty secret).
        public var skipped: Int
    }

    public static let scheme = "otpauth-migration://"

    public static func isMigrationURI(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(scheme)
    }

    // MARK: Decode

    public static func decode(uri: String) throws -> Batch {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMigrationURI(trimmed),
              let components = URLComponents(string: trimmed),
              let raw = components.queryItems?.first(where: { $0.name == "data" })?.value,
              let data = base64Decode(raw)
        else { throw OTPImportError.invalidMigrationPayload }
        return try decode(payload: data)
    }

    public static func decode(payload: Data) throws -> Batch {
        var reader = ProtoReader(Array(payload))
        var batch = Batch(accounts: [], version: 0, batchSize: 1, batchIndex: 0, batchID: 0, skipped: 0)
        while let (field, wire) = try reader.nextTag() {
            switch (field, wire) {
            case (1, .lengthDelimited):
                let bytes = try reader.readLengthDelimited()
                if let account = try decodeParameters(bytes) {
                    batch.accounts.append(account)
                } else {
                    batch.skipped += 1
                }
            case (2, .varint): batch.version = Int(truncatingIfNeeded: try reader.readVarint())
            case (3, .varint): batch.batchSize = Int(truncatingIfNeeded: try reader.readVarint())
            case (4, .varint): batch.batchIndex = Int(truncatingIfNeeded: try reader.readVarint())
            case (5, .varint): batch.batchID = Int(Int32(truncatingIfNeeded: try reader.readVarint()))
            default: try reader.skip(wire)
            }
        }
        if batch.accounts.isEmpty && batch.skipped == 0 { throw OTPImportError.noAccountsFound }
        return batch
    }

    private static func decodeParameters(_ bytes: [UInt8]) throws -> OTPAccount? {
        var reader = ProtoReader(bytes)
        var secret = Data()
        var name = ""
        var issuer = ""
        var algorithmCode: UInt64 = 0
        var digitsCode: UInt64 = 0
        var typeCode: UInt64 = 0
        var counter: UInt64 = 0

        while let (field, wire) = try reader.nextTag() {
            switch (field, wire) {
            case (1, .lengthDelimited): secret = Data(try reader.readLengthDelimited())
            case (2, .lengthDelimited): name = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (3, .lengthDelimited): issuer = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (4, .varint): algorithmCode = try reader.readVarint()
            case (5, .varint): digitsCode = try reader.readVarint()
            case (6, .varint): typeCode = try reader.readVarint()
            case (7, .varint): counter = try reader.readVarint()
            default: try reader.skip(wire)
            }
        }

        guard !secret.isEmpty else { return nil }

        let algorithm: OTPAlgorithm
        switch algorithmCode {
        case 0, 1: algorithm = .sha1
        case 2: algorithm = .sha256
        case 3: algorithm = .sha512
        default: return nil // MD5 or unknown: not supported
        }
        let digits: Int
        switch digitsCode {
        case 0, 1: digits = 6
        case 2: digits = 8
        default: return nil
        }
        let kind: OTPKind
        switch typeCode {
        case 0, 2: kind = .totp
        case 1: kind = .hotp
        default: return nil
        }

        // Google stores the full label ("Issuer:account") in `name`.
        var accountName = name
        if let colon = name.firstIndex(of: ":") {
            let prefix = String(name[..<colon])
            if issuer.isEmpty || prefix.caseInsensitiveCompare(issuer) == .orderedSame {
                if issuer.isEmpty { issuer = prefix }
                accountName = String(name[name.index(after: colon)...])
            }
        }

        return OTPAccount(issuer: issuer, name: accountName, secret: secret, algorithm: algorithm,
                          digits: digits, kind: kind, period: 30, counter: counter)
    }

    // MARK: Encode (export to Google Authenticator)

    /// Accounts Google Authenticator can't represent (non-30s periods, 7 digits) are
    /// returned in `unsupported` and left out of the QR codes.
    public static func encode(_ accounts: [OTPAccount], perBatch: Int = 8,
                              batchID: Int32 = Int32.random(in: 1...Int32.max))
        -> (uris: [String], unsupported: [OTPAccount]) {
        let supported = accounts.filter(isExportable)
        let unsupported = accounts.filter { !isExportable($0) }
        let chunks = stride(from: 0, to: supported.count, by: max(perBatch, 1)).map {
            Array(supported[$0..<min($0 + perBatch, supported.count)])
        }
        let uris = chunks.enumerated().map { index, chunk -> String in
            var writer = ProtoWriter()
            for account in chunk {
                writer.writeMessage(field: 1, encodeParameters(account))
            }
            writer.writeVarint(field: 2, 1)
            writer.writeVarint(field: 3, UInt64(chunks.count))
            writer.writeVarint(field: 4, UInt64(index))
            writer.writeVarint(field: 5, UInt64(UInt32(bitPattern: batchID)))
            let base64 = Data(writer.bytes).base64EncodedString()
            let allowed = CharacterSet.alphanumerics
            let escaped = base64.addingPercentEncoding(withAllowedCharacters: allowed) ?? base64
            return "otpauth-migration://offline?data=\(escaped)"
        }
        return (uris, unsupported)
    }

    public static func isExportable(_ account: OTPAccount) -> Bool {
        (account.digits == 6 || account.digits == 8) && (account.kind == .hotp || account.period == 30)
    }

    private static func encodeParameters(_ account: OTPAccount) -> [UInt8] {
        var writer = ProtoWriter()
        writer.writeBytes(field: 1, Array(account.secret))
        let label = account.issuer.isEmpty ? account.name : "\(account.issuer):\(account.name)"
        writer.writeBytes(field: 2, Array(label.utf8))
        writer.writeBytes(field: 3, Array(account.issuer.utf8))
        let algorithm: UInt64
        switch account.algorithm {
        case .sha1: algorithm = 1
        case .sha256: algorithm = 2
        case .sha512: algorithm = 3
        }
        writer.writeVarint(field: 4, algorithm)
        writer.writeVarint(field: 5, account.digits == 8 ? 2 : 1)
        writer.writeVarint(field: 6, account.kind == .hotp ? 1 : 2)
        if account.kind == .hotp { writer.writeVarint(field: 7, account.counter) }
        return writer.bytes
    }

    // MARK: Helpers

    static func base64Decode(_ string: String) -> Data? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "+") // '+' mangled to space by some decoders
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

// MARK: - Minimal, bounds-checked protobuf reader/writer

enum ProtoWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct ProtoReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw OTPImportError.invalidMigrationPayload }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func nextTag() throws -> (Int, ProtoWireType)? {
        if isAtEnd { return nil }
        let key = try readVarint()
        guard let wire = ProtoWireType(rawValue: UInt8(key & 0x7)) else { throw OTPImportError.invalidMigrationPayload }
        let field = Int(truncatingIfNeeded: key >> 3)
        guard field > 0 else { throw OTPImportError.invalidMigrationPayload }
        return (field, wire)
    }

    mutating func readLengthDelimited() throws -> [UInt8] {
        let length = try readVarint()
        guard length <= UInt64(bytes.count - index) else { throw OTPImportError.invalidMigrationPayload }
        let end = index + Int(length)
        defer { index = end }
        return Array(bytes[index..<end])
    }

    mutating func skip(_ wire: ProtoWireType) throws {
        switch wire {
        case .varint: _ = try readVarint()
        case .lengthDelimited: _ = try readLengthDelimited()
        case .fixed64: try advance(8)
        case .fixed32: try advance(4)
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard bytes.count - index >= count else { throw OTPImportError.invalidMigrationPayload }
        index += count
    }
}

struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func appendVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func writeVarint(field: Int, _ value: UInt64) {
        appendVarint(UInt64(field << 3) | UInt64(ProtoWireType.varint.rawValue))
        appendVarint(value)
    }

    mutating func writeBytes(field: Int, _ value: [UInt8]) {
        appendVarint(UInt64(field << 3) | UInt64(ProtoWireType.lengthDelimited.rawValue))
        appendVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func writeMessage(field: Int, _ value: [UInt8]) { writeBytes(field: field, value) }
}
