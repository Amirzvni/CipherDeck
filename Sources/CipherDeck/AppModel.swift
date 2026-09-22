import AppKit
import CipherDeckCore
import CryptoKit
import Foundation
import Observation
import SwiftUI

enum SettingsKey {
    static let appLock = "appLockEnabled"
    static let autoLockMinutes = "autoLockMinutes"
    static let lockOnSleep = "lockOnSleep"
    static let clipboardSeconds = "clipboardClearSeconds"
    static let hideCodes = "hideCodes"
    static let showNextCode = "showNextCode"
    static let menuBar = "showMenuBarExtra"
    static let captureProtection = "screenCaptureProtection"
    static let sortMode = "sortMode"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            appLock: true, autoLockMinutes: 5, lockOnSleep: true, clipboardSeconds: 30,
            hideCodes: false, showNextCode: true, menuBar: true, captureProtection: true,
            sortMode: SortMode.manual.rawValue,
        ])
    }
}

enum SortMode: String, CaseIterable, Identifiable {
    case manual, issuer, recent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: return "Custom order"
        case .issuer: return "A → Z"
        case .recent: return "Newest first"
        }
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case success, info, error }
    let id = UUID()
    let message: String
    var kind: Kind = .success
}

/// Pending import waiting for user confirmation.
struct PendingImport: Identifiable {
    let id = UUID()
    var source: String
    var result: ImportResult
}

@MainActor
@Observable
final class AppModel {
    enum VaultState: Equatable {
        case locked
        case ready
        case keyMissing      // vault on disk, key gone from Keychain
        case failed(String)
    }

    private(set) var accounts: [OTPAccount] = []
    private(set) var state: VaultState = .locked
    private(set) var recoveredFromBackup = false
    var toast: Toast?
    var pendingImport: PendingImport?
    var searchText = ""

    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private let vault: VaultFile
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var unlocking = false

    var isUnlocked: Bool { state == .ready }

    /// `--demo`: in-memory sample accounts for screenshots. Never touches the Keychain or disk.
    nonisolated static let isDemo = CommandLine.arguments.contains("--demo")
    /// `--demo --demo-screen <name>`: which screen to show (README screenshots).
    nonisolated static let demoScreen: String? = {
        let args = CommandLine.arguments
        guard isDemo, let i = args.firstIndex(of: "--demo-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    static let vaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CipherDeck", isDirectory: true)
    }()

    init() {
        SettingsKey.registerDefaults()
        vault = VaultFile(url: Self.vaultDirectory.appendingPathComponent("vault.cdv"))
        WindowProtection.enabled = UserDefaults.standard.bool(forKey: SettingsKey.captureProtection)
        if Self.isDemo {
            WindowProtection.enabled = false
            accounts = Self.demoScreen == "empty" ? [] : Self.demoAccounts
            state = Self.demoScreen == "locked" ? .locked : .ready
            return
        }
        installObservers()
        if !UserDefaults.standard.bool(forKey: SettingsKey.appLock) {
            openVault()
        }
    }

    // MARK: Lock / unlock

    func unlock() async {
        guard !isUnlocked, !unlocking, !Self.isDemo else { return }
        unlocking = true
        defer { unlocking = false }
        if UserDefaults.standard.bool(forKey: SettingsKey.appLock) {
            guard await Authenticator.authenticate(reason: "unlock your CipherDeck vault") else { return }
        }
        openVault()
    }

    /// Wipes decrypted accounts and the key from memory.
    func lock() {
        guard !Self.isDemo, UserDefaults.standard.bool(forKey: SettingsKey.appLock) else { return }
        accounts = []
        key = nil
        searchText = ""
        pendingImport = nil
        if state == .ready { state = .locked }
    }

