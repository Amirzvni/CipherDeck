import CipherDeckCore
import SwiftUI
import UniformTypeIdentifiers

enum ActiveSheet: Identifiable {
    case manual
    case camera(googleGuide: Bool)
    case edit(OTPAccount)
    case showQR(OTPAccount)
    case exportGoogle
    case backupExport
    case backupImport(URL)
    case settings

    var id: String {
        switch self {
        case .manual: return "manual"
        case .camera(let g): return "camera-\(g)"
        case .edit(let a): return "edit-\(a.id)"
        case .showQR(let a): return "qr-\(a.id)"
        case .exportGoogle: return "export-google"
        case .backupExport: return "backup-export"
        case .backupImport(let u): return "backup-import-\(u.path)"
        case .settings: return "settings"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.sortMode) private var sortMode = SortMode.manual.rawValue
    @State private var sheet: ActiveSheet?
    @State private var pendingDelete: OTPAccount?
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            CyberBackground()
            VStack(spacing: 0) {
                HeaderBar(sheet: $sheet, onScanScreen: scanScreen, onOpenFile: openFile)
                switch model.state {
                case .ready:
                    vaultView
                case .locked:
                    LockView()
                case .keyMissing:
                    VaultProblemView(keyMissing: true, message: "")
                case .failed(let message):
                    VaultProblemView(keyMissing: false, message: message)
                }
                FooterBar()
            }
            .ignoresSafeArea(edges: .top)
            Scanlines().ignoresSafeArea()
            if dropTargeted { DropOverlay() }
            ToastOverlay()
        }
        .frame(minWidth: 460, minHeight: 540)
        .tint(CP.yellow)
        .preferredColorScheme(.dark)
        .protectedFromCapture()
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: handleDrop)
        .sheet(item: $sheet) { sheet in
            sheetView(sheet)
                .preferredColorScheme(.dark)
                .protectedFromCapture()
        }
        .sheet(item: Binding(get: { model.pendingImport }, set: { model.pendingImport = $0 })) { pending in
            ImportReviewSheet(pending: pending)
                .preferredColorScheme(.dark)
                .protectedFromCapture()
        }
        .alert("Delete \(pendingDelete?.title ?? "account")?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { account in
            Button("Delete", role: .destructive) { model.delete(account.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the account from CipherDeck. Make sure you have turned off 2FA or have another way to sign in — deleted secrets can't be recovered.")
        }
        .onAppear {
            switch AppModel.demoScreen {
            case "settings": sheet = .settings
            case "google": sheet = .camera(googleGuide: true)
            case "export": sheet = .exportGoogle
            case "manual": sheet = .manual
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cipherDeckCommand)) { note in
            guard let command = note.object as? AppCommand else { return }
            handle(command)
        }
    }

    // MARK: Vault list

    private var vaultView: some View {
        VStack(spacing: 10) {
            SearchBar(text: Bindable(model).searchText, focused: $searchFocused,
                      count: model.visibleAccounts.count, onSubmit: model.copyTopMatch)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            if model.accounts.isEmpty {
                EmptyVaultView(sheet: $sheet, onScanScreen: scanScreen, onOpenFile: openFile)
            } else if model.visibleAccounts.isEmpty {
                Spacer()
                Text("NO MATCH FOR \u{201C}\(model.searchText.uppercased())\u{201D}")
                    .font(CP.mono(12, .bold)).tracking(2).foregroundStyle(CP.dim)
                Spacer()
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    List {
                        ForEach(Array(model.visibleAccounts.enumerated()), id: \.element.id) { index, account in
                            AccountRow(
                                account: account, index: index, now: context.date,
                                onCopy: { model.copyCode(for: account) },
                                onCopyNext: { model.copyCode(for: account, next: true) },
                                onAdvance: { model.advanceCounter(account.id) },
                                onEdit: { sheet = .edit(account) },
                                onShowQR: { sheet = .showQR(account) },
                                onPin: { model.togglePin(account.id) },
                                onDelete: { pendingDelete = account }
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                        .onMove(perform: model.canReorder ? { model.move(from: $0, to: $1) } : nil)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 10)
                }
                .id(sortMode)
            }
        }
        .background(copyShortcuts)
    }

    /// Hidden buttons for ⌘1…⌘9.
    private var copyShortcuts: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { i in
                Button("") { model.copy(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .manual: ManualEntrySheet()
        case .camera(let guide): CameraScanSheet(showGoogleGuide: guide)
        case .edit(let account): EditAccountSheet(account: account)
        case .showQR(let account): AccountQRSheet(account: account)
        case .exportGoogle: GoogleExportSheet()
        case .backupExport: BackupExportSheet()
        case .backupImport(let url): BackupImportSheet(url: url)
        case .settings: SettingsView(inSheet: true)
        }
    }

    // MARK: Actions

    private func handle(_ command: AppCommand) {
        switch command {
        case .add: if model.isUnlocked { sheet = .manual }
        case .scanCamera: if model.isUnlocked { sheet = .camera(googleGuide: false) }
        case .scanScreen: scanScreen()
        case .importFile: openFile()
        case .importGoogle: if model.isUnlocked { sheet = .camera(googleGuide: true) }
        case .exportGoogle: if model.isUnlocked { sheet = .exportGoogle }
        case .exportBackup: if model.isUnlocked { sheet = .backupExport }
        case .paste: if model.isUnlocked { model.pasteFromClipboard() }
        case .find: searchFocused = true
        case .lock: model.lock()
        case .settings: sheet = .settings
        }
    }

    private func scanScreen() {
        guard model.isUnlocked else { return }
        Task {
            switch await ScreenQRScanner.scan() {
            case .payloads(let payloads): model.stagePayloads(payloads, source: "Screen")
            case .cancelled: break
            case .nothingFound:
                model.showToast("No QR code found. First time? Allow CipherDeck in System Settings › Privacy & Security › Screen Recording.", .error)
            }
        }
    }

    private func openFile() {
        guard model.isUnlocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .plainText, .text, .json,
                                     UTType(filenameExtension: EncryptedBackup.fileExtension) ?? .data, .data]
        panel.message = "Choose a QR code image, a text file of otpauth:// links, or a CipherDeck backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.importFile(url) { sheet = .backupImport(url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.isUnlocked else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if model.importFile(url) { sheet = .backupImport(url) }
                    }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    let payloads = QRCode.decode(image)
                    Task { @MainActor in
                        if payloads.isEmpty { model.showToast("No QR code found in the dropped image.", .error) }
                        else { model.stagePayloads(payloads, source: "Dropped image") }
                    }
                }
                return true
            }
        }
        return false
    }
}

