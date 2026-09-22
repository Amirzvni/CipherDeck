import CipherDeckCore
import SwiftUI

struct SettingsView: View {
    var inSheet = false
    @AppStorage(SettingsKey.appLock) private var appLock = true
    @AppStorage(SettingsKey.autoLockMinutes) private var autoLockMinutes = 5
    @AppStorage(SettingsKey.lockOnSleep) private var lockOnSleep = true
    @AppStorage(SettingsKey.clipboardSeconds) private var clipboardSeconds = 30
    @AppStorage(SettingsKey.hideCodes) private var hideCodes = false
    @AppStorage(SettingsKey.showNextCode) private var showNextCode = true
    @AppStorage(SettingsKey.menuBar) private var menuBar = true
    @AppStorage(SettingsKey.captureProtection) private var captureProtection = true
    @AppStorage(SettingsKey.sortMode) private var sortMode = SortMode.manual.rawValue
    @State private var confirmDisableLock = false

    var body: some View {
        SheetFrame(title: "System config", subtitle: "Everything stays on this Mac. CipherDeck never connects to the internet.", width: 500) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel(text: "Security")
                    toggle("Require \(Authenticator.biometryName) to unlock", "Touch ID or your Mac password every time the vault opens.",
                           isOn: Binding(get: { appLock }, set: { newValue in
                               if newValue { appLock = true } else { confirmDisableLock = true }
                           }))
                    if appLock {
                        row("Auto-lock when idle", "Locks after no keyboard/mouse activity.") {
                            Picker("", selection: $autoLockMinutes) {
                                Text("1 min").tag(1); Text("5 min").tag(5); Text("15 min").tag(15)
                                Text("1 hour").tag(60); Text("Never").tag(0)
                            }.labelsHidden().frame(width: 110)
                        }
                        toggle("Lock on sleep / screen lock", "Also locks when you switch users.", isOn: $lockOnSleep)
                    }
                    toggle("Hide from screenshots & recordings", "Screen-recording malware and screen sharing see a blank window.", isOn: $captureProtection)
                        .onChange(of: captureProtection) { _, value in
                            WindowProtection.enabled = value
                            WindowProtection.applyToAll()
                        }
                    row("Clear clipboard after", "Copied codes are also hidden from clipboard managers.") {
                        Picker("", selection: $clipboardSeconds) {
                            Text("15 s").tag(15); Text("30 s").tag(30); Text("60 s").tag(60)
                            Text("2 min").tag(120); Text("Never").tag(0)
                        }.labelsHidden().frame(width: 110)
                    }

                    SectionLabel(text: "Display")
                    toggle("Hide codes until hovered", "Shoulder-surfing protection.", isOn: $hideCodes)
                    toggle("Show next code", "Preview the upcoming code when the timer is nearly out.", isOn: $showNextCode)
                    toggle("Menu bar quick access", "Copy codes from the menu bar without opening the window.", isOn: $menuBar)
                    row("Sort", "Pinned accounts always stay on top.") {
                        Picker("", selection: $sortMode) {
                            ForEach(SortMode.allCases) { Text($0.label).tag($0.rawValue) }
                        }.labelsHidden().frame(width: 140)
                    }

                    SectionLabel(text: "Data")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Vault: ~/Library/Application Support/CipherDeck/vault.cdv")
                        Text("Encrypted with AES-256-GCM. The key lives in your login Keychain.")
                        Text("Make an encrypted backup (⇄ menu) after adding accounts.")
                    }
                    .font(CP.mono(10)).foregroundStyle(CP.dim)
                    Button("Reveal Vault in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppModel.vaultDirectory])
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.cyan, compact: true))

                    CreditFooter().frame(maxWidth: .infinity).padding(.top, 6)
                }
                .padding(.trailing, 6)
            }
            .frame(minHeight: 560, maxHeight: 640)
        }
        .alert("Turn off the app lock?", isPresented: $confirmDisableLock) {
            Button("Turn Off", role: .destructive) {
                Task {
                    if await Authenticator.authenticate(reason: "turn off the CipherDeck app lock") { appLock = false }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone using your unlocked Mac could then read your 2FA codes.")
        }
    }

    private func toggle(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        row(title, detail) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(CP.yellow)
        }
    }

    private func row<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(CP.mono(12, .semibold)).foregroundStyle(CP.text)
                Text(detail).font(CP.mono(10)).foregroundStyle(CP.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
    }
}
