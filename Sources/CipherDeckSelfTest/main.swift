import CipherDeckCore
import CryptoKit
import Foundation

// Executable test suite: `swift run CipherDeckSelfTest`.
// (The Command Line Tools toolchain ships neither XCTest nor swift-testing.)

var failures = 0
var checks = 0
var currentSuite = ""

func suite(_ name: String, _ body: () throws -> Void) {
    currentSuite = name
    let before = failures
    do { try body() } catch {
        failures += 1
        print("  ✗ [\(name)] threw: \(error)")
    }
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  ✗ [\(currentSuite)] line \(line): \(message)")
    }
}

func expectThrows(_ message: String, line: Int = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("  ✗ [\(currentSuite)] line \(line): expected throw — \(message)")
    } catch {}
}

let rfcSHA1 = Data("12345678901234567890".utf8)
let rfcSHA256 = Data("12345678901234567890123456789012".utf8)
let rfcSHA512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

// MARK: - Base32

suite("Base32 RFC 4648 vectors") {
    let vectors = [("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"), ("foob", "MZXW6YQ"),
                   ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI")]
    for (plain, encoded) in vectors {
        expect(Base32.encode(Data(plain.utf8)) == encoded, "encode \(plain)")
        expect(Base32.decode(encoded) == Data(plain.utf8), "decode \(encoded)")
    }
    expect(Base32.decode("mzxw 6ytb-oi======") == Data("foobar".utf8), "tolerant decode")
    expect(Base32.decode("JBSWY3DPEHPK3PXP") != nil, "classic example key")
    expect(Base32.decode("ABC1") == nil, "rejects '1'")
    expect(Base32.decode("") == nil, "rejects empty")
    expect(Base32.decode("   ") == nil, "rejects whitespace only")
    for _ in 0..<500 {
        let bytes = Data((0..<Int.random(in: 1...64)).map { _ in UInt8.random(in: 0...255) })
        expect(Base32.decode(Base32.encode(bytes)) == bytes, "random round-trip")
    }
}

// MARK: - HOTP / TOTP

suite("HOTP RFC 4226 Appendix D") {
    let expected = ["755224", "287082", "359152", "969429", "338314",
                    "254676", "287922", "162583", "399871", "520489"]
    for (counter, code) in expected.enumerated() {
        expect(OTPGenerator.hotp(secret: rfcSHA1, counter: UInt64(counter)) == code, "counter \(counter)")
    }
}

suite("TOTP RFC 6238 Appendix B") {
    let table: [(TimeInterval, String, String, String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1111111109, "07081804", "68084774", "25091201"),
        (1111111111, "14050471", "67062674", "99943326"),
        (1234567890, "89005924", "91819424", "93441116"),
        (2000000000, "69279037", "90698825", "38618901"),
        (20000000000, "65353130", "77737706", "47863826"),
    ]
    for (t, sha1, sha256, sha512) in table {
        let date = Date(timeIntervalSince1970: t)
        expect(OTPGenerator.totp(secret: rfcSHA1, at: date, digits: 8, algorithm: .sha1) == sha1, "SHA1 @\(t)")
        expect(OTPGenerator.totp(secret: rfcSHA256, at: date, digits: 8, algorithm: .sha256) == sha256, "SHA256 @\(t)")
        expect(OTPGenerator.totp(secret: rfcSHA512, at: date, digits: 8, algorithm: .sha512) == sha512, "SHA512 @\(t)")
    }
}

suite("TOTP helpers") {
    let date = Date(timeIntervalSince1970: 59)
    expect(abs(OTPGenerator.secondsRemaining(at: date, period: 30) - 1) < 0.0001, "1s remaining at t=59")
    expect(OTPGenerator.totpCounter(at: date, period: 30) == 1, "counter at t=59")
    let account = OTPAccount(issuer: "X", name: "y", secret: rfcSHA1, digits: 8)
    expect(account.code(at: date) == "94287082", "account code")
    expect(account.nextCode(at: Date(timeIntervalSince1970: 29)) == "94287082", "next code = following window")
    var hotp = OTPAccount(issuer: "H", name: "h", secret: rfcSHA1, kind: .hotp, counter: 3)
    expect(hotp.code() == "969429", "HOTP current")
    expect(hotp.nextCode() == "338314", "HOTP next")
    hotp.counter += 1
    expect(hotp.code() == "338314", "HOTP advanced")
    expect("123456".groupedCode == "123 456", "group 6")
    expect("12345678".groupedCode == "1234 5678", "group 8")
    expect("1234567".groupedCode == "123 4567", "group 7")
}

// MARK: - otpauth://

suite("otpauth:// parsing") {
    let a = try OTPAuthURI.parse("otpauth://totp/ACME%20Co:john.doe@email.com?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=ACME%20Co&algorithm=SHA1&digits=6&period=30")
    expect(a.issuer == "ACME Co", "issuer")
    expect(a.name == "john.doe@email.com", "name")
    expect(a.kind == .totp && a.digits == 6 && a.period == 30 && a.algorithm == .sha1, "params")

    let b = try OTPAuthURI.parse("otpauth://totp/Example:alice@google.com?secret=JBSWY3DPEHPK3PXP")
    expect(b.issuer == "Example" && b.name == "alice@google.com", "issuer from label")

    let c = try OTPAuthURI.parse("otpauth://hotp/bob?secret=jbswy3dpehpk3pxp&counter=42&digits=8&algorithm=sha256")
    expect(c.kind == .hotp && c.counter == 42 && c.digits == 8 && c.algorithm == .sha256, "hotp params")
    expect(c.issuer.isEmpty && c.name == "bob", "no issuer")

    let d = try OTPAuthURI.parse("OTPAUTH://TOTP/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&period=60")
    expect(d.period == 60, "uppercase scheme + period")

    expectThrows("no secret") { _ = try OTPAuthURI.parse("otpauth://totp/x?issuer=y") }
    expectThrows("bad secret") { _ = try OTPAuthURI.parse("otpauth://totp/x?secret=!!!!") }
    expectThrows("bad digits") { _ = try OTPAuthURI.parse("otpauth://totp/x?secret=JBSWY3DP&digits=12") }
    expectThrows("bad algorithm") { _ = try OTPAuthURI.parse("otpauth://totp/x?secret=JBSWY3DP&algorithm=MD5") }
    expectThrows("bad type") { _ = try OTPAuthURI.parse("otpauth://steam/x?secret=JBSWY3DP") }
    expectThrows("not otpauth") { _ = try OTPAuthURI.parse("https://example.com") }
}

suite("otpauth:// build round-trip") {
    let accounts = [
        OTPAccount(issuer: "ACME Co", name: "john+doe@email.com", secret: Data("abcdefghij".utf8)),
        OTPAccount(issuer: "", name: "solo", secret: Data("0123456789".utf8), algorithm: .sha512, digits: 8, period: 60),
        OTPAccount(issuer: "Bank & Trust", name: "a:b", secret: rfcSHA1, kind: .hotp, counter: 7),
    ]
    for account in accounts {
        let uri = OTPAuthURI.build(account)
        let parsed = try OTPAuthURI.parse(uri)
        expect(parsed.dedupeKey == account.dedupeKey, "round-trip \(uri)")
        expect(parsed.digits == account.digits && parsed.period == account.period
               && parsed.counter == account.counter && parsed.algorithm == account.algorithm, "params \(uri)")
    }
}

// MARK: - Google Authenticator migration

suite("Google migration: known sample") {
    // Public sample payload: secret "Hello!\xde\xad\xbe\xef", label "Example:alice@google.com".
    let uri = "otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8SGEV4YW1wbGU6YWxpY2VAZ29vZ2xlLmNvbRoHRXhhbXBsZTAC"
    let batch = try GoogleMigration.decode(uri: uri)
    expect(batch.accounts.count == 1, "one account")
    let a = batch.accounts[0]
    expect(Base32.encode(a.secret) == "JBSWY3DPEHPK3PXP", "secret")
    expect(a.issuer == "Example", "issuer")
    expect(a.name == "alice@google.com", "name stripped of issuer prefix")
    expect(a.kind == .totp && a.digits == 6 && a.algorithm == .sha1, "defaults")
}

suite("Google migration: encode/decode round-trip & batching") {
    var accounts: [OTPAccount] = []
    for i in 0..<19 {
        let secret = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        accounts.append(OTPAccount(issuer: i % 3 == 0 ? "" : "Issuer \(i)", name: "user\(i)@mail.com",
                                   secret: secret, algorithm: [.sha1, .sha256, .sha512][i % 3],
                                   digits: i % 2 == 0 ? 6 : 8, kind: i % 5 == 0 ? .hotp : .totp,
                                   counter: UInt64(i * 1000)))
    }
    accounts.append(OTPAccount(issuer: "Weird", name: "60s", secret: rfcSHA1, period: 60))
    let (uris, unsupported) = GoogleMigration.encode(accounts, perBatch: 8)
    expect(uris.count == 3, "19 exportable → 3 QR codes")
    expect(unsupported.count == 1 && unsupported[0].issuer == "Weird", "60s period unsupported")

    var result = ImportResult()
    for uri in uris { result.merge(ImportParser.parse(link: uri)) }
    expect(result.errors.isEmpty, "no errors: \(result.errors)")
    expect(result.missingBatchHint == nil, "all batches seen")
    let exportable = accounts.filter(GoogleMigration.isExportable)
    expect(result.accounts.map(\.dedupeKey) == exportable.map(\.dedupeKey), "identical accounts")
    expect(result.accounts.filter { $0.kind == .hotp }.map(\.counter)
           == exportable.filter { $0.kind == .hotp }.map(\.counter), "HOTP counters kept")

    let partial = ImportParser.parse(link: uris[0])
    expect(partial.missingBatchHint != nil, "hint for partial export")
}

suite("Google migration: hostile input never crashes") {
    let good = GoogleMigration.encode([OTPAccount(issuer: "A", name: "b", secret: rfcSHA1)]).uris[0]
    let payload = try GoogleMigration.decode(uri: good)
    expect(payload.accounts.count == 1, "baseline")
    let raw = Array(Data(base64Encoded: String(good.split(separator: "=", maxSplits: 1)[1])
        .removingPercentEncoding!)!)
    for cut in 0..<raw.count {
        _ = try? GoogleMigration.decode(payload: Data(raw[0..<cut]))
    }
    for _ in 0..<20_000 {
        let bytes = Data((0..<Int.random(in: 0...200)).map { _ in UInt8.random(in: 0...255) })
        _ = try? GoogleMigration.decode(payload: bytes)
    }
    // Absurd length prefix must be rejected, not allocated.
    expectThrows("huge length") { _ = try GoogleMigration.decode(payload: Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F])) }
    expectThrows("bad uri") { _ = try GoogleMigration.decode(uri: "otpauth-migration://offline?data=") }
    expect(true, "survived fuzzing")
}

