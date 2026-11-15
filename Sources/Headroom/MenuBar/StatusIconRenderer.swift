import AppKit

/// Draws the menu bar icon: one horizontal bar per provider, filled with the remaining quota of its
/// most constrained window. A template image so it matches the other menu bar icons, unless a bar
/// is critically low and is drawn in red.
enum StatusIconRenderer {
    private static let lowThreshold = 10.0
    private static let size: CGFloat = 18

    /// - Parameter remainingPercents: Remaining percent per provider; nil means no data.
    static func render(_ remainingPercents: [Double?]) -> NSImage {
        let bars: [Double?] = remainingPercents.isEmpty ? [nil] : Array(remainingPercents.prefix(3))
        let hasCritical = bars.contains { ($0 ?? 100) > 0 && ($0 ?? 100) <= lowThreshold }

        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // Resolved at draw time, so a colored icon still follows the menu bar appearance.
            let foreground = hasCritical ? NSColor.labelColor : NSColor.black
            let critical = NSColor.systemRed
            draw(bars, foreground: foreground, critical: critical)
            return true
        }
        image.isTemplate = !hasCritical
        image.accessibilityDescription = "Headroom"
        return image
    }

    private static func draw(_ bars: [Double?], foreground: NSColor, critical: NSColor) {
        let count = CGFloat(bars.count)
        // The same proportions as the Windows tray icon, in a slightly inset square.
        let box: CGFloat = 16
        let origin = (size - box) / 2
        let barHeight: CGFloat = switch bars.count {
        case 1: box * 0.34
        case 2: box * 0.27
        default: box * 0.2
        }
        let gap = barHeight * (bars.count == 2 ? 0.75 : 0.6)
        let total = count * barHeight + (count - 1) * gap
        let top = origin + (box - total) / 2
        let left = origin + box * 0.06
        let right = origin + box - box * 0.06

        for (index, remaining) in bars.enumerated() {
            let y = top + CGFloat(index) * (barHeight + gap)
            let track = NSRect(x: left, y: y, width: right - left, height: barHeight)
            let radius = barHeight / 2

            // Track.
            foreground.withAlphaComponent(remaining == nil ? 0.3 : 0.38).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            guard let value = remaining, value > 0 else {
                continue
            }

            // Fill proportional to remaining quota; keep at least a visible dot.
            let width = max((right - left) * min(value / 100, 1), barHeight * 0.9)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: left, y: y, width: width, height: barHeight).clip()
            (value <= lowThreshold ? critical : foreground).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
