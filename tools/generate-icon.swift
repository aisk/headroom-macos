// Generates the app icon in the macOS style: a small guitar amp on the standard rounded-square
// plate, whose blue grille shows three level bars (the quota "headroom" left).
// Writes Sources/Headroom/Resources/AppIcon.icns.
// Usage: swift tools/generate-icon.swift [output.icns]

import AppKit
import CoreGraphics
import Foundation

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/Headroom/Resources/AppIcon.icns"

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    let data = try renderPNG(pixels: entry.pixels)
    try data.write(to: iconset.appendingPathComponent("\(entry.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
print("Wrote \(output)")

// MARK: - Drawing

func renderPNG(pixels: Int) throws -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        fatalError("Could not create a bitmap context")
    }

    // Draw on a 1024-point canvas with a top-left origin.
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    drawIcon(context, small: pixels <= 32)

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func fillGradient(_ context: CGContext, _ path: CGPath, _ rect: CGRect, top: CGColor, bottom: CGColor) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    context.restoreGState()
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    let r = min(radius, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func drawIcon(_ context: CGContext, small: Bool) {
    // The standard macOS icon grid: an 824-point plate centered on the 1024-point canvas.
    let plate = small ? CGRect(x: 64, y: 64, width: 896, height: 896) : CGRect(x: 100, y: 100, width: 824, height: 824)
    let plateRadius = plate.width * 0.225
    let platePath = roundedRect(plate, plateRadius)

    // Soft drop shadow under the plate (the canvas is flipped, so a positive y offset points down).
    if !small {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, alpha: 0.35))
        context.addPath(platePath)
        context.setFillColor(color(0x2E3036))
        context.fillPath()
        context.restoreGState()
    }

    // Amp body.
    fillGradient(context, platePath, plate, top: color(0x4A4D55), bottom: color(0x1E2025))

    // A subtle light edge keeps the dark body readable on dark backgrounds.
    context.saveGState()
    context.addPath(roundedRect(plate.insetBy(dx: 2, dy: 2), plateRadius - 2))
    context.setStrokeColor(color(0xFFFFFF, alpha: small ? 0.18 : 0.22))
    context.setLineWidth(small ? 16 : 4)
    context.strokePath()
    context.restoreGState()

    let pad = plate.width * (small ? 0.12 : 0.085)
    var grilleTop = plate.minY + pad

    if !small {
        // Control panel with knobs.
        let panel = CGRect(x: plate.minX + pad, y: plate.minY + pad, width: plate.width - 2 * pad, height: plate.height * 0.19)
        fillGradient(context, roundedRect(panel, panel.height * 0.32), panel, top: color(0xF3F1EC), bottom: color(0xC6C3BB))
        grilleTop = panel.maxY + pad * 0.6

        let knobCount = 4
        let knob = panel.height * 0.62
        let spacing = panel.width / CGFloat(knobCount)
        for i in 0..<knobCount {
            let center = CGPoint(x: panel.minX + spacing * (CGFloat(i) + 0.5), y: panel.midY)
            let knobRect = CGRect(x: center.x - knob / 2, y: center.y - knob / 2, width: knob, height: knob)
            fillGradient(context, CGPath(ellipseIn: knobRect, transform: nil), knobRect, top: color(0x3A3C42), bottom: color(0x141518))

            // Pointer ticks at different angles, so they read as amp controls rather than window buttons.
            let angle = CGFloat(-140 + i * 60) * .pi / 180
            context.saveGState()
            context.setStrokeColor(color(0xFFFFFF))
            context.setLineWidth(knob * 0.13)
            context.setLineCap(.round)
            context.move(to: center)
            context.addLine(to: CGPoint(x: center.x + cos(angle) * knob * 0.36, y: center.y + sin(angle) * knob * 0.36))
            context.strokePath()
            context.restoreGState()
        }
    }

    // Grille: a blue gradient holding the level bars.
    let grille = CGRect(x: plate.minX + pad, y: grilleTop, width: plate.width - 2 * pad, height: plate.maxY - pad - grilleTop)
    fillGradient(context, roundedRect(grille, plateRadius * 0.45), grille, top: color(0x2998F0), bottom: color(0x0F5FC2))

    // Three level bars: full, two thirds, one third. The empty part is the headroom.
    let levels: [CGFloat] = [1.0, 0.66, 0.36]
    let inner = grille.width * (small ? 0.13 : 0.12)
    let barHeight = grille.height * (small ? 0.19 : 0.15)
    let gap = grille.height * 0.12
    let total = 3 * barHeight + 2 * gap
    let top = grille.minY + (grille.height - total) / 2
    let width = grille.width - 2 * inner
    for (index, level) in levels.enumerated() {
        let y = top + CGFloat(index) * (barHeight + gap)
        let track = CGRect(x: grille.minX + inner, y: y, width: width, height: barHeight)
        context.addPath(roundedRect(track, barHeight / 2))
        context.setFillColor(color(0xFFFFFF, alpha: 0.3))
        context.fillPath()

        let fill = CGRect(x: track.minX, y: y, width: max(barHeight, width * level), height: barHeight)
        context.addPath(roundedRect(fill, barHeight / 2))
        context.setFillColor(color(0xFFFFFF))
        context.fillPath()
    }
}