// MARK: - Header / footer / search

struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: ActiveSheet?
    var onScanScreen: () -> Void
    var onOpenFile: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                GlitchText(text: "CIPHERDECK", size: 19)
                Text("NETRUNNER 2FA // ENCRYPTED")
                    .font(CP.mono(8, .medium)).tracking(2).foregroundStyle(CP.dim)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            if model.isUnlocked {
                Menu {
                    Button("Scan QR with Camera…") { sheet = .camera(googleGuide: false) }
                    Button("Scan QR on Screen…") { onScanScreen() }
                    Button("Import QR Image or File…") { onOpenFile() }
                    Button("Paste Link or QR Image") { model.pasteFromClipboard() }
                    Divider()
                    Button("Enter Setup Key…") { sheet = .manual }
                } label: {
                    Label("ADD", systemImage: "plus")
                        .font(CP.mono(11, .bold))
                }
                .menuStyle(.button)
                .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true, compact: true))
                .fixedSize()
                .help("Add account")

                Menu {
                    Section("Google Authenticator") {
                        Button("Import from Google Authenticator…") { sheet = .camera(googleGuide: true) }
                        Button("Export to Google Authenticator…") { sheet = .exportGoogle }
                    }
                    Section("Encrypted Backup") {
                        Button("Export Encrypted Backup…") { sheet = .backupExport }
                        Button("Restore from Backup File…") { onOpenFile() }
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .menuStyle(.button)
                .buttonStyle(IconButtonStyle(color: CP.cyan))
                .fixedSize()
                .help("Transfer accounts")

                Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                    .buttonStyle(IconButtonStyle(color: CP.cyan))
                    .help("Settings")

                if UserDefaults.standard.bool(forKey: SettingsKey.appLock) {
                    Button { model.lock() } label: { Image(systemName: "lock.fill") }
                        .buttonStyle(IconButtonStyle(color: CP.red))
                        .help("Lock (⌘L)")
                }
            }
        }
        .padding(.leading, 78) // room for traffic lights
        .padding(.trailing, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(colors: [CP.yellow, CP.red.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
        )
    }
}

struct SearchBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let count: Int
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(">").font(CP.mono(13, .bold)).foregroundStyle(CP.yellow)
            TextField("", text: $text, prompt: Text("SEARCH_").foregroundStyle(CP.dim))
                .textFieldStyle(.plain)
                .font(CP.mono(13))
                .foregroundStyle(CP.text)
                .focused(focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(CP.dim)
            }
            Text("\(count) ID\(count == 1 ? "" : "S")")
                .font(CP.mono(10, .bold)).tracking(1).foregroundStyle(CP.dim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cpPanel(stroke: focused.wrappedValue ? CP.yellow.opacity(0.8) : CP.line, fill: CP.bg.opacity(0.7), cut: 9)
        .help("Type to filter · Return copies the top result")
    }
}

