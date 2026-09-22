#!/usr/bin/env swift
// Renders the CipherDeck logo (Cyberpunk 2077 style) procedurally with CoreGraphics.
// Usage: swift scripts/generate_icon.swift <output-dir>
// Produces <output-dir>/AppIcon.iconset/*.png and <output-dir>/logo.png (1024px).
// Run scripts/build_icon.sh to also produce AppIcon.icns.

import AppKit
import CoreGraphics

let yellow = CGColor(red: 0.988, green: 0.933, blue: 0.039, alpha: 1)   // #FCEE0A
let cyan = CGColor(red: 0.0, green: 0.941, blue: 1.0, alpha: 1)         // #00F0FF
let red = CGColor(red: 1.0, green: 0.0, blue: 0.235, alpha: 1)          // #FF003C

func color(_ c: CGColor, _ alpha: CGFloat) -> CGColor { c.copy(alpha: alpha)! }

/// Chamfered shield (cut corners) centred on (cx, cy).
func shieldPath(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let l = cx - w / 2, r = cx + w / 2, t = cy + h / 2, b = cy - h / 2
    let cut: CGFloat = w * 0.2
    p.move(to: CGPoint(x: l + cut, y: t))
    p.addLine(to: CGPoint(x: r, y: t))
    p.addLine(to: CGPoint(x: r, y: b + h * 0.36))
    p.addLine(to: CGPoint(x: cx + w * 0.16, y: b))
    p.addLine(to: CGPoint(x: cx - w * 0.16, y: b))
    p.addLine(to: CGPoint(x: l, y: b + h * 0.36))
    p.addLine(to: CGPoint(x: l, y: t - cut))
    p.closeSubpath()
    return p
}

/// Angular keyhole: octagon head + tapered slot.
func keyholePath(cx: CGFloat, cy: CGFloat, s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let r = s
    let k = r * 0.414
    let headY = cy + s * 0.55
    p.move(to: CGPoint(x: cx - k, y: headY + r))
    p.addLine(to: CGPoint(x: cx + k, y: headY + r))
    p.addLine(to: CGPoint(x: cx + r, y: headY + k))
    p.addLine(to: CGPoint(x: cx + r, y: headY - k))
    p.addLine(to: CGPoint(x: cx + r * 0.45, y: headY - r * 0.95))
    p.addLine(to: CGPoint(x: cx + r * 0.75, y: cy - s * 1.35))
    p.addLine(to: CGPoint(x: cx - r * 0.75, y: cy - s * 1.35))
    p.addLine(to: CGPoint(x: cx - r * 0.45, y: headY - r * 0.95))
    p.addLine(to: CGPoint(x: cx - r, y: headY - k))
    p.addLine(to: CGPoint(x: cx - r, y: headY + k))
    p.closeSubpath()
    return p
}

