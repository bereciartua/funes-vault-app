import AppKit

/// The menu bar glyph (04-ux-mac.md): the app icon's eye (UX review F19), drawn in code so it
/// follows the menu bar's appearance. The almond is the icon's (scripts/app_icon.swift), scaled to
/// 16 points wide.
enum MenuBarIcon {
    enum State: String, CaseIterable {
        /// On, nothing waiting: the outline glyph.
        case normal
        /// A panel is open, or requests or suggestions are waiting: filled, with an accent dot.
        case needsYou
        /// All agents are paused: slashed.
        case paused
        /// The agent server failed (a port in use, or it stopped): a warning badge.
        case cantConnect
        /// The agent server is off (before setup, or turned off in Settings): dimmed.
        case off

        var accessibilityLabel: String {
            switch self {
            case .normal: String(localized: "Funes Vault")
            case .needsYou: String(localized: "Funes Vault, waiting for you")
            case .paused: String(localized: "Funes Vault, paused")
            case .cantConnect: String(localized: "Funes Vault, can't connect")
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

    /// A 7-point warning triangle at the top right, knocked out of the glyph, with its "!" cut
    /// out of it, so it reads on the eye.
    private static func drawWarning(ink: NSColor) {
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: 11, y: 11))
        triangle.line(to: NSPoint(x: 18, y: 11))
        triangle.line(to: NSPoint(x: 14.5, y: 17.5))
        triangle.close()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let gap = triangle.copy() as! NSBezierPath
        gap.lineWidth = 2.4
        gap.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        ink.setFill()
        triangle.fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(rect: NSRect(x: 14.0, y: 13.6, width: 1, height: 2.4)).fill()
        NSBezierPath(rect: NSRect(x: 14.0, y: 12.0, width: 1, height: 1)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// The icon's almond: two cubic lids from the left corner to the right one.
    static func almond() -> NSBezierPath {
        let path = NSBezierPath()
        let left = NSPoint(x: 1, y: 9), right = NSPoint(x: 17, y: 9)
        // On the icon's 1024 canvas: corners 196 and 828, control points 132.72 in and 262 up or down.
        let inset: CGFloat = 16 * 132.72 / 632, lift: CGFloat = 16 * 262 / 632
        path.move(to: left)
        path.curve(to: right, controlPoint1: NSPoint(x: left.x + inset, y: 9 + lift),
                   controlPoint2: NSPoint(x: right.x - inset, y: 9 + lift))
        path.curve(to: left, controlPoint1: NSPoint(x: right.x - inset, y: 9 - lift),
                   controlPoint2: NSPoint(x: left.x + inset, y: 9 - lift))
        path.close()
        return path
    }

    private static func draw(_ state: State, in rect: NSRect) {
        let ink = state == .needsYou ? NSColor.labelColor : NSColor.black
        let alpha: CGFloat = state == .off ? 0.45 : 1
        let eye = almond()
        let iris = NSBezierPath(ovalIn: NSRect(x: 9 - 3.1, y: 9 - 3.1, width: 6.2, height: 6.2))

        if state == .needsYou {
            ink.setFill()
            eye.fill()
            // A white iris ring knocked out of the filled almond, with the pupil left in.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            iris.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: 9 - 1.7, y: 9 - 1.7, width: 3.4, height: 3.4)).fill()
            let dot = NSBezierPath(ovalIn: NSRect(x: 12.5, y: 12, width: 5.5, height: 5.5))
            NSColor.controlAccentColor.setFill()
            dot.fill()
        } else {
            ink.withAlphaComponent(alpha).setStroke()
            ink.withAlphaComponent(alpha).setFill()
            eye.lineWidth = 1.4
            eye.stroke()
            iris.fill()
            // The icon's catchlight.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 9.6, y: 9.6, width: 1.5, height: 1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
        if state == .cantConnect { drawWarning(ink: ink) }
        if state == .paused {
            // A gap around the slash keeps it legible across the outline.
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 2, y: 1.5))
            slash.line(to: NSPoint(x: 16, y: 16.5))
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            slash.lineWidth = 3.4
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            slash.lineWidth = 1.5
            ink.setStroke()
            slash.stroke()
        }
    }
}
