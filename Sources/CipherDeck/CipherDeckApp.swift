import AppKit
import CipherDeckCore
import SwiftUI

enum AppCommand {
    case add, scanCamera, scanScreen, importFile, importGoogle, exportGoogle, exportBackup, paste, find, lock, settings
}

extension Notification.Name {
    static let cipherDeckCommand = Notification.Name("CipherDeckCommand")
}

@MainActor
func send(_ command: AppCommand) {
    NotificationCenter.default.post(name: .cipherDeckCommand, object: command)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-apply capture protection whenever any window (sheets, menus, alerts) appears.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if let window = note.object as? NSWindow { WindowProtection.apply(to: window) }
                }
            }
        }
        scheduleSnapshotIfRequested()
    }

    /// `--demo --snapshot <file.png>`: renders the main window to a PNG and quits
    /// (README screenshots). Only allowed with demo data, never with a real vault.
    private func scheduleSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard AppModel.isDemo, let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 })
            else { exit(2) }
            let target = window.attachedSheet ?? window
            guard let view = target.contentView?.superview ?? target.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: SettingsKey.menuBar)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct CipherDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage(SettingsKey.menuBar) private var showMenuBar = true

    var body: some Scene {
        Window("CipherDeck", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Enter Setup Key…") { send(.add) }.keyboardShortcut("n")
                Button("Scan QR with Camera…") { send(.scanCamera) }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Scan QR on Screen…") { send(.scanScreen) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Import QR Image or File…") { send(.importFile) }.keyboardShortcut("o")
                Divider()
                Button("Import from Google Authenticator…") { send(.importGoogle) }
                Button("Export to Google Authenticator…") { send(.exportGoogle) }
                Button("Export Encrypted Backup…") { send(.exportBackup) }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste 2FA Link or QR Image") { send(.paste) }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find Account") { send(.find) }.keyboardShortcut("f")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { send(.settings) }.keyboardShortcut(",")
            }
            CommandMenu("Vault") {
                Button("Lock Vault") { send(.lock) }.keyboardShortcut("l")
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: "key.viewfinder")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar quick access

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GlitchText(text: "CIPHERDECK", size: 13)
                Spacer()
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "macwindow") }
                    .buttonStyle(IconButtonStyle(color: CP.cyan))
                    .help("Open CipherDeck")
                if model.isUnlocked && UserDefaults.standard.bool(forKey: SettingsKey.appLock) {
                    Button { model.lock() } label: { Image(systemName: "lock.fill") }
                        .buttonStyle(IconButtonStyle(color: CP.red))
                }
            }
            .padding(12)

            if model.isUnlocked {
                TextField("", text: $query, prompt: Text("> SEARCH_").foregroundStyle(CP.dim))
                    .textFieldStyle(.plain)
                    .font(CP.mono(12))
                    .padding(8)
                    .cpPanel(stroke: CP.line, fill: CP.bg, cut: 7)
                    .padding(.horizontal, 12)
                    .onSubmit {
                        if let first = filtered.first { model.copyCode(for: first) }
                    }

                let list = filtered
                if list.isEmpty {
                    Text(model.accounts.isEmpty ? "NO ACCOUNTS YET" : "NO MATCH")
                        .font(CP.mono(11, .bold)).foregroundStyle(CP.dim).padding(24)
                } else {
                    ScrollView {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(spacing: 4) {
                                ForEach(list) { account in
                                    MenuBarRow(account: account, now: context.date) { model.copyCode(for: account) }
                                }
                            }
                            .padding(12)
                        }
                    }
                    .frame(maxHeight: 420)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.system(size: 26)).foregroundStyle(CP.red)
                    Text("VAULT LOCKED").font(CP.mono(12, .bold)).tracking(2).foregroundStyle(CP.red)
                    Button("Unlock") { Task { await model.unlock() } }
                        .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true, compact: true))
                }
                .padding(24)
            }

            if let toast = model.toast {
                Text(toast.message).font(CP.mono(10, .bold))
                    .foregroundStyle(toast.kind == .error ? CP.red : CP.green)
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    .lineLimit(2)
            }
            Rectangle().fill(CP.line).frame(height: 1)
            CreditFooter(compact: true).padding(8)
        }
        .frame(width: 340)
        .background(CyberBackground())
        .preferredColorScheme(.dark)
        .protectedFromCapture()
    }

    private var filtered: [OTPAccount] {
        model.visibleAccounts.filter { $0.matches(query) }
    }
}

struct MenuBarRow: View {
    let account: OTPAccount
    let now: Date
    var onCopy: () -> Void
    @AppStorage(SettingsKey.hideCodes) private var hideCodes = false
    @State private var hovering = false

    var body: some View {
        let remaining = OTPGenerator.secondsRemaining(at: now, period: account.period)
        let urgent = account.kind == .totp && remaining <= 5
        HStack(spacing: 10) {
            IssuerBadge(title: account.title, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.title.uppercased()).font(CP.mono(10, .bold)).foregroundStyle(CP.yellow).lineLimit(1)
                if !account.subtitle.isEmpty {
                    Text(account.subtitle).font(CP.mono(9)).foregroundStyle(CP.dim).lineLimit(1)
                }
            }
            Spacer()
            Text(hideCodes && !hovering ? "••• •••" : account.code(at: now).groupedCode)
                .font(CP.mono(16, .semibold))
                .foregroundStyle(urgent ? CP.red : CP.cyan)
            if account.kind == .totp {
                CountdownRing(period: account.period, size: 22)
            }
        }
        .padding(8)
        .background(Chamfer(cut: 8).fill(hovering ? CP.panelHi : CP.panel))
        .overlay(Chamfer(cut: 8).stroke(hovering ? CP.yellow.opacity(0.8) : CP.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
    }
}