    private func openVault() {
        do {
            if let existing = try KeychainStore.loadKey() {
                let result = try vault.load(key: existing)
                key = existing
                accounts = result.accounts
                recoveredFromBackup = result.recoveredFromBackup
                state = .ready
                if result.recoveredFromBackup {
                    showToast("Main vault was damaged — restored from automatic backup.", .info)
                    persist()
                }
            } else if vault.exists {
                // Never overwrite a vault we can't decrypt.
                state = .keyMissing
            } else {
                let newKey = VaultCrypto.newKey()
                try KeychainStore.saveKey(newKey)
                try vault.save([], key: newKey)
                key = newKey
                accounts = []
                state = .ready
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Recovery path when the Keychain key is gone: move the undecryptable vault aside
    /// (never delete it) and start a fresh one. The user can then restore from a backup file.
    func archiveUnreadableVaultAndStartFresh() {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for url in [vault.url, vault.backupURL] where fm.fileExists(atPath: url.path) {
            let dest = url.deletingLastPathComponent().appendingPathComponent("unreadable-\(stamp)-\(url.lastPathComponent)")
            try? fm.moveItem(at: url, to: dest)
        }
        openVault()
    }

    func retryOpen() { openVault() }

    private static var demoAccounts: [OTPAccount] {
        func a(_ issuer: String, _ name: String, pinned: Bool = false, kind: OTPKind = .totp, digits: Int = 6, period: Int = 30) -> OTPAccount {
            OTPAccount(issuer: issuer, name: name, secret: Data((0..<20).map { _ in UInt8.random(in: 0...255) }),
                       digits: digits, kind: kind, period: period, pinned: pinned)
        }
        return [a("GitHub", "v.silverhand@samurai.band", pinned: true), a("Arasaka", "netrunner@arasaka.corp"),
                a("Militech", "ops@militech.com", digits: 8), a("Night City Bank", "v@nightcity.net"),
                a("Afterlife", "rogue@afterlife.bar", kind: .hotp), a("Trauma Team", "platinum@traumateam.com", period: 60)]
    }

    // MARK: Derived list

    var visibleAccounts: [OTPAccount] {
        let filtered = accounts.filter { $0.matches(searchText) }
        let mode = SortMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.sortMode) ?? "") ?? .manual
        let sorted: [OTPAccount]
        switch mode {
        case .manual: sorted = filtered
        case .issuer: sorted = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recent: sorted = filtered.sorted { $0.createdAt > $1.createdAt }
        }
        return sorted.filter(\.pinned) + sorted.filter { !$0.pinned }
    }

    var canReorder: Bool {
        searchText.isEmpty
            && (UserDefaults.standard.string(forKey: SettingsKey.sortMode) ?? SortMode.manual.rawValue) == SortMode.manual.rawValue
    }

    // MARK: Mutations (every one persists)

    @discardableResult
    func add(_ incoming: [OTPAccount]) -> VaultMerge.Outcome? {
        guard isUnlocked else { return nil }
        let outcome = VaultMerge.merge(existing: accounts, incoming: incoming)
        guard outcome.added > 0 else {
            showToast(outcome.duplicates > 0 ? "Already in your vault." : "Nothing to add.", .info)
            return outcome
        }
        accounts = outcome.accounts
        persist()
        var message = "\(outcome.added) account\(outcome.added == 1 ? "" : "s") added"
        if outcome.duplicates > 0 { message += " · \(outcome.duplicates) duplicate\(outcome.duplicates == 1 ? "" : "s") skipped" }
        showToast(message)
        return outcome
    }

    func update(_ account: OTPAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        persist()
    }

    func delete(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        persist()
        showToast("Account deleted.", .info)
    }

    func togglePin(_ id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].pinned.toggle()
        persist()
    }

