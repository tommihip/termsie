import AppKit

/// One row of the terminal list: number, open/closed dot, live thumbnail, name, folder, badge,
/// and a button that runs the terminal's startup commands.
final class TerminalRowView: NSTableRowView {
    /// The thumbnail at the default sidebar width. It never grows past this.
    static let thumbnailSize = NSSize(width: 104, height: 65)
    private static let gutter: CGFloat = 22
    private static let margin: CGFloat = 6
    private static let runButtonSize: CGFloat = 16

    /// How a row lays out at a given sidebar width.
    ///
    /// At the default width and wider the thumbnail is full size and any extra width goes to the
    /// text. Narrower, the thumbnail gives way first, shrinking until it would be too small to
    /// read and then disappearing, which hands its space back to the name. Narrower still, only
    /// the number and status dot are left.
    struct Metrics: Equatable {
        /// Nil when the thumbnail is hidden.
        var thumbnail: NSSize?
        var rowHeight: CGFloat
        var showsText: Bool

        /// Space kept for the name and folder beside a thumbnail. At the default width this is
        /// exactly what is left over, which is what makes the default the point where
        /// shrinking starts.
        static let textWidthBesideThumbnail: CGFloat = 112
        static let minThumbnailWidth: CGFloat = 48
        static let compactRowHeight: CGFloat = 40
        static let minThumbnailRowHeight: CGFloat = 64
        static let minTextWidth: CGFloat = 36

        /// Everything left of the thumbnail: margin, number gutter and gap.
        static var leading: CGFloat { TerminalRowView.margin + TerminalRowView.gutter + 6 }

        /// The width at which the thumbnail is full size.
        static var fullWidth: CGFloat {
            leading + TerminalRowView.thumbnailSize.width + 8 + textWidthBesideThumbnail + TerminalRowView.margin
        }

        static func forWidth(_ width: CGFloat, fullRowHeight: CGFloat) -> Metrics {
            let full = TerminalRowView.thumbnailSize
            let thumbWidth = min(full.width, (width - (fullWidth - full.width)).rounded(.down))
            if thumbWidth >= minThumbnailWidth {
                let height = (thumbWidth * full.height / full.width).rounded()
                // The row loses what the thumbnail loses, so the margins stay put — down to the
                // height the name, folder and badge need stacked beside it.
                let rowHeight = max(fullRowHeight - (full.height - height), minThumbnailRowHeight)
                return Metrics(thumbnail: NSSize(width: thumbWidth, height: height),
                               rowHeight: rowHeight.rounded(), showsText: true)
            }
            let textWidth = width - leading - TerminalRowView.margin
            return Metrics(thumbnail: nil, rowHeight: compactRowHeight, showsText: textWidth >= minTextWidth)
        }
    }

    var metrics = Metrics(thumbnail: TerminalRowView.thumbnailSize, rowHeight: 84, showsText: true)
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
    /// Whether this terminal has startup commands to run, which is when the button shows.
    var hasStartupCommands = false { didSet { updateRunToolTip() } }
    /// Commands were asked for and are waiting for the terminal to be free.
    var runPending = false
    var runHovered = false {
        didSet { if runHovered != oldValue { setNeedsDisplay(runButtonRect.insetBy(dx: -2, dy: -2)) } }
    }
    private var runToolTip: NSView.ToolTipTag?

    override var isFlipped: Bool { true }

