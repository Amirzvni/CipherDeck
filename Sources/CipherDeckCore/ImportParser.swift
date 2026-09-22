import Foundation

/// Turns scanned QR payloads, pasted text or text files into accounts. Accepts any mix of
/// `otpauth://` links and Google Authenticator `otpauth-migration://` links.
public struct ImportResult: Sendable {
    public var accounts: [OTPAccount] = []
    public var errors: [String] = []
    public var skippedUnsupported = 0
    /// For Google multi-QR exports: batch id → set of batch indexes seen, and expected size.
    public var migrationBatches: [Int: (seen: Set<Int>, size: Int)] = [:]

    public init() {}

    public var isEmpty: Bool { accounts.isEmpty }

    /// Human-readable hint like "Scanned 2 of 3 QR codes" for incomplete Google exports.
    public var missingBatchHint: String? {
        for (_, info) in migrationBatches where info.seen.count < info.size {
            return "Scanned \(info.seen.count) of \(info.size) Google export QR codes — scan the rest too."
        }
        return nil
    }

    public mutating func merge(_ other: ImportResult) {
        accounts.append(contentsOf: other.accounts)
        errors.append(contentsOf: other.errors)
        skippedUnsupported += other.skippedUnsupported
        for (id, info) in other.migrationBatches {
            let existing = migrationBatches[id]
            migrationBatches[id] = ((existing?.seen ?? []).union(info.seen), max(existing?.size ?? 0, info.size))
        }
    }
}

public enum ImportParser {
    public static func parse(text: String) -> ImportResult {
        var result = ImportResult()
        let links = extractLinks(from: text)
        if links.isEmpty {
            result.errors.append(OTPImportError.noAccountsFound.localizedDescription)
            return result
        }
        for link in links {
            result.merge(parse(link: link))
        }
        return result
    }

    public static func parse(link: String) -> ImportResult {
        var result = ImportResult()
        do {
            if GoogleMigration.isMigrationURI(link) {
                let batch = try GoogleMigration.decode(uri: link)
                result.accounts.append(contentsOf: batch.accounts)
                result.skippedUnsupported += batch.skipped
                if batch.batchSize > 1 {
                    result.migrationBatches[batch.batchID] = ([batch.batchIndex], batch.batchSize)
                }
            } else {
                result.accounts.append(try OTPAuthURI.parse(link))
            }
        } catch {
            result.errors.append(error.localizedDescription)
        }
        return result
    }

    /// Finds every `otpauth://` / `otpauth-migration://` link in free text.
    public static func extractLinks(from text: String) -> [String] {
        let pattern = #"otpauth(?:-migration)?://[^\s"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

public enum VaultMerge {
    public struct Outcome: Sendable {
        public var accounts: [OTPAccount]
        public var added: Int
        public var duplicates: Int
        public var invalid: Int
    }

    /// Appends `incoming` to `existing`, skipping accounts already present (and duplicates
    /// within `incoming`). Existing accounts are never modified or removed.
    public static func merge(existing: [OTPAccount], incoming: [OTPAccount]) -> Outcome {
        var seen = Set(existing.map(\.dedupeKey))
        var merged = existing
        var added = 0
        var duplicates = 0
        var invalid = 0
        for var account in incoming {
            guard account.isValid else { invalid += 1; continue }
            if seen.insert(account.dedupeKey).inserted {
                account.id = UUID()
                merged.append(account)
                added += 1
            } else {
                duplicates += 1
            }
        }
        return Outcome(accounts: merged, added: added, duplicates: duplicates, invalid: invalid)
    }
}