    func advanceCounter(_ id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].kind == .hotp else { return }
        accounts[index].counter &+= 1
        persist()
    }

    /// Reorder within the visible (unfiltered, manual) list.
    func move(from source: IndexSet, to destination: Int) {
        guard canReorder else { return }
        var visible = visibleAccounts
        visible.move(fromOffsets: source, toOffset: destination)
        // Keep pinned-first invariant by re-deriving the manual order from the new visible order.
        accounts = visible
        persist()
    }

    private func persist() {
        guard !Self.isDemo, let key else { return }
        do {
            try vault.save(accounts, key: key)
        } catch {
            showToast("SAVE FAILED: \(error.localizedDescription)", .error)
        }
    }

    // MARK: Actions

    func copyCode(for account: OTPAccount, next: Bool = false) {
        guard isUnlocked else { return }
        let code = next ? account.nextCode() : account.code()
        let seconds = UserDefaults.standard.integer(forKey: SettingsKey.clipboardSeconds)
        Clipboard.copySecret(code, clearAfter: seconds)
        let suffix = seconds > 0 ? " · clears in \(seconds)s" : ""
        showToast("\(account.title.uppercased()) code copied\(suffix)")
    }

    func copyTopMatch() {
        if let first = visibleAccounts.first { copyCode(for: first) }
    }

    func copy(index: Int) {
        let list = visibleAccounts
        guard list.indices.contains(index) else { return }
        copyCode(for: list[index])
    }

    func showToast(_ message: String, _ kind: Toast.Kind = .success) {
        let toast = Toast(message: message, kind: kind)
        self.toast = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 2.6))
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    // MARK: Imports

    func stageImport(_ result: ImportResult, source: String) {
        guard isUnlocked else { return }
        if result.accounts.isEmpty {
            let reason = result.errors.first ?? "No 2FA accounts found."
            showToast(reason, .error)
            return
        }
        pendingImport = PendingImport(source: source, result: result)
    }

    func stagePayloads(_ payloads: [String], source: String) {
        var result = ImportResult()
        for payload in payloads { result.merge(ImportParser.parse(link: payload)) }
        if result.accounts.isEmpty && result.errors.isEmpty {
            result.errors.append("That QR code isn't a 2FA code.")
        }
        stageImport(result, source: source)
    }

    func confirmPendingImport() {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        add(pending.result.accounts)
    }

    /// ⌘V: text with otpauth links, or an image containing a QR code.
    func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let string = pb.string(forType: .string), !ImportParser.extractLinks(from: string).isEmpty {
            stageImport(ImportParser.parse(text: string), source: "Clipboard")
            return
        }
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let image = images.first {
            let payloads = QRCode.decode(image)
            if payloads.isEmpty { showToast("No QR code found in the copied image.", .error) }
            else { stagePayloads(payloads, source: "Clipboard image") }
            return
        }
        showToast("Clipboard has no otpauth:// link or QR image.", .error)
    }

    /// Imports an image (QR), text file (otpauth links) or CipherDeck backup.
    /// Returns true when the file is an encrypted backup that needs a password
    /// (the caller then asks for it and calls `importBackup`).
    func importFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp"].contains(ext) {
            let payloads = QRCode.decode(fileURL: url)
            if payloads.isEmpty { showToast("No QR code found in \(url.lastPathComponent).", .error) }
            else { stagePayloads(payloads, source: url.lastPathComponent) }
            return false
        }
        guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else {
            showToast("Couldn't read \(url.lastPathComponent).", .error)
            return false
        }
        if EncryptedBackup.isBackup(data) { return true }
        stageImport(ImportParser.parse(text: String(decoding: data, as: UTF8.self)), source: url.lastPathComponent)
        return false
    }

    func decryptBackup(_ url: URL, password: String) async throws -> [OTPAccount] {
        guard let data = try? Data(contentsOf: url) else { throw BackupError.notABackup }
        return try await Task.detached { try EncryptedBackup.import(data, password: password) }.value
    }

    // MARK: Exports

    func exportBackup(to url: URL, password: String) async {
        let snapshot = accounts
        do {
            let data = try await Task.detached { try EncryptedBackup.export(snapshot, password: password) }.value
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            showToast("Encrypted backup saved (\(snapshot.count) accounts).")
        } catch {
            showToast(error.localizedDescription, .error)
        }
    }

    // MARK: Auto-lock

    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let lockIfEnabled: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, UserDefaults.standard.bool(forKey: SettingsKey.lockOnSleep) else { return }
                self.lock()
            }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main, using: lockIfEnabled))
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockIfEnabled))

        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }

    private func checkIdle() {
        let minutes = UserDefaults.standard.integer(forKey: SettingsKey.autoLockMinutes)
        guard isUnlocked, minutes > 0 else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if idle >= Double(minutes * 60) { lock() }
    }
}