    var thumbnailRect: NSRect {
        let size = metrics.thumbnail ?? .zero
        return NSRect(x: Metrics.leading, y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private var textX: CGFloat {
        metrics.thumbnail == nil ? Metrics.leading : thumbnailRect.maxX + 8
    }

    /// The top of the name, whichever layout the row is in.
    private var titleY: CGFloat {
        metrics.thumbnail == nil ? bounds.midY - 15 : thumbnailRect.minY + 2
    }

    /// Whether the run button is shown at all: it needs commands to run and room beside the name.
    var showsRunButton: Bool {
        hasStartupCommands && metrics.showsText
            && bounds.width - Self.margin - textX >= Self.runButtonSize + Metrics.minTextWidth
    }

    /// Top right, level with the name. Zero when the button is not shown.
    var runButtonRect: NSRect {
        guard showsRunButton else { return .zero }
        return NSRect(x: bounds.width - Self.margin - Self.runButtonSize, y: titleY - 1,
                      width: Self.runButtonSize, height: Self.runButtonSize)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRunToolTip()
    }

    private func updateRunToolTip() {
        if let tag = runToolTip { removeToolTip(tag); runToolTip = nil }
        guard showsRunButton else { return }
        runToolTip = addToolTip(runButtonRect, owner: "Run startup commands" as NSString, userData: nil)
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
        guard let graphics = NSGraphicsContext.current else { return }
        let context = graphics.cgContext
        // Save and restore the *same* context, and pair them with `defer`. The previous version
        // read `NSGraphicsContext.current` separately for the save and the restore, which is only
        // balanced if that property hands back the same object both times.
        context.saveGState()
        defer { context.restoreGState() }

        let colors = ConfigStore.shared.config.colors
        // A closed terminal reads as dimmed rather than absent.
        context.setAlpha(isOpen ? 1.0 : 0.55)

        let x = Self.margin
        let midY = bounds.midY

        BadgeDrawing.drawIndexPill(number, at: NSPoint(x: x, y: midY - 16), active: isActivePane, colors: colors)
        BadgeDrawing.drawStatusDot(in: NSRect(x: x + 4, y: midY + 4, width: 7, height: 7),
                                   isOpen: isOpen, isBusy: isBusy, colors: colors)

        if metrics.thumbnail != nil { drawThumbnail(context, colors: colors) }
        guard metrics.showsText else { return }

        // Title and folder stack vertically beside the thumbnail; the badge sits under them so a
        // narrow sidebar still shows a readable name.
        let textX = self.textX
        let run = runButtonRect
        let textRight = run == .zero ? bounds.width - Self.margin : run.minX - 4
        let textWidth = max(0, textRight - textX)
        let titleFont = UIFonts.system(size: 11, weight: isActivePane ? .semibold : .medium)
        let subFont = UIFonts.monospaced(size: 9.5, weight: .regular)
        BadgeDrawing.drawTruncated(title,
                                   font: titleFont,
                                   color: NSColor.hex(isActivePane ? colors.headerActiveText : colors.headerText),
                                   at: NSPoint(x: textX, y: titleY), maxWidth: textWidth)
        if !subtitle.isEmpty {
            BadgeDrawing.drawTruncated(subtitle,
                                       font: subFont,
                                       color: NSColor.hex(colors.headerText),
                                       at: NSPoint(x: textX, y: titleY + 15),
                                       maxWidth: max(0, bounds.width - Self.margin - textX))
        }
        if run != .zero { drawRunButton(in: run, colors: colors) }

        // Badges need a row of their own, which only the thumbnail layout has.
        guard metrics.thumbnail != nil else { return }
        let thumb = thumbnailRect
        var right = bounds.width - Self.margin
        let badgeY = max(thumb.maxY - 8, titleY + 34)
        if badge != .none {
            right = BadgeDrawing.draw(badge, rightEdge: right, midY: badgeY, colors: colors)
        }
        if let label = environmentLabel, let tint = environmentTint, right - textX > 40 {
            _ = BadgeDrawing.drawLabel(label.uppercased(), rightEdge: right,
                                       midY: badgeY, color: tint, filled: true)
        }
    }

    private func drawThumbnail(_ context: CGContext, colors: TermsieConfig.Colors) {
        let thumb = thumbnailRect
        if let image = thumbnail {
            context.saveGState()
            // The row is flipped; images draw bottom-up, so flip back for this one draw.
            context.translateBy(x: 0, y: thumb.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(image, in: NSRect(x: thumb.minX, y: 0, width: thumb.width, height: thumb.height))
            context.restoreGState()
        } else {
            NSColor.hex(colors.background).setFill()
            thumb.fill()
        }
        let strokeColor = environmentTint ?? NSColor.hex(isActivePane ? colors.activeBorder : colors.inactiveBorder)
        strokeColor.withAlphaComponent(isActivePane || environmentTint != nil ? 0.9 : 1).setStroke()
        let border = NSBezierPath(roundedRect: thumb.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        border.stroke()
    }

    /// A drawn play triangle, like the footer's drawn plus, so it stays crisp at any scale.
    private func drawRunButton(in rect: NSRect, colors: TermsieConfig.Colors) {
        if runHovered {
            NSColor.hex(colors.headerActiveText).withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        let tint: NSColor
        if runPending { tint = NSColor.hex(colors.activeBorder) }
        else if runHovered { tint = NSColor.hex(colors.headerActiveText) }
        else { tint = NSColor.hex(colors.headerText).withAlphaComponent(0.75) }
        let inset = rect.insetBy(dx: 4.5, dy: 4)
        let play = NSBezierPath()
        play.move(to: NSPoint(x: inset.minX, y: inset.minY))
        play.line(to: NSPoint(x: inset.maxX, y: inset.midY))
        play.line(to: NSPoint(x: inset.minX, y: inset.maxY))
        play.close()
        play.lineJoinStyle = .round
        play.lineWidth = 1
        tint.setFill()
        tint.setStroke()
        play.fill()
        play.stroke()
    }
}