// MARK: - Import parsing & merge

suite("Import parser & merge") {
    let text = """
    some notes
    otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub
    "otpauth://totp/AWS:root?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ"
    otpauth://totp/broken?secret=
    otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8SGEV4YW1wbGU6YWxpY2VAZ29vZ2xlLmNvbRoHRXhhbXBsZTAC
    """
    let result = ImportParser.parse(text: text)
    expect(result.accounts.count == 3, "3 accounts, got \(result.accounts.count)")
    expect(result.errors.count == 1, "1 error")

    let existing = [result.accounts[0]]
    let outcome = VaultMerge.merge(existing: existing, incoming: result.accounts + result.accounts)
    expect(outcome.added == 2, "2 added")
    expect(outcome.duplicates == 4, "4 duplicates")
    expect(outcome.accounts.first?.id == existing[0].id, "existing untouched")
}

// MARK: - Vault

suite("Vault encrypt / atomic save / backup fallback") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cd-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = VaultFile(url: dir.appendingPathComponent("vault.cdv"))
    let key = VaultCrypto.newKey()
    let one = [OTPAccount(issuer: "One", name: "a", secret: rfcSHA1)]
    let two = one + [OTPAccount(issuer: "Two", name: "b", secret: rfcSHA256, algorithm: .sha256)]

    expect(!vault.exists, "fresh")
    try vault.save(one, key: key)
    expect(vault.exists, "exists after save")
    try vault.save(two, key: key)

    let loaded = try vault.load(key: key)
    expect(loaded.accounts.map(\.id) == two.map(\.id) && !loaded.recoveredFromBackup, "load latest")

    let raw = try Data(contentsOf: vault.url)
    expect(raw.range(of: Data("12345678901234567890".utf8)) == nil, "no plaintext secret on disk")
    expect(raw.range(of: Data("One".utf8)) == nil, "no plaintext issuer on disk")
    let perms = try FileManager.default.attributesOfItem(atPath: vault.url.path)[.posixPermissions] as? Int
    expect(perms == 0o600, "vault is 0600")

    expectThrows("wrong key") { _ = try vault.load(key: VaultCrypto.newKey()) }

    // Corrupt main file → falls back to .bak (previous good version).
    try Data("garbage".utf8).write(to: vault.url)
    let recovered = try vault.load(key: key)
    expect(recovered.recoveredFromBackup && recovered.accounts.map(\.id) == one.map(\.id), "recovered from .bak")

    // Saving over a corrupt main must not clobber the good .bak.
    try vault.save(two, key: key)
    let bak = try VaultFile(url: vault.backupURL).load(key: key)
    expect(bak.accounts.map(\.id) == one.map(\.id), "good .bak preserved")

    // Tampering is detected.
    var tampered = try Data(contentsOf: vault.url)
    tampered[tampered.count / 2] ^= 0x01
    try tampered.write(to: vault.url)
    try? FileManager.default.removeItem(at: vault.backupURL)
    expectThrows("tampered") { _ = try vault.load(key: key) }
}

