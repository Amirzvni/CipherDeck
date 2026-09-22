import SwiftUI

/// Cyberpunk 2077 palette & type. Keep every color here — views never hardcode colors.
enum CP {
    static let bg = Color(hex: 0x07070D)
    static let bgTop = Color(hex: 0x140A1E)
    static let panel = Color(hex: 0x10101A)
    static let panelHi = Color(hex: 0x181826)
    static let yellow = Color(hex: 0xFCEE0A)
    static let cyan = Color(hex: 0x00F0FF)
    static let red = Color(hex: 0xFF003C)
    static let magenta = Color(hex: 0xFF2A6D)
    static let green = Color(hex: 0x39FF88)
    static let text = Color(hex: 0xE8E8F0)
    static let dim = Color(hex: 0x7C7C92)
    static let line = Color(hex: 0x2A2A3E)

    static let avatarPalette: [Color] = [yellow, cyan, magenta, green, Color(hex: 0xB026FF), Color(hex: 0xFF8A00)]

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func avatarColor(for string: String) -> Color {
        var hash: UInt32 = 5381
        for byte in string.lowercased().utf8 { hash = (hash &* 33) ^ UInt32(byte) }
        return avatarPalette[Int(hash % UInt32(avatarPalette.count))]
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Shapes

/// Rectangle with cut (chamfered) top-left and bottom-right corners — the signature CP2077 UI panel.
struct Chamfer: Shape {
    var cut: CGFloat = 12
    var topLeft = true
    var bottomRight = true
    var topRight = false
    var bottomLeft = false

    func path(in rect: CGRect) -> Path {
        let c = min(cut, rect.width / 3, rect.height / 3)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + (topLeft ? c : 0), y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - (topRight ? c : 0), y: rect.minY))
        if topRight { p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c)) }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - (bottomRight ? c : 0)))
        if bottomRight { p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY)) }
        p.addLine(to: CGPoint(x: rect.minX + (bottomLeft ? c : 0), y: rect.maxY))
        if bottomLeft { p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c)) }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + (topLeft ? c : 0)))
        if topLeft { p.addLine(to: CGPoint(x: rect.minX + c, y: rect.minY)) }
        p.closeSubpath()
        return p
    }
}

// MARK: - Modifiers & styles

struct CPPanel: ViewModifier {
    var stroke: Color = CP.line
    var fill: Color = CP.panel
    var cut: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(Chamfer(cut: cut).fill(fill))
            .overlay(Chamfer(cut: cut).stroke(stroke, lineWidth: 1))
    }
}

extension View {
    func cpPanel(stroke: Color = CP.line, fill: Color = CP.panel, cut: CGFloat = 12) -> some View {
        modifier(CPPanel(stroke: stroke, fill: fill, cut: cut))
    }

    func neonGlow(_ color: Color, radius: CGFloat = 6) -> some View {
        shadow(color: color.opacity(0.75), radius: radius)
    }
}

struct NeonButtonStyle: ButtonStyle {
    var color: Color = CP.yellow
    var filled = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CP.mono(compact ? 11 : 12, .bold))
            .tracking(1.5)
            .textCase(.uppercase)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .foregroundStyle(filled ? CP.bg : color)
            .background(Chamfer(cut: compact ? 6 : 9).fill(filled ? color : color.opacity(configuration.isPressed ? 0.25 : 0.08)))
            .overlay(Chamfer(cut: compact ? 6 : 9).stroke(color, lineWidth: 1))
            .shadow(color: color.opacity(configuration.isPressed ? 0.9 : 0.35), radius: configuration.isPressed ? 10 : 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    var color: Color = CP.cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 30, height: 28)
            .background(Chamfer(cut: 6).fill(color.opacity(configuration.isPressed ? 0.3 : 0.08)))
            .overlay(Chamfer(cut: 6).stroke(color.opacity(0.8), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Text field wrapped in a chamfered neon frame.
struct CPTextField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    var monospaced = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(CP.mono(10, .bold)).tracking(1.5).foregroundStyle(CP.cyan)
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(prompt).foregroundStyle(CP.dim))
                } else {
                    TextField("", text: $text, prompt: Text(prompt).foregroundStyle(CP.dim))
                }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? CP.mono(13) : .system(size: 13))
            .foregroundStyle(CP.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .cpPanel(stroke: CP.cyan.opacity(0.5), fill: CP.bg, cut: 7)
        }
    }
}

/// "// SECTION" label.
struct SectionLabel: View {
    let text: String
    var color: Color = CP.yellow

    var body: some View {
        HStack(spacing: 8) {
            Text("//").foregroundStyle(CP.red)
            Text(text.uppercased()).foregroundStyle(color)
            Rectangle().fill(color.opacity(0.3)).frame(height: 1)
        }
        .font(CP.mono(11, .bold))
        .tracking(2)
    }
}

// MARK: - Effects

/// Subtle CRT scanlines over everything.
struct Scanlines: View {
    var opacity: Double = 0.07

    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(opacity * 3)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

/// Title with chromatic aberration and an occasional glitch jitter.
struct GlitchText: View {
    let text: String
    var size: CGFloat = 22

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Glitch for ~0.25s every ~4s.
            let glitching = t.truncatingRemainder(dividingBy: 4.0) < 0.25
            let jitter: CGFloat = glitching ? CGFloat((Int(t * 50) % 5) - 2) * 1.5 : 0
            ZStack {
                label.foregroundStyle(CP.red.opacity(0.85)).offset(x: -1.5 + jitter, y: glitching ? 1 : 0)
                label.foregroundStyle(CP.cyan.opacity(0.85)).offset(x: 1.5 - jitter, y: glitching ? -1 : 0)
                label.foregroundStyle(CP.yellow).offset(x: glitching ? jitter * 0.5 : 0)
            }
            .compositingGroup()
            .neonGlow(CP.yellow, radius: 5)
        }
    }

    private var label: some View {
        Text(text).font(CP.mono(size, .heavy)).tracking(4).lineLimit(1).fixedSize()
    }
}

/// Background: dark gradient + faint grid.
struct CyberBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [CP.bgTop, CP.bg, CP.bg], startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                let step: CGFloat = 28
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(CP.cyan.opacity(0.025)))
                    x += step
                }
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(CP.cyan.opacity(0.025)))
                    y += step
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// "Created by Amir Rezvani with ❤️" — required on every main surface.
struct CreditFooter: View {
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Created by").foregroundStyle(CP.dim)
            Text("Amir Rezvani").foregroundStyle(CP.yellow).fontWeight(.bold)
            Text("with").foregroundStyle(CP.dim)
            Text("❤️")
        }
        .font(CP.mono(compact ? 10 : 11))
        .tracking(0.5)
    }
}
