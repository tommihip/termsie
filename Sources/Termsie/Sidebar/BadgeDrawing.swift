import AppKit

/// Small drawn elements shared by the pane header and the sidebar rows, so the two cannot
/// drift apart visually.
enum BadgeDrawing {
    /// The state of a terminal, as shown by a badge or a dot.
    enum Badge: Equatable {
        case none
        case activity
        case bell
        case warning
        case exited(Int32?)
    }

    static let pillHeight: CGFloat = 14
    static let pillRadius: CGFloat = 3

    /// The terminal's number, as a filled pill.
    @discardableResult
    static func drawIndexPill(_ number: Int, at origin: NSPoint, active: Bool,
                              colors: TermsieConfig.Colors) -> NSRect {
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: active ? NSColor.white : NSColor.hex(colors.headerText),
        ])
        let size = text.size()
        let rect = NSRect(x: origin.x, y: origin.y, width: max(16, size.width + 8), height: pillHeight)
        (active ? NSColor.hex(colors.activeBorder) : NSColor.hex(colors.inactiveBorder)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: pillRadius, yRadius: pillRadius).fill()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        return rect
    }

    /// A labelled pill, either filled or outlined. Returns the rect it occupied.
    @discardableResult
    static func drawLabel(_ text: String, rightEdge: CGFloat, midY: CGFloat,
                          color: NSColor, filled: Bool) -> NSRect {
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: filled ? NSColor.black : color,
        ])
        let size = s.size()
        let rect = NSRect(x: rightEdge - size.width - 8, y: midY - pillHeight / 2,
                          width: size.width + 8, height: pillHeight)
        if filled {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: pillRadius, yRadius: pillRadius).fill()
        } else {
            color.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: pillRadius, yRadius: pillRadius).stroke()
        }
        s.draw(at: NSPoint(x: rect.minX + 4, y: midY - size.height / 2))
        return rect
    }

    @discardableResult
    static func drawDot(rightEdge: CGFloat, midY: CGFloat, color: NSColor, diameter: CGFloat = 8) -> NSRect {
        let r = NSRect(x: rightEdge - diameter, y: midY - diameter / 2, width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        return r
    }

    /// Draws whichever badge applies, right-aligned. Returns the new right edge.
    static func draw(_ badge: Badge, rightEdge: CGFloat, midY: CGFloat,
                     colors: TermsieConfig.Colors) -> CGFloat {
        switch badge {
        case .none:
            return rightEdge
        case .activity:
            return drawDot(rightEdge: rightEdge, midY: midY, color: NSColor.hex(colors.activity)).minX - 8
        case .bell:
            return drawLabel("BELL", rightEdge: rightEdge, midY: midY,
                             color: NSColor.hex(colors.bell), filled: true).minX - 6
        case .warning:
            return drawLabel("!", rightEdge: rightEdge, midY: midY,
                             color: NSColor.hex(colors.warning), filled: true).minX - 6
        case .exited(let code):
            let text = code.map { "exited \($0)" } ?? "exited"
            let color = NSColor.hex(code == 0 ? colors.exited : colors.bell)
            return drawLabel(text, rightEdge: rightEdge, midY: midY, color: color, filled: false).minX - 6
        }
    }

    /// The open/closed indicator used in sidebar rows.
    /// Filled accent = running a job, filled grey = idle shell, hollow ring = closed.
    static func drawStatusDot(in rect: NSRect, isOpen: Bool, isBusy: Bool, colors: TermsieConfig.Colors) {
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        if isOpen {
            (isBusy ? NSColor.hex(colors.activeBorder) : NSColor.hex(colors.headerText)).setFill()
            path.fill()
        } else {
            NSColor.hex(colors.exited).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Draws text truncated to a width, returning the width actually used.
    @discardableResult
    static func drawTruncated(_ string: String, font: NSFont, color: NSColor,
                              at point: NSPoint, maxWidth: CGFloat) -> CGFloat {
        guard maxWidth > 4, !string.isEmpty else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let s = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        let size = s.size()
        let w = min(size.width, maxWidth)
        s.draw(with: NSRect(x: point.x, y: point.y, width: w, height: size.height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return w
    }
}