// MARK: - Encrypted backups

suite("Encrypted backup") {
    let accounts = [OTPAccount(issuer: "GitHub", name: "me", secret: rfcSHA1, note: "recovery codes in safe"),
                    OTPAccount(issuer: "Bank", name: "you", secret: rfcSHA512, algorithm: .sha512, digits: 8, kind: .hotp, counter: 9)]
    let file = try EncryptedBackup.export(accounts, password: "correct horse battery", iterations: 20_000)
    expect(EncryptedBackup.isBackup(file), "recognized")
    expect(file.range(of: Data("GitHub".utf8)) == nil, "no plaintext in backup")
    let restored = try EncryptedBackup.import(file, password: "correct horse battery")
    expect(restored.map(\.dedupeKey) == accounts.map(\.dedupeKey), "restored")
    expect(restored[1].counter == 9 && restored[0].note == "recovery codes in safe", "fields kept")
    expectThrows("wrong password") { _ = try EncryptedBackup.import(file, password: "wrong horse battery") }
    expectThrows("weak password") { _ = try EncryptedBackup.export(accounts, password: "short") }

    // Downgrading the KDF iterations in the header must fail (header is AAD).
    var json = try JSONSerialization.jsonObject(with: file) as! [String: Any]
    json["iterations"] = 10_000
    let downgraded = try JSONSerialization.data(withJSONObject: json)
    expectThrows("tampered header") { _ = try EncryptedBackup.import(downgraded, password: "correct horse battery") }

    let start = Date()
    _ = try EncryptedBackup.export(accounts, password: "correct horse battery")
    print("    (600k-iteration PBKDF2 export took \(String(format: "%.2f", Date().timeIntervalSince(start)))s)")
}

suite("Forward-compatible account decoding") {
    let json = #"{"secret":"MTIzNDU2Nzg5MDEyMzQ1Njc4OTA=","issuer":"Old","futureField":true}"#
    let account = try JSONDecoder().decode(OTPAccount.self, from: Data(json.utf8))
    expect(account.issuer == "Old" && account.digits == 6 && account.period == 30 && account.kind == .totp, "defaults")
}

print("")
print(failures == 0 ? "ALL \(checks) CHECKS PASSED" : "\(failures) FAILURE(S) out of \(checks) checks")
exit(failures == 0 ? 0 : 1)
