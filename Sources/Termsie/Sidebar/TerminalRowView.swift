import AppKit

/// One row of the terminal list: number, open/closed dot, live thumbnail, name, folder, badge.
final class TerminalRowView: NSTableRowView {
    static let thumbnailSize = NSSize(width: 104, height: 65)
    private static let gutter: CGFloat = 22
    private static let margin: CGFloat = 6

    var number = 0
    var title = ""
    var subtitle = ""
    var badge: BadgeDrawing.Badge = .none
    var isOpen = false
    var isBusy = false
    var isActivePane = false
    var thumbnail: CGImage?
    var environmentTint: NSColor?
    var environmentLabel: String?

    override var isFlipped: Bool { true }

    var thumbnailRect: NSRect {
        NSRect(x: Self.margin + Self.gutter + 6,
               y: (bounds.height - Self.thumbnailSize.height) / 2,
               width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let colors = ConfigStore.shared.config.colors
        NSColor.hex(colors.sidebarBackground).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let colors = ConfigStore.shared.config.colors
        NSColor.hex(colors.sidebarSelection).setFill()
        bounds.fill()
        (environmentTint ?? NSColor.hex(colors.activeBorder)).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let colors = ConfigStore.shared.config.colors
        // A closed terminal reads as dimmed rather than absent.
        let alpha: CGFloat = isOpen ? 1.0 : 0.55
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)

        let x = Self.margin
        let midY = bounds.midY

        BadgeDrawing.drawIndexPill(number, at: NSPoint(x: x, y: midY - 16), active: isActivePane, colors: colors)
        BadgeDrawing.drawStatusDot(in: NSRect(x: x + 4, y: midY + 4, width: 7, height: 7),
                                   isOpen: isOpen, isBusy: isBusy, colors: colors)

        let thumb = thumbnailRect
        if let image = thumbnail, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            // The row is flipped; images draw bottom-up, so flip back for this one draw.
            ctx.translateBy(x: 0, y: thumb.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: NSRect(x: thumb.minX, y: 0, width: thumb.width, height: thumb.height))
            ctx.restoreGState()
        } else {
            NSColor.hex(colors.background).setFill()
            thumb.fill()
        }
        let strokeColor = environmentTint ?? NSColor.hex(isActivePane ? colors.activeBorder : colors.inactiveBorder)
        strokeColor.withAlphaComponent(isActivePane || environmentTint != nil ? 0.9 : 1).setStroke()
        let border = NSBezierPath(roundedRect: thumb.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        border.stroke()

        // Title and folder stack vertically beside the thumbnail; the badge sits under them so a
        // narrow sidebar still shows a readable name.
        let textX = thumb.maxX + 8
        let textWidth = max(0, bounds.width - Self.margin - textX)
        BadgeDrawing.drawTruncated(title,
                                   font: NSFont.systemFont(ofSize: 11, weight: isActivePane ? .semibold : .medium),
                                   color: NSColor.hex(isActivePane ? colors.headerActiveText : colors.headerText),
                                   at: NSPoint(x: textX, y: thumb.minY + 2), maxWidth: textWidth)
        if !subtitle.isEmpty {
            BadgeDrawing.drawTruncated(subtitle,
                                       font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                                       color: NSColor.hex(colors.headerText),
                                       at: NSPoint(x: textX, y: thumb.minY + 17), maxWidth: textWidth)
        }
        var right = min(bounds.width - Self.margin, textX + textWidth)
        if badge != .none {
            right = BadgeDrawing.draw(badge, rightEdge: right, midY: thumb.maxY - 8, colors: colors)
        }
        if let label = environmentLabel, let tint = environmentTint {
            _ = BadgeDrawing.drawLabel(label.uppercased(), rightEdge: right,
                                       midY: thumb.maxY - 8, color: tint, filled: true)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
