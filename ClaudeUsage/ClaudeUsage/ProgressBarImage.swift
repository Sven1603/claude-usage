import AppKit

/// Renders a compact horizontal progress bar as a template-friendly NSImage
/// for the menu bar label. Color reflects the usage threshold.
enum ProgressBarImage {
    static func make(percent: Int, dimmed: Bool = false) -> NSImage {
        let barWidth: CGFloat = 40, height: CGFloat = 12, radius: CGFloat = 3
        // Transparent trailing space baked into the image guarantees a visible gap
        // before the percent text — the menu-bar HStack spacing isn't reliably applied.
        let trailingGap: CGFloat = 8
        let image = NSImage(size: NSSize(width: barWidth + trailingGap, height: height))
        image.lockFocus()

        let track = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: barWidth, height: height),
                                 xRadius: radius, yRadius: radius)
        NSColor.tertiaryLabelColor.setFill()
        track.fill()

        let frac = CGFloat(max(0, min(100, percent))) / 100
        let fillWidth = max(radius * 2, barWidth * frac)
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fillWidth, height: height),
                                xRadius: radius, yRadius: radius)
        color(for: percent).withAlphaComponent(dimmed ? 0.4 : 1).setFill()
        fill.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func color(for percent: Int) -> NSColor {
        switch percent {
        case ..<75: return .systemGreen
        case 75..<90: return .systemOrange
        default: return .systemRed
        }
    }
}
