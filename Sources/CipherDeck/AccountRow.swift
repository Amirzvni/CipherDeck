import CipherDeckCore
import SwiftUI

/// Circular countdown for TOTP codes. Turns red in the last 5 seconds.
struct CountdownRing: View {
    let period: Int
    var size: CGFloat = 34

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
            let remaining = OTPGenerator.secondsRemaining(at: context.date, period: period)
            let fraction = remaining / Double(period)
            let urgent = remaining <= 5
            let color = urgent ? CP.red : CP.cyan
            ZStack {
                Circle().stroke(CP.line, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .neonGlow(color, radius: 3)
                Text("\(Int(remaining.rounded(.up)))")
                    .font(CP.mono(size * 0.33, .bold))
                    .foregroundStyle(urgent ? CP.red : CP.text)
            }
            .frame(width: size, height: size)
        }
    }
}

/// Letter badge for an issuer.
struct IssuerBadge: View {
    let title: String
    var size: CGFloat = 40

    var body: some View {
        let color = CP.avatarColor(for: title)
        Text(String(title.first.map(String.init) ?? "?").uppercased())
            .font(CP.mono(size * 0.45, .heavy))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Chamfer(cut: size * 0.25).fill(color.opacity(0.12)))
            .overlay(Chamfer(cut: size * 0.25).stroke(color.opacity(0.9), lineWidth: 1.2))
            .neonGlow(color, radius: 3)
    }
}

struct AccountRow: View {
    let account: OTPAccount
    let index: Int
    let now: Date
    var onCopy: () -> Void
    var onCopyNext: () -> Void
    var onAdvance: () -> Void
    var onEdit: () -> Void
    var onShowQR: () -> Void
    var onPin: () -> Void
    var onDelete: () -> Void

    @AppStorage(SettingsKey.hideCodes) private var hideCodes = false
    @AppStorage(SettingsKey.showNextCode) private var showNextCode = true
    @State private var hovering = false
    @State private var flash = false

    var body: some View {
        let code = account.code(at: now)
        let reveal = !hideCodes || hovering
        let remaining = OTPGenerator.secondsRemaining(at: now, period: account.period)
        let accent = CP.avatarColor(for: account.title)

        HStack(spacing: 14) {
            IssuerBadge(title: account.title)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.title.uppercased())
                        .font(CP.mono(12, .bold))
                        .tracking(1.5)
                        .foregroundStyle(CP.yellow)
                        .lineLimit(1)
                    if account.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(CP.magenta)
                    }
                    if account.kind == .hotp {
                        Tag(text: "HOTP", color: CP.magenta)
                    }
                    if account.algorithm != .sha1 || account.digits != 6 || (account.kind == .totp && account.period != 30) {
                        Tag(text: specs, color: CP.dim)
                    }
                }
                if !account.subtitle.isEmpty {
                    Text(account.subtitle)
                        .font(CP.mono(11))
                        .foregroundStyle(CP.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ZStack(alignment: .leading) {
                        Text(reveal ? code.groupedCode : String(repeating: "•", count: account.digits).groupedCode)
                            .font(CP.mono(28, .semibold))
                            .foregroundStyle(account.kind == .totp && remaining <= 5 ? CP.red : CP.cyan)
                            .neonGlow(account.kind == .totp && remaining <= 5 ? CP.red : CP.cyan, radius: 4)
                            .opacity(flash ? 0 : 1)
                        if flash {
                            Text("COPIED ✓")
                                .font(CP.mono(20, .heavy))
                                .tracking(3)
                                .foregroundStyle(CP.green)
                                .neonGlow(CP.green, radius: 5)
                                .transition(.opacity)
                        }
                    }
                    .monospacedDigit()
                    if showNextCode && reveal && !flash {
                        Text("NEXT \(account.nextCode(at: now).groupedCode)")
                            .font(CP.mono(10, .medium))
                            .foregroundStyle(CP.dim)
                    }
                }
            }

            Spacer(minLength: 8)

            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(CP.mono(9))
                    .foregroundStyle(CP.dim.opacity(hovering ? 1 : 0))
            }

            switch account.kind {
            case .totp:
                CountdownRing(period: account.period)
            case .hotp:
                Button(action: onAdvance) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(color: CP.magenta))
                .help("Generate next HOTP code")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Chamfer(cut: 14)
                .fill(hovering ? CP.panelHi : CP.panel)
        )
        .overlay(
            Chamfer(cut: 14)
                .stroke(hovering ? accent.opacity(0.9) : CP.line, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 3).padding(.vertical, 14).opacity(hovering ? 1 : 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { copy() }
        .help("Click to copy code")
        .contextMenu {
            Button("Copy Code") { copy() }
            Button("Copy Next Code") { onCopyNext() }
            if account.kind == .hotp { Button("Next HOTP Code") { onAdvance() } }
            Divider()
            Button(account.pinned ? "Unpin" : "Pin to Top") { onPin() }
            Button("Edit…") { onEdit() }
            Button("Show QR / Setup Key…") { onShowQR() }
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
        }
    }

    private var specs: String {
        var parts = [account.algorithm.rawValue, "\(account.digits)D"]
        if account.kind == .totp { parts.append("\(account.period)S") }
        return parts.joined(separator: "·")
    }

    private func copy() {
        onCopy()
        withAnimation(.easeOut(duration: 0.12)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeIn(duration: 0.2)) { flash = false }
        }
    }
}

struct Tag: View {
    let text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(CP.mono(8, .bold))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(Chamfer(cut: 3).stroke(color.opacity(0.7), lineWidth: 1))
    }
}
