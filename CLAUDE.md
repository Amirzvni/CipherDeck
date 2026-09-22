# CipherDeck — project instructions for Claude

CipherDeck is an open-source, native macOS authenticator (TOTP/HOTP) app. It exists because
Google Authenticator has no Mac app. It must do everything the iPhone Google Authenticator
app does — and fill the gaps it leaves — wrapped in a Cyberpunk 2077 visual theme.

Owner: Amir Rezvani. The UI footer must always read: **"Created by Amir Rezvani with ❤️"**.

Progress, phases and the backlog live in [STATE.md](STATE.md). **Update STATE.md after
finishing every phase** (tick items, note decisions, record what's next).

---

## The two pillars (non-negotiable)

### 1. Security — secrets must never leak
Malware on the user's Mac must not be able to quietly steal their 2FA secrets or codes.

- **Secrets never touch disk in plaintext.** The vault is AES-256-GCM encrypted
  (CryptoKit). The 256-bit vault key lives only in the macOS Keychain, whose ACL is bound to
  the app's code signature — any other process asking for it triggers a system prompt.
- **No networking. Ever.** No analytics, no crash reporters, no update checks, no favicon
  fetching, no third-party SDKs. Do not import URLSession/Network for app features. If a
  future feature seems to need the network, stop and ask the owner.
- **Zero third-party dependencies.** Apple frameworks only (SwiftUI, AppKit, CryptoKit,
  Security, LocalAuthentication, Vision, AVFoundation, CommonCrypto). This keeps the supply
  chain auditable. Do not add SwiftPM packages.
- **Hardened Runtime** is always on (blocks dylib injection / debugger attach). Entitlements
  are minimal: only the camera (QR scanning). Never add `disable-library-validation`,
  `allow-dyld-environment-variables`, `get-task-allow` or network entitlements.
- **Screen-capture protection:** app windows set `NSWindow.sharingType = .none` by default so
  screen recorders/screenshot malware can't grab codes or QR exports.
- **Clipboard hygiene:** copied codes are marked `org.nspasteboard.ConcealedType` +
  `TransientType` (clipboard managers skip them) and are auto-cleared after a timeout — only
  if the clipboard still holds our value.
- **App lock:** Touch ID / macOS password (LocalAuthentication), auto-lock on idle, sleep,
  screen lock. When locked, no code or secret is computed or rendered.
- **Exports are encrypted or explicit.** Backups use a password → PBKDF2-HMAC-SHA256
  (600k iterations) → AES-256-GCM. Showing transfer QR codes requires authentication.
  Never write secrets to logs, `print`, UserDefaults, temp files that outlive their use,
  or crash-prone string interpolation in errors.
- Treat all imported data (QR payloads, files, URIs) as hostile: bounds-check the protobuf
  decoder, validate every field, never crash on malformed input.

### 2. Reliability — never lose a user's accounts
Losing 2FA secrets can lock people out of their lives.

- **Atomic writes only.** Vault writes go to a temp file and are atomically renamed; the
  previous good vault is kept as `vault.cdv.bak`, and loading falls back to it.
- **Never overwrite what you can't read.** If a vault exists but the key is missing or
  decryption fails, show an error — never silently create a fresh empty vault over it.
- **Versioned formats.** Vault, payload and backup formats carry a version. Decoding must
  tolerate missing (new) fields with defaults. Never break reading older files.
- **Correct codes.** OTP generation is verified against the RFC 4226 / RFC 6238 test
  vectors in the self-test suite. Any change to crypto/OTP/parsing code must keep
  `swift run CipherDeckSelfTest` green.
- **Imports are additive and de-duplicated**; deleting always asks for confirmation.

---

## Stack & layout

- Swift 6 toolchain (Swift 5 language mode), SwiftUI + AppKit, SwiftPM. macOS 14+, Apple
  Silicon (arm64) primary.
- `Sources/CipherDeckCore` — pure logic, no UI: Base32, HOTP/TOTP, `otpauth://` parsing,
  Google Authenticator `otpauth-migration://` protobuf decode/encode, vault crypto/file,
  encrypted backups, import parsing/merge. Everything security-critical lives here and is
  tested.
- `Sources/CipherDeck` — the SwiftUI app (views, theme, keychain, lock, clipboard, QR
  scanning via camera / screen region / image files).
- `Sources/CipherDeckSelfTest` — executable test suite (the CLT toolchain on this machine
  has neither XCTest nor swift-testing). Run: `swift run CipherDeckSelfTest`.
- `scripts/build_app.sh` builds the `.app` bundle, ad-hoc signs it with Hardened Runtime;
  `scripts/make_dmg.sh` produces `dist/CipherDeck-<version>.dmg`.
  `scripts/generate_icon.swift` renders the logo → `Resources/AppIcon.icns`.

## Build environment gotchas

- The owner has **no Apple Developer account**. Builds are ad-hoc signed (`codesign -s -`).
  Never introduce anything requiring a Team ID (App Groups, data-protection keychain,
  notarization, iCloud).
- Xcode's license isn't accepted on this machine, so prefix tool invocations with
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools` (swift, git). The scripts do this.
- Ad-hoc signatures change every build, so after an update macOS asks once to allow
  CipherDeck to access its Keychain item. That's expected (and is the security feature).

## Theme — Cyberpunk 2077

Near-black background, signature yellow `#FCEE0A`, neon cyan `#00F0FF`, hot red `#FF003C`.
Monospaced, uppercase, tracked-out labels; chamfered (cut-corner) panels; subtle scanlines;
glitch/chromatic-aberration accents on titles. Keep it readable: codes must be large, high
contrast, and grouped (`123 456`). Keep the theme in `Theme.swift`; don't hardcode colors in
views.

## Conventions

- Keep UI code thin; put logic in `CipherDeckCore` where it can be tested.
- Use `SecureBytes`-style care: minimize the lifetime of decoded secrets in UI state.
- Every new import/export format gets self-tests with real-world sample payloads.
- Update `STATE.md` at the end of every phase.
