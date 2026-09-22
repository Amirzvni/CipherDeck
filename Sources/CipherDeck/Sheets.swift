import AVFoundation
import CipherDeckCore
import SwiftUI
import UniformTypeIdentifiers

/// Common chrome for every sheet: title bar, close button, cyber background.
struct SheetFrame<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var width: CGFloat = 460
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(CP.mono(15, .heavy)).tracking(3).foregroundStyle(CP.yellow)
                        .neonGlow(CP.yellow, radius: 3)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(CP.mono(10)).foregroundStyle(CP.dim)
                    }
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(color: CP.red))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Rectangle().fill(LinearGradient(colors: [CP.yellow, CP.red.opacity(0.5), .clear],
                                            startPoint: .leading, endPoint: .trailing)).frame(height: 1)
            content().padding(18)
        }
        .frame(width: width)
        .tint(CP.yellow)
        .background(CyberBackground())
        .overlay(Scanlines())
    }
}

// MARK: - Manual entry

struct ManualEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var issuer = ""
    @State private var name = ""
    @State private var secret = ""
    @State private var kind = OTPKind.totp
    @State private var algorithm = OTPAlgorithm.sha1
    @State private var digits = 6
    @State private var period = 30
    @State private var counter = 0
    @State private var showAdvanced = false
    @State private var error: String?

    var body: some View {
        SheetFrame(title: "Enter setup key", subtitle: "Paste the key a website shows under “can't scan the QR code?”") {
            VStack(alignment: .leading, spacing: 14) {
                CPTextField(label: "SERVICE / ISSUER", text: $issuer, prompt: "GitHub", monospaced: false)
                CPTextField(label: "ACCOUNT", text: $name, prompt: "you@example.com", monospaced: false)
                CPTextField(label: "SECRET KEY", text: $secret, prompt: "JBSW Y3DP EHPK 3PXP  — or an otpauth:// link")

                HStack(spacing: 8) {
                    Button("Time based · TOTP") { kind = .totp }
                        .buttonStyle(NeonButtonStyle(color: CP.cyan, filled: kind == .totp, compact: true))
                    Button("Counter based · HOTP") { kind = .hotp }
                        .buttonStyle(NeonButtonStyle(color: CP.magenta, filled: kind == .hotp, compact: true))
                }

                DisclosureGroup(isExpanded: $showAdvanced) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("ALGORITHM").font(CP.mono(10, .bold)).foregroundStyle(CP.cyan)
                            Picker("", selection: $algorithm) {
                                ForEach(OTPAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 120)
                        }
                        GridRow {
                            Text("DIGITS").font(CP.mono(10, .bold)).foregroundStyle(CP.cyan)
                            Picker("", selection: $digits) {
                                ForEach(6...8, id: \.self) { Text("\($0)").tag($0) }
                            }.labelsHidden().frame(width: 120)
                        }
                        if kind == .totp {
                            GridRow {
                                Text("PERIOD").font(CP.mono(10, .bold)).foregroundStyle(CP.cyan)
                                Stepper("\(period) seconds", value: $period, in: 10...300, step: 5)
                                    .font(CP.mono(12))
                            }
                        } else {
                            GridRow {
                                Text("COUNTER").font(CP.mono(10, .bold)).foregroundStyle(CP.cyan)
                                TextField("", value: $counter, format: .number).frame(width: 120)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("ADVANCED").font(CP.mono(10, .bold)).tracking(1.5).foregroundStyle(CP.dim)
                }

                if let error {
                    Text(error).font(CP.mono(11, .bold)).foregroundStyle(CP.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(NeonButtonStyle(color: CP.dim))
                    Button("Add Account") { save() }
                        .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(secret.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth") {
            let result = ImportParser.parse(text: trimmed)
            guard !result.accounts.isEmpty else { error = result.errors.first ?? "Invalid link."; return }
            model.add(result.accounts)
            dismiss()
            return
        }
        guard let key = Base32.decode(trimmed) else {
            error = "That key isn't valid Base32 (letters A–Z and digits 2–7)."
            return
        }
        guard key.count >= 5 else {
            error = "That key is too short — double-check you copied all of it."
            return
        }
        guard !issuer.trimmingCharacters(in: .whitespaces).isEmpty || !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "Give the account a service or account name."
            return
        }
        let account = OTPAccount(issuer: issuer, name: name, secret: key, algorithm: algorithm,
                                 digits: digits, kind: kind, period: period, counter: UInt64(max(counter, 0)))
        model.add([account])
        dismiss()
    }
}

// MARK: - Camera scanning (incl. Google Authenticator transfer)

struct CameraScanSheet: View {
    let showGoogleGuide: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = CameraScanner()
    @State private var result = ImportResult()
    @State private var seenPayloads = Set<String>()
    @State private var lastMessage = ""

    var body: some View {
        SheetFrame(title: showGoogleGuide ? "Import from Google Authenticator" : "Scan QR code",
                   subtitle: showGoogleGuide ? "Transfer every account from your phone in one go" : "Hold the QR code up to your Mac's camera",
                   width: 560) {
            VStack(alignment: .leading, spacing: 14) {
                if showGoogleGuide { guide }

                ZStack {
                    switch scanner.state {
                    case .running, .idle:
                        CameraPreview(session: scanner.session)
                    case .denied:
                        cameraMessage("Camera access denied.\nEnable CipherDeck in System Settings › Privacy & Security › Camera — or use “Scan QR on Screen” with a screenshot instead.")
                    case .noCamera:
                        cameraMessage("No camera found.\nTake a screenshot of the QR code on your phone, AirDrop it to this Mac and drop it on the CipherDeck window.")
                    case .failed:
                        cameraMessage("The camera couldn't be started.")
                    }
                    Viewfinder()
                }
                .frame(height: 300)
                .clipShape(Chamfer(cut: 16))
                .overlay(Chamfer(cut: 16).stroke(CP.cyan.opacity(0.7), lineWidth: 1))

                HStack(spacing: 10) {
                    Image(systemName: result.accounts.isEmpty ? "dot.radiowaves.left.and.right" : "checkmark.seal.fill")
                        .foregroundStyle(result.accounts.isEmpty ? CP.cyan : CP.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.accounts.isEmpty ? "SCANNING…" : "\(result.accounts.count) ACCOUNT\(result.accounts.count == 1 ? "" : "S") CAPTURED")
                            .font(CP.mono(12, .bold)).tracking(1.5)
                            .foregroundStyle(result.accounts.isEmpty ? CP.cyan : CP.green)
                        if let hint = result.missingBatchHint {
                            Text(hint).font(CP.mono(10)).foregroundStyle(CP.yellow)
                        } else if !lastMessage.isEmpty {
                            Text(lastMessage).font(CP.mono(10)).foregroundStyle(CP.dim)
                        }
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(NeonButtonStyle(color: CP.dim))
                    Button("Review & Import") { finish() }
                        .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                        .disabled(result.accounts.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            scanner.onPayloads = handle
            if !AppModel.isDemo { scanner.start() }
        }
        .onDisappear { scanner.stop() }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "On your iPhone / Android")
            ForEach(Array([
                "Open Google Authenticator → tap ☰ (or ⋯) → Transfer accounts → Export accounts.",
                "Select the accounts to move, then tap Next.",
                "Hold the phone up to this Mac's camera. If Google shows several QR codes, scan each one (tap Next on the phone).",
                "No camera? Screenshot the QR on the phone, AirDrop it here and drop it on the main window.",
            ].enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("0\(i + 1)").font(CP.mono(10, .heavy)).foregroundStyle(CP.red)
                    Text(step).font(CP.mono(11)).foregroundStyle(CP.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func cameraMessage(_ text: String) -> some View {
        Text(text).font(CP.mono(12)).foregroundStyle(CP.text).multilineTextAlignment(.center)
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(CP.bg)
    }

    private func handle(_ payloads: [String]) {
        var changed = false
        for payload in payloads where seenPayloads.insert(payload).inserted {
            let parsed = ImportParser.parse(link: payload)
            if parsed.accounts.isEmpty {
                lastMessage = parsed.errors.first ?? "That QR code isn't a 2FA code."
                continue
            }
            result.merge(parsed)
            changed = true
            lastMessage = "+\(parsed.accounts.count) from last code"
        }
        guard changed else { return }
        NSSound(named: "Tink")?.play()
        // Single otpauth code, or a complete Google export → go straight to review.
        let migrationComplete = !result.migrationBatches.isEmpty && result.missingBatchHint == nil
        if result.migrationBatches.isEmpty && !showGoogleGuide && result.accounts.count == 1 { finish() }
        else if migrationComplete { finish() }
    }

    private func finish() {
        scanner.stop()
        let staged = result
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            model.stageImport(staged, source: showGoogleGuide ? "Google Authenticator" : "Camera")
        }
    }
}

struct Viewfinder: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.7
            let rect = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2, width: side, height: side)
            Path { p in
                let l: CGFloat = 26
                for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                          (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                          (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                          (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
                    p.move(to: CGPoint(x: corner.x + l * dx, y: corner.y))
                    p.addLine(to: corner)
                    p.addLine(to: CGPoint(x: corner.x, y: corner.y + l * dy))
                }
            }
            .stroke(CP.yellow, lineWidth: 3)
            .neonGlow(CP.yellow, radius: 6)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Import review

struct ImportReviewSheet: View {
    let pending: PendingImport
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(title: "Confirm import", subtitle: "Source: \(pending.source)", width: 480) {
            VStack(alignment: .leading, spacing: 12) {
                let existing = Set(model.accounts.map(\.dedupeKey))
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(pending.result.accounts.enumerated()), id: \.offset) { _, account in
                            HStack(spacing: 10) {
                                IssuerBadge(title: account.title, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.title.uppercased()).font(CP.mono(11, .bold)).foregroundStyle(CP.yellow)
                                    if !account.subtitle.isEmpty {
                                        Text(account.subtitle).font(CP.mono(10)).foregroundStyle(CP.dim)
                                    }
                                }
                                Spacer()
                                if existing.contains(account.dedupeKey) {
                                    Tag(text: "ALREADY ADDED", color: CP.dim)
                                } else {
                                    Tag(text: account.kind.rawValue.uppercased(), color: CP.cyan)
                                }
                            }
                            .padding(8)
                            .cpPanel(cut: 8)
                        }
                    }
                }
                .frame(maxHeight: 300)

                if let hint = pending.result.missingBatchHint {
                    Label(hint, systemImage: "exclamationmark.triangle").font(CP.mono(10, .bold)).foregroundStyle(CP.yellow)
                }
                if pending.result.skippedUnsupported > 0 {
                    Label("\(pending.result.skippedUnsupported) account(s) use an unsupported format and were skipped.",
                          systemImage: "exclamationmark.triangle").font(CP.mono(10)).foregroundStyle(CP.yellow)
                }
                ForEach(pending.result.errors.prefix(3), id: \.self) { error in
                    Label(error, systemImage: "xmark.octagon").font(CP.mono(10)).foregroundStyle(CP.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { model.pendingImport = nil; dismiss() }
                        .buttonStyle(NeonButtonStyle(color: CP.dim))
                    Button("Import \(pending.result.accounts.count)") {
                        model.confirmPendingImport()
                        dismiss()
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Edit

struct EditAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OTPAccount
    @State private var counterText: String

    init(account: OTPAccount) {
        _draft = State(initialValue: account)
        _counterText = State(initialValue: String(account.counter))
    }

    var body: some View {
        SheetFrame(title: "Edit account", subtitle: "Secrets can't be changed — re-add the account if the service gave you a new key") {
            VStack(alignment: .leading, spacing: 14) {
                CPTextField(label: "SERVICE / ISSUER", text: $draft.issuer, monospaced: false)
                CPTextField(label: "ACCOUNT", text: $draft.name, monospaced: false)
                CPTextField(label: "NOTE (ENCRYPTED)", text: $draft.note, prompt: "e.g. recovery codes are in the safe", monospaced: false)
                if draft.kind == .hotp {
                    CPTextField(label: "HOTP COUNTER", text: $counterText)
                }
                Toggle("Pin to top", isOn: $draft.pinned).font(CP.mono(12)).toggleStyle(.switch).tint(CP.yellow)
                Text("\(draft.kind.rawValue.uppercased()) · \(draft.algorithm.rawValue) · \(draft.digits) DIGITS\(draft.kind == .totp ? " · \(draft.period)S" : "")")
                    .font(CP.mono(10)).foregroundStyle(CP.dim)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(NeonButtonStyle(color: CP.dim))
                    Button("Save") {
                        if draft.kind == .hotp, let c = UInt64(counterText.trimmingCharacters(in: .whitespaces)) { draft.counter = c }
                        draft.issuer = draft.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.update(draft)
                        dismiss()
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Reveal a single account (QR + setup key), auth-gated

struct AccountQRSheet: View {
    let account: OTPAccount
    @State private var authorized = false
    @State private var failed = false

    var body: some View {
        SheetFrame(title: "Transfer \(account.title)", subtitle: "Scan with another authenticator. Anyone who sees this can clone your 2FA.", width: 420) {
            VStack(spacing: 14) {
                if authorized {
                    let uri = OTPAuthURI.build(account)
                    QRPanel(payload: uri)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SETUP KEY").font(CP.mono(10, .bold)).foregroundStyle(CP.cyan)
                        Text(Base32.encode(account.secret).chunked(4))
                            .font(CP.mono(13, .semibold)).foregroundStyle(CP.text).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).cpPanel(cut: 8)
                } else {
                    AuthGate(failed: failed) { await authorize() }
                }
            }
        }
        .task { await authorize() }
    }

    private func authorize() async {
        authorized = await Authenticator.authenticate(reason: "reveal the secret for \(account.title)")
        failed = !authorized
    }
}

struct AuthGate: View {
    var failed: Bool
    var action: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(CP.red)
            Text(failed ? "AUTHENTICATION FAILED" : "AUTHENTICATION REQUIRED")
                .font(CP.mono(12, .bold)).tracking(2).foregroundStyle(failed ? CP.red : CP.yellow)
            Button("Authenticate") { Task { await action() } }
                .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

struct QRPanel: View {
    let payload: String
    var size: CGFloat = 260

    var body: some View {
        Group {
            if let image = QRCode.image(for: payload, size: size) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
                    .padding(14)
                    .background(Color.white)
            } else {
                Text("QR generation failed").foregroundStyle(CP.red)
            }
        }
        .clipShape(Chamfer(cut: 14))
        .overlay(Chamfer(cut: 14).stroke(CP.yellow, lineWidth: 2))
        .neonGlow(CP.yellow, radius: 8)
    }
}

extension String {
    func chunked(_ n: Int) -> String {
        stride(from: 0, to: count, by: n).map { i -> String in
            let start = index(startIndex, offsetBy: i)
            let end = index(start, offsetBy: n, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }.joined(separator: " ")
    }
}

// MARK: - Export to Google Authenticator

struct GoogleExportSheet: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Set<UUID>()
    @State private var authorized = false
    @State private var failed = false
    @State private var codes: [String] = []
    @State private var page = 0
    @State private var skipped: [OTPAccount] = []

    var body: some View {
        SheetFrame(title: "Export to Google Authenticator",
                   subtitle: "Google Authenticator → + → Scan a QR code. Keep this screen private.", width: 480) {
            VStack(spacing: 14) {
                if !authorized {
                    AuthGate(failed: failed) { await authorize() }
                } else if codes.isEmpty {
                    selection
                } else {
                    qrPages
                }
            }
        }
        .task { await authorize() }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Select accounts")
                Button(selected.count == model.accounts.count ? "None" : "All") {
                    selected = selected.count == model.accounts.count ? [] : Set(model.accounts.map(\.id))
                }
                .buttonStyle(NeonButtonStyle(color: CP.cyan, compact: true))
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.accounts) { account in
                        Toggle(isOn: Binding(get: { selected.contains(account.id) },
                                             set: { if $0 { selected.insert(account.id) } else { selected.remove(account.id) } })) {
                            HStack {
                                Text(account.title).font(CP.mono(12, .bold)).foregroundStyle(CP.yellow)
                                Text(account.subtitle).font(CP.mono(11)).foregroundStyle(CP.dim)
                                if !GoogleMigration.isExportable(account) { Tag(text: "NOT SUPPORTED BY GOOGLE", color: CP.red) }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("Generate QR Codes") {
                    let chosen = model.accounts.filter { selected.contains($0.id) }
                    let encoded = GoogleMigration.encode(chosen)
                    codes = encoded.uris
                    skipped = encoded.unsupported
                    page = 0
                }
                .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                .disabled(selected.isEmpty)
            }
        }
        .onAppear { if selected.isEmpty { selected = Set(model.accounts.map(\.id)) } }
    }

    private var qrPages: some View {
        VStack(spacing: 14) {
            QRPanel(payload: codes[page], size: 280)
            Text("QR \(page + 1) OF \(codes.count)").font(CP.mono(12, .bold)).tracking(2).foregroundStyle(CP.cyan)
            if !skipped.isEmpty {
                Text("\(skipped.count) account(s) skipped: Google Authenticator only supports 30-second, 6/8-digit codes.")
                    .font(CP.mono(10)).foregroundStyle(CP.yellow).multilineTextAlignment(.center)
            }
            HStack {
                Button("Back") { page -= 1 }.buttonStyle(NeonButtonStyle(color: CP.cyan)).disabled(page == 0)
                Spacer()
                Button(page == codes.count - 1 ? "Start Over" : "Next") {
                    if page == codes.count - 1 { codes = [] } else { page += 1 }
                }
                .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
            }
        }
    }

    private func authorize() async {
        authorized = await Authenticator.authenticate(reason: "export your 2FA accounts")
        failed = !authorized
    }
}

// MARK: - Encrypted backups

struct BackupExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false

    private var problem: String? {
        if password.count < EncryptedBackup.minimumPasswordLength { return "At least \(EncryptedBackup.minimumPasswordLength) characters." }
        if password != confirm { return "Passwords don't match." }
        return nil
    }

    var body: some View {
        SheetFrame(title: "Encrypted backup", subtitle: "AES-256-GCM · PBKDF2-SHA256 × 600,000. Without this password the file is useless — to you and to thieves.") {
            VStack(alignment: .leading, spacing: 14) {
                CPTextField(label: "BACKUP PASSWORD", text: $password, secure: true)
                CPTextField(label: "CONFIRM PASSWORD", text: $confirm, secure: true)
                if let problem, !password.isEmpty {
                    Text(problem).font(CP.mono(10)).foregroundStyle(CP.red)
                }
                Text("Store the file somewhere safe (USB drive, cloud storage). You can restore it on any Mac running CipherDeck.")
                    .font(CP.mono(10)).foregroundStyle(CP.dim)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(NeonButtonStyle(color: CP.dim))
                    Button(working ? "Encrypting…" : "Save Backup…") { save() }
                        .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                        .disabled(problem != nil || working)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "CipherDeck-\(day).\(EncryptedBackup.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task {
            await model.exportBackup(to: url, password: password)
            working = false
            dismiss()
        }
    }
}

struct BackupImportSheet: View {
    let url: URL
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        SheetFrame(title: "Restore backup", subtitle: url.lastPathComponent) {
            VStack(alignment: .leading, spacing: 14) {
                CPTextField(label: "BACKUP PASSWORD", text: $password, secure: true)
                if let error { Text(error).font(CP.mono(10, .bold)).foregroundStyle(CP.red) }
                Text("Accounts are added to your vault; existing ones are kept and duplicates skipped.")
                    .font(CP.mono(10)).foregroundStyle(CP.dim)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(NeonButtonStyle(color: CP.dim))
                    Button(working ? "Decrypting…" : "Decrypt") {
                        working = true
                        Task {
                            do {
                                let accounts = try await model.decryptBackup(url, password: password)
                                dismiss()
                                try? await Task.sleep(for: .milliseconds(350))
                                var result = ImportResult()
                                result.accounts = accounts
                                model.stageImport(result, source: "Backup · \(url.lastPathComponent)")
                            } catch {
                                self.error = error.localizedDescription
                            }
                            working = false
                        }
                    }
                    .buttonStyle(NeonButtonStyle(color: CP.yellow, filled: true))
                    .disabled(password.isEmpty || working)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
