import Foundation

public enum OTPImportError: Error, Equatable, LocalizedError {
    case notAnOTPAuthURI
    case unsupportedType(String)
    case missingSecret
    case invalidSecret
    case unsupportedAlgorithm(String)
    case invalidDigits
    case invalidPeriod
    case invalidMigrationPayload
    case noAccountsFound

    public var errorDescription: String? {
        switch self {
        case .notAnOTPAuthURI: return "Not an otpauth:// link."
        case .unsupportedType(let t): return "Unsupported OTP type “\(t)”."
        case .missingSecret: return "The link has no secret."
        case .invalidSecret: return "The secret key is not valid Base32."
        case .unsupportedAlgorithm(let a): return "Unsupported algorithm “\(a)”."
        case .invalidDigits: return "Digits must be between 6 and 8."
        case .invalidPeriod: return "Period must be between 1 and 300 seconds."
        case .invalidMigrationPayload: return "The Google Authenticator export code is damaged or unsupported."
        case .noAccountsFound: return "No accounts were found."
        }
    }
}

/// `otpauth://TYPE/LABEL?secret=…&issuer=…&algorithm=…&digits=…&period=…&counter=…`
/// (Google's Key Uri Format).
public enum OTPAuthURI {
    public static func parse(_ raw: String) throws -> OTPAccount {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("otpauth://") else { throw OTPImportError.notAnOTPAuthURI }

        let components = URLComponents(string: trimmed)
            ?? URLComponents(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(["%", "#"])) ?? "")
        guard let components, let host = components.host?.lowercased() else {
            throw OTPImportError.notAnOTPAuthURI
        }
        guard let kind = OTPKind(rawValue: host) else { throw OTPImportError.unsupportedType(host) }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name.lowercased()] = item.value ?? ""
        }

        guard let secretString = query["secret"], !secretString.isEmpty else { throw OTPImportError.missingSecret }
        guard let secret = Base32.decode(secretString) else { throw OTPImportError.invalidSecret }

        var algorithm = OTPAlgorithm.sha1
        if let alg = query["algorithm"], !alg.isEmpty {
            guard let parsed = OTPAlgorithm(loose: alg) else { throw OTPImportError.unsupportedAlgorithm(alg) }
            algorithm = parsed
        }

        var digits = 6
        if let d = query["digits"], !d.isEmpty {
            guard let value = Int(d), OTPGenerator.allowedDigits.contains(value) else { throw OTPImportError.invalidDigits }
            digits = value
        }

        var period = 30
        if let p = query["period"], !p.isEmpty {
            guard let value = Int(p), OTPGenerator.allowedPeriods.contains(value) else { throw OTPImportError.invalidPeriod }
            period = value
        }

        let counter = UInt64(query["counter"] ?? "") ?? 0

        // Label: "Issuer:account" or "account". `path` is already percent-decoded.
        var label = components.path
        if label.hasPrefix("/") { label.removeFirst() }
        var labelIssuer = ""
        var name = label
        if let colon = label.firstIndex(of: ":") {
            labelIssuer = String(label[..<colon])
            name = String(label[label.index(after: colon)...])
        }
        let issuer = (query["issuer"].flatMap { $0.isEmpty ? nil : $0 }) ?? labelIssuer

        return OTPAccount(issuer: issuer, name: name, secret: secret, algorithm: algorithm,
                          digits: digits, kind: kind, period: period, counter: counter)
    }

    public static func build(_ account: OTPAccount) -> String {
        let labelAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":/?#"))
        let issuerPart = account.issuer.addingPercentEncoding(withAllowedCharacters: labelAllowed) ?? ""
        let namePart = account.name.addingPercentEncoding(withAllowedCharacters: labelAllowed) ?? ""
        let label = account.issuer.isEmpty ? namePart : "\(issuerPart):\(namePart)"

        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = account.kind.rawValue
        components.percentEncodedPath = "/" + label
        var items = [URLQueryItem(name: "secret", value: Base32.encode(account.secret))]
        if !account.issuer.isEmpty { items.append(URLQueryItem(name: "issuer", value: account.issuer)) }
        items.append(URLQueryItem(name: "algorithm", value: account.algorithm.rawValue))
        items.append(URLQueryItem(name: "digits", value: String(account.digits)))
        switch account.kind {
        case .totp: items.append(URLQueryItem(name: "period", value: String(account.period)))
        case .hotp: items.append(URLQueryItem(name: "counter", value: String(account.counter)))
        }
        // Encode '+', '&', '=' explicitly: some scanners read '+' as a space.
        let valueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#"))
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name,
                         value: $0.value?.addingPercentEncoding(withAllowedCharacters: valueAllowed))
        }
        return components.string ?? ""
    }
}
