import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security

// MARK: - Keychain

/// Stores the 256-bit vault key in the login Keychain. The item's ACL is bound to this app's
/// code signature, so any other process that asks for it triggers a system prompt.
enum KeychainStore {
    static let service = "com.amirrezvani.cipherdeck"
    static let account = "vault-key"

    enum KeychainError: Error, LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let s):
                let message = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "Keychain error: \(message)"
            }
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Returns nil only if the item definitely doesn't exist; any other failure throws
    /// (so we never mistake "access denied" for "no key" and overwrite a vault).
    static func loadKey() throws -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw KeychainError.status(errSecDecode) }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    static func saveKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "CipherDeck vault key"
        attributes[kSecAttrDescription as String] = "Encryption key for your CipherDeck 2FA vault"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}

// MARK: - Authentication

enum Authenticator {
    /// Touch ID / Apple Watch / macOS account password.
    static func authenticate(reason: String) async -> Bool {
        if AppModel.isDemo { return true } // demo data only
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode/biometrics configured at all: nothing to authenticate against.
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "Password"
        }
    }
}

// MARK: - Clipboard

@MainActor
enum Clipboard {
    /// nspasteboard.org markers: clipboard managers skip concealed/transient items.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static var clearTask: Task<Void, Never>?

    static func copySecret(_ value: String, clearAfter seconds: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, concealed, transient], owner: nil)
        pb.setString(value, forType: .string)
        pb.setString("", forType: concealed)
        pb.setString("", forType: transient)
        let changeCount = pb.changeCount

        clearTask?.cancel()
        guard seconds > 0 else { return }
        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // Only clear if the clipboard still holds our code.
            if NSPasteboard.general.changeCount == changeCount {
                NSPasteboard.general.clearContents()
            }
        }
    }
}

// MARK: - Screen-capture protection

@MainActor
enum WindowProtection {
    static var enabled = true

    static func apply(to window: NSWindow?) {
        window?.sharingType = enabled ? .none : .readOnly
    }

    static func applyToAll() {
        for window in NSApp.windows { apply(to: window) }
    }
}

/// Grabs the hosting NSWindow to apply capture protection.
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { configure(window) } }
    }
}

import SwiftUI

extension View {
    /// Hides this window from screenshots / screen recording (when enabled in settings).
    func protectedFromCapture() -> some View {
        background(WindowAccessor { WindowProtection.apply(to: $0) })
    }
}
