import AppKit

/// The menu bar glyph (04-ux-mac.md): an "f." in a rounded square, drawn in code so it follows
/// the menu bar's appearance.
enum MenuBarIcon {
    enum State: String, CaseIterable {
        /// On, nothing waiting: the outline glyph.
        case normal
        /// A panel is open, or requests or suggestions are waiting: filled, with an accent dot.
        case needsYou
        /// Funes or the MCP server is paused: slashed.
        case paused
        /// MCP server off (before setup): dimmed.
        case off

        var accessibilityLabel: String {
            switch self {
            case .normal: String(localized: "Funes Vault")
            case .needsYou: String(localized: "Funes Vault, waiting for you")
            case .paused: String(localized: "Funes Vault, paused")
            case .off: String(localized: "Funes Vault, off")
            }
        }
    }

    static let size = NSSize(width: 18, height: 18)

    /// `remote`: Remote Access is on, so a small globe sits at the bottom right (04-ux-mac.md).
    static func image(_ state: State, remote: Bool = false) -> NSImage {
        // The dot is the only color, so only "needs you" isn't a template image.
        let image = NSImage(size: size, flipped: false) { rect in
            draw(state, in: rect)
            if remote { drawGlobe(ink: state == .needsYou ? NSColor.labelColor : NSColor.black) }
            return true
        }
        image.isTemplate = state != .needsYou
        image.accessibilityDescription = remote
            ? state.accessibilityLabel + ", " + String(localized: "Remote Access on") : state.accessibilityLabel
        return image
    }

    /// A 7-point globe in a knocked-out circle, so it reads on the glyph.
    private static func drawGlobe(ink: NSColor) {
        let frame = NSRect(x: 11, y: 0, width: 7, height: 7)
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: frame.insetBy(dx: -1, dy: -1)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        ink.setStroke()
        let outline = NSBezierPath(ovalIn: frame.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        let meridian = NSBezierPath(ovalIn: NSRect(x: frame.midX - 1.4, y: frame.minY + 0.5, width: 2.8, height: frame.height - 1))
        meridian.lineWidth = 0.8
        meridian.stroke()
        let equator = NSBezierPath()
        equator.move(to: NSPoint(x: frame.minX + 0.5, y: frame.midY))
        equator.line(to: NSPoint(x: frame.maxX - 0.5, y: frame.midY))
        equator.lineWidth = 0.8
        equator.stroke()
    }

    private static func draw(_ state: State, in rect: NSRect) {
        let ink = state == .needsYou ? NSColor.labelColor : NSColor.black
        let alpha: CGFloat = state == .off ? 0.45 : 1
        let box = NSRect(x: 2, y: 2, width: 14, height: 14)
        let shape = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
        let font = NSFont.systemFont(ofSize: 11.5, weight: .heavy)
        let glyph = NSAttributedString(string: "f.", attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(alpha)])
        let glyphSize = glyph.size()
        let origin = NSPoint(x: box.midX - glyphSize.width / 2 + 0.5, y: box.midY - glyphSize.height / 2 + 0.5)

        if state == .needsYou {
            ink.setFill()
            shape.fill()
            // Knock the glyph out of the filled square.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            glyph.draw(at: origin)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let dot = NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 6, height: 6))
            NSColor.controlAccentColor.setFill()
            dot.fill()
        } else {
            ink.withAlphaComponent(alpha).setStroke()
            shape.lineWidth = 1.3
            shape.stroke()
            glyph.draw(at: origin)
        }
        if state == .paused {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 1, y: 1))
            slash.line(to: NSPoint(x: 17, y: 17))
            slash.lineWidth = 1.6
            ink.setStroke()
            slash.stroke()
        }
    }
}