struct FooterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            LinearGradient(colors: [.clear, CP.cyan.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(model.isUnlocked ? CP.green : CP.red).frame(width: 6, height: 6)
                        .neonGlow(model.isUnlocked ? CP.green : CP.red, radius: 3)
                    Text(model.isUnlocked ? "AES-256 · OFFLINE" : "LOCKED")
                        .font(CP.mono(9, .bold)).tracking(1.5).foregroundStyle(CP.dim)
                }
                Spacer()
                CreditFooter()
                Spacer()
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(CP.mono(9)).foregroundStyle(CP.dim)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - States

struct EmptyVaultView: View {
    @Binding var sheet: ActiveSheet?
    var onScanScreen: () -> Void
    var onOpenFile: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 20)
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 54, weight: .thin))
                    .foregroundStyle(CP.cyan)
                    .neonGlow(CP.cyan, radius: 8)
                Text("NO IDENTITIES LOADED")
                    .font(CP.mono(15, .heavy)).tracking(3).foregroundStyle(CP.yellow)
                Text("Jack in your first 2FA account.")
                    .font(CP.mono(12)).foregroundStyle(CP.dim)

                VStack(spacing: 10) {
                    Button { sheet = .camera(googleGuide: true) } label: {
                        Label("Import from Google Authenticator", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                    Button { onScanScreen() } label: {
                        Label("Scan QR on Screen", systemImage: "viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.cyan))
                    Button { sheet = .camera(googleGuide: false) } label: {
                        Label("Scan QR with Camera", systemImage: "camera").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.cyan))
                    Button { sheet = .manual } label: {
                        Label("Enter Setup Key", systemImage: "keyboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.cyan))
                    Button { onOpenFile() } label: {
                        Label("Import Image / File / Backup", systemImage: "doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.magenta))
                }
                .frame(maxWidth: 320)

                Text("TIP: drag a QR screenshot onto this window, or press ⌘V.")
                    .font(CP.mono(10)).foregroundStyle(CP.dim)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
        }
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Chamfer(cut: 18).stroke(CP.red, lineWidth: 2).frame(width: 110, height: 110)
                    .neonGlow(CP.red, radius: 10)
                Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(CP.red)
            }
            GlitchText(text: "ACCESS RESTRICTED", size: 20)
            Text("VAULT ENCRYPTED // AUTHENTICATE TO DECRYPT")
                .font(CP.mono(10, .medium)).tracking(2).foregroundStyle(CP.dim)
            Button {
                Task { await model.unlock() }
            } label: {
                Label("Unlock with \(Authenticator.biometryName)", systemImage: "touchid")
            }
            .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.unlock() }
    }
}

struct VaultProblemView: View {
    @Environment(AppModel.self) private var model
    let keyMissing: Bool
    let message: String
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.octagon").font(.system(size: 48)).foregroundStyle(CP.red)
                .neonGlow(CP.red, radius: 8)
            Text(keyMissing ? "VAULT KEY NOT FOUND" : "VAULT ERROR")
                .font(CP.mono(16, .heavy)).tracking(3).foregroundStyle(CP.red)
            Text(keyMissing
                 ? "Your encrypted vault exists, but its key is missing from the Keychain (or access was denied). Nothing has been changed or deleted."
                 : message)
                .font(CP.mono(12)).foregroundStyle(CP.text).multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("Try Again") { model.retryOpen() }
                    .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                if keyMissing {
                    Button("Archive & Start Fresh") { confirmReset = true }
                        .buttonStyle(NeonButtonStyle(color: CP.red))
                }
            }
            Text("Tip: if macOS asked for Keychain access and you clicked Deny, click Try Again and choose Always Allow.")
                .font(CP.mono(10)).foregroundStyle(CP.dim).multilineTextAlignment(.center).frame(maxWidth: 380)
            Spacer()
        }
        .padding()
        .alert("Start a fresh vault?", isPresented: $confirmReset) {
            Button("Archive & Start Fresh", role: .destructive) { model.archiveUnreadableVaultAndStartFresh() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The unreadable vault is kept (renamed) in ~/Library/Application Support/CipherDeck. You can then restore accounts from an encrypted backup.")
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            CP.bg.opacity(0.8)
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 40)).foregroundStyle(CP.yellow)
                Text("DROP QR IMAGE / FILE").font(CP.mono(14, .heavy)).tracking(3).foregroundStyle(CP.yellow)
            }
        }
        .overlay(Chamfer(cut: 20).stroke(CP.yellow, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(12))
        .allowsHitTesting(false)
    }
}

struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer()
            if let toast = model.toast {
                let color: Color = toast.kind == .error ? CP.red : (toast.kind == .info ? CP.cyan : CP.green)
                HStack(spacing: 8) {
                    Image(systemName: toast.kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(toast.message).multilineTextAlignment(.leading)
                }
                .font(CP.mono(11, .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .cpPanel(stroke: color, fill: CP.bg.opacity(0.95), cut: 8)
                .neonGlow(color, radius: 6)
                .padding(.horizontal, 24)
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .allowsHitTesting(false)
    }
}