func drawEmblem(_ ctx: CGContext, dx: CGFloat, stroke: CGColor, fill: CGColor, glow: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: dx, y: 0)
    if glow > 0 { ctx.setShadow(offset: .zero, blur: glow, color: stroke) }
    ctx.setLineJoin(.miter)
    ctx.setLineWidth(30)
    ctx.setStrokeColor(stroke)
    ctx.addPath(shieldPath(cx: 512, cy: 545, w: 430, h: 480))
    ctx.strokePath()
    ctx.setFillColor(fill)
    ctx.addPath(keyholePath(cx: 512, cy: 545, s: 72))
    ctx.fillPath()
    ctx.restoreGState()
}

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    // macOS icon grid: 824pt body with continuous-ish corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.55))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(gray: 0.03, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Background gradient: deep night-city purple → black.
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.13, green: 0.05, blue: 0.20, alpha: 1),
        CGColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1),
        CGColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Perspective grid floor.
    ctx.setStrokeColor(color(cyan, 0.22))
    ctx.setLineWidth(2)
    let horizon: CGFloat = 330
    for i in 0..<9 {
        let t = CGFloat(i) / 8
        let y = horizon - (horizon - 100) * pow(t, 1.8)
        ctx.move(to: CGPoint(x: 100, y: y)); ctx.addLine(to: CGPoint(x: 924, y: y))
    }
    for i in -8...8 {
        ctx.move(to: CGPoint(x: 512 + CGFloat(i) * 22, y: horizon))
        ctx.addLine(to: CGPoint(x: 512 + CGFloat(i) * 150, y: 100))
    }
    ctx.strokePath()

    // Fade the grid into the horizon.
    let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1),
        CGColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: 512, y: horizon + 2), end: CGPoint(x: 512, y: horizon - 90), options: [])

    // Yellow hazard strip, top-left, CP2077 style.
    ctx.setFillColor(yellow)
    let strip = CGMutablePath()
    strip.move(to: CGPoint(x: 100, y: 780)); strip.addLine(to: CGPoint(x: 244, y: 924))
    strip.addLine(to: CGPoint(x: 300, y: 924)); strip.addLine(to: CGPoint(x: 100, y: 724))
    strip.closeSubpath()
    ctx.addPath(strip); ctx.fillPath()
    ctx.setFillColor(color(yellow, 0.35))
    let strip2 = CGMutablePath()
    strip2.move(to: CGPoint(x: 100, y: 690)); strip2.addLine(to: CGPoint(x: 334, y: 924))
    strip2.addLine(to: CGPoint(x: 352, y: 924)); strip2.addLine(to: CGPoint(x: 100, y: 672))
    strip2.closeSubpath()
    ctx.addPath(strip2); ctx.fillPath()

    // Emblem: chromatic aberration (red/cyan offsets) + glowing yellow core.
    ctx.setBlendMode(.screen)
    drawEmblem(ctx, dx: -12, stroke: color(red, 0.85), fill: color(red, 0.85), glow: 0)
    drawEmblem(ctx, dx: 12, stroke: color(cyan, 0.85), fill: color(cyan, 0.85), glow: 0)
    ctx.setBlendMode(.normal)
    drawEmblem(ctx, dx: 0, stroke: yellow, fill: yellow, glow: 40)

    // Glitch slices: displaced horizontal bands.
    let slices: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
        (668, 14, 34, color(cyan, 0.9)), (452, 9, -28, color(red, 0.9)),
        (392, 6, 44, color(yellow, 0.9)), (730, 5, -40, color(red, 0.7)),
    ]
    for (y, h, dx, c) in slices {
        ctx.setFillColor(c)
        ctx.fill(CGRect(x: 297 + dx, y: y, width: 430, height: h))
    }

    // OTP digit bar: ▮▮▮ ▮▮▮
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: cyan)
    ctx.setFillColor(cyan)
    let segW: CGFloat = 44, gap: CGFloat = 14, groupGap: CGFloat = 40, segY: CGFloat = 214
    let total = segW * 6 + gap * 4 + groupGap
    var x = 512 - total / 2
    for i in 0..<6 {
        let seg = CGMutablePath()
        seg.move(to: CGPoint(x: x + 8, y: segY + 22)); seg.addLine(to: CGPoint(x: x + segW, y: segY + 22))
        seg.addLine(to: CGPoint(x: x + segW - 8, y: segY)); seg.addLine(to: CGPoint(x: x, y: segY))
        seg.closeSubpath()
        ctx.addPath(seg); ctx.fillPath()
        x += segW + (i == 2 ? groupGap : gap)
    }
    ctx.restoreGState()

    // Scanlines.
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
    var sy: CGFloat = 100
    while sy < 924 { ctx.fill(CGRect(x: 100, y: sy, width: 824, height: 3)); sy += 8 }

    // Inner neon rim.
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    ctx.setStrokeColor(color(yellow, 0.35))
    ctx.setLineWidth(6)
    ctx.strokePath()

    return rep
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let data = render(size: px).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}
try render(size: 1024).representation(using: .png, properties: [:])!
    .write(to: outDir.appendingPathComponent("logo.png"))
print("Rendered icon set to \(iconset.path)")
