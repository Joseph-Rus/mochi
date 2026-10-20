// The menu bar: how much of your Claude plan you've used (a badge like AI Usage's), Mochi's icon, or nothing at all.
import AppKit

enum UsageBadge {
    static let claude = NSColor(srgbRed: 0xCC / 255.0, green: 0x78 / 255.0, blue: 0x5C / 255.0, alpha: 1)

    /// Height of the bar: taller on a MacBook with a notch than the status bar's own `thickness` says.
    private static var slot: CGFloat {
        let notch = NSScreen.screens.map { $0.safeAreaInsets.top }.max() ?? 0
        return notch > 0 ? notch : NSStatusBar.system.thickness
    }

    private static func font(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold, width: .condensed)
        // steady digits, so the badge doesn't jiggle as the number changes
        let d = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: d, size: size) ?? base
    }

    /// A Claude-coloured rounded square with the percentage on it. Dimmed while there's no number yet.
    static func image(_ label: String, dim: Bool) -> NSImage {
        let side = (slot * 0.875).rounded()
        let digits = label.filter(\.isNumber).count
        let probe = font(100)
        let byCap = side * (dim ? 0.42 : digits <= 1 ? 0.40 : digits == 2 ? 0.30 : 0.26) / (probe.capHeight / 100)
        let wide = (label as NSString).size(withAttributes: [.font: probe]).width
        let byWidth = wide > 0 ? side * 0.82 / (wide / 100) : byCap
        let f = font(max(5.5, min(byCap, byWidth)).rounded(.down))
        let img = NSImage(size: NSSize(width: side, height: slot), flipped: false) { rect in
            let box = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            (dim ? claude.withAlphaComponent(0.4) : claude).setFill()
            NSBezierPath(roundedRect: box, xRadius: side * 0.18, yRadius: side * 0.18).fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let baseline = box.midY - f.capHeight / 2
            (label as NSString).draw(in: NSRect(x: box.minX, y: baseline + f.descender, width: side, height: f.ascender - f.descender),
                                     withAttributes: [.font: f, .foregroundColor: NSColor.white, .paragraphStyle: style])
            return true
        }
        img.isTemplate = false   // keep Claude's colour in both light and dark menu bars
        return img
    }

    /// "3:10 PM" today, "Fri 9:00 AM" further out.
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(d.timeIntervalSinceNow < 20 * 3600 ? "jmm" : "EEE jmm")
        return f.string(from: d)
    }
}

/// One usage window in the menu: its name, how much is used and when it resets, and a bar.
final class UsageRow: NSView {
    let title: String
    let usage: UsageWindow

    init(title: String, window: UsageWindow) {
        self.title = title
        self.usage = window
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let inset: CGFloat = 14
        let pct = min(max(usage.pct, 0), 100)
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        (title as NSString).draw(at: NSPoint(x: inset, y: 19), withAttributes: label)
        var right = "\(Int(pct.rounded()))%"
        if let r = usage.resets { right += " · resets \(UsageBadge.when(r))" }
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let w = (right as NSString).size(withAttributes: small).width
        (right as NSString).draw(at: NSPoint(x: bounds.width - inset - w, y: 20), withAttributes: small)
        let track = NSRect(x: inset, y: 8, width: bounds.width - inset * 2, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        var fill = track
        fill.size.width = max(track.height, track.width * pct / 100)
        (pct >= 90 ? NSColor.systemRed : UsageBadge.claude).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}
