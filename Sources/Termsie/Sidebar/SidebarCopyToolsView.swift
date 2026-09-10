import AppKit

/// The copy tools that sit between the terminal list and the New Terminal button: a switch for
/// copying every selection as it is made, and three buttons that copy a whole command, its output,
/// or the terminal itself.
///
/// Drawn rather than assembled from controls, for the same reason the footer below it is: an
/// `NSButton` here would bring its own bezel, its own font and its own idea of a highlight, none of
/// which match the list it belongs to.
final class SidebarCopyToolsView: NSView {
    /// One row. The toggle is first so it reads as the setting it is, with the actions under it.
    enum Row: Equatable {
        case autoCopy
        case action(TerminalPane.CopyTarget)
    }

    static let rowHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 20
    private static let padding: CGFloat = 4

    static let rows: [Row] = [
        .autoCopy,
        .action(.lastCommandOutput),
        .action(.wholeTerminal),
        .action(.lastCommand),
    ]

    static var height: CGFloat {
        headerHeight + CGFloat(rows.count) * rowHeight + padding
    }

    var onAction: ((TerminalPane.CopyTarget) -> Void)?
    var onToggleAutoCopy: (() -> Void)?
    /// Whether each action can do anything right now, so a button that would beep looks like it.
    var enabledTargets: Set<TerminalPane.CopyTarget> = [] {
        didSet { if enabledTargets != oldValue { needsDisplay = true } }
    }
    var autoCopyOn = false { didSet { if autoCopyOn != oldValue { needsDisplay = true } } }

    /// The row a copy just came from, flashed briefly so the click has an answer even though the
    /// clipboard has nothing visible to show for it.
    private var confirmingRow: Row?
    private var confirmWork: DispatchWorkItem?
    private var hoveredRow: Row? { didSet { if hoveredRow != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { confirmWork?.cancel() }

    // MARK: Geometry

    private func rect(of row: Row) -> NSRect {
        guard let index = Self.rows.firstIndex(of: row) else { return .zero }
        return NSRect(x: 0, y: Self.headerHeight + CGFloat(index) * Self.rowHeight,
                      width: bounds.width, height: Self.rowHeight)
    }

    private func row(at point: NSPoint) -> Row? {
        Self.rows.first { rect(of: $0).contains(point) }
    }

    private func isEnabled(_ row: Row) -> Bool {
        switch row {
        case .autoCopy: return true
        case .action(let target): return enabledTargets.contains(target)
        }
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredRow = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hoveredRow = nil }

    override func mouseDown(with event: NSEvent) {
        // Swallowed rather than passed up the responder chain: the action belongs on mouse-up,
        // the way every other button in the app behaves.
    }

    override func mouseUp(with event: NSEvent) {
        guard let row = row(at: convert(event.locationInWindow, from: nil)), isEnabled(row) else { return }
        switch row {
        case .autoCopy:
            onToggleAutoCopy?()
        case .action(let target):
            onAction?(target)
        }
    }

    /// Flashes a row to acknowledge a copy. `false` marks the row instead as having found nothing.
    func confirm(_ target: TerminalPane.CopyTarget, copied: Bool) {
        confirmWork?.cancel()
        confirmingRow = copied ? .action(target) : nil
        if !copied { NSSound.beep() }
        needsDisplay = true
        guard copied else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.confirmingRow = nil
            self?.needsDisplay = true
        }
        confirmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let colors = ConfigStore.shared.config.colors
        NSColor(white: 1, alpha: 0.06).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        BadgeDrawing.drawTruncated("COPY", font: UIFonts.system(size: 9, weight: .semibold),
                                   color: NSColor.hex(colors.headerText).withAlphaComponent(0.65),
                                   at: NSPoint(x: 12, y: 6), maxWidth: bounds.width - 24)

        for row in Self.rows { draw(row, colors: colors) }
    }

    private func draw(_ row: Row, colors: TermsieConfig.Colors) {
        let frame = rect(of: row)
        let enabled = isEnabled(row)
        let confirming = confirmingRow == row
        let accent = NSColor.hex(colors.activeBorder)

        if confirming {
            accent.withAlphaComponent(0.28).setFill()
            frame.fill()
        } else if hoveredRow == row, enabled {
            NSColor.hex(colors.sidebarSelection).withAlphaComponent(0.8).setFill()
            frame.fill()
        }

        let active = hoveredRow == row && enabled
        var tint = NSColor.hex(active ? colors.headerActiveText : colors.headerText)
        if !enabled { tint = tint.withAlphaComponent(0.35) }
        let midY = frame.midY

        switch row {
        case .autoCopy:
            drawSwitch(at: NSPoint(x: 12, y: midY), on: autoCopyOn, colors: colors)
            let textX: CGFloat = 12 + 22 + 8
            BadgeDrawing.drawTruncated("Auto-copy on select", font: UIFonts.system(size: 11, weight: .medium),
                                       color: autoCopyOn ? NSColor.hex(colors.headerActiveText) : tint,
                                       at: NSPoint(x: textX, y: midY - 7),
                                       maxWidth: max(0, bounds.width - textX - 44))
            drawShortcut("⌥⇧⌘C", rightEdge: bounds.width - 8, midY: midY, colors: colors, dim: !enabled)
        case .action(let target):
            drawGlyph(for: target, at: NSPoint(x: 12 + 11, y: midY), tint: tint)
            let textX: CGFloat = 12 + 22 + 8
            let shortcutRight = bounds.width - 8
            let used = drawShortcut(shortcut(for: target), rightEdge: shortcutRight, midY: midY,
                                    colors: colors, dim: !enabled)
            BadgeDrawing.drawTruncated(shortLabel(for: target), font: UIFonts.system(size: 11, weight: .medium),
                                       color: tint, at: NSPoint(x: textX, y: midY - 7),
                                       maxWidth: max(0, shortcutRight - used - 6 - textX))
        }
    }

    /// A pill switch rather than a checkbox: this is a mode that stays on, not a one-off choice.
    private func drawSwitch(at leftMiddle: NSPoint, on: Bool, colors: TermsieConfig.Colors) {
        let track = NSRect(x: leftMiddle.x, y: leftMiddle.y - 6, width: 22, height: 12)
        let path = NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6)
        if on {
            NSColor.hex(colors.activeBorder).setFill()
            path.fill()
        } else {
            NSColor(white: 1, alpha: 0.10).setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let knob = NSRect(x: on ? track.maxX - 11 : track.minX + 1, y: track.minY + 1, width: 10, height: 10)
        (on ? NSColor.white : NSColor.hex(colors.headerText)).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    /// A drawn mark per action, so the three rows are told apart without reading them.
    private func drawGlyph(for target: TerminalPane.CopyTarget, at center: NSPoint, tint: NSColor) {
        tint.setStroke()
        tint.setFill()
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        switch target {
        case .lastCommandOutput:
            // A chevron with two output lines under it.
            path.move(to: NSPoint(x: center.x - 6, y: center.y - 5))
            path.line(to: NSPoint(x: center.x - 2, y: center.y - 1.5))
            path.line(to: NSPoint(x: center.x - 6, y: center.y + 2))
            path.stroke()
            NSRect(x: center.x - 6, y: center.y + 4, width: 12, height: 1.4).fill()
            NSRect(x: center.x - 6, y: center.y + 7, width: 8, height: 1.4).fill()
        case .wholeTerminal:
            // A framed screen full of lines.
            let frame = NSRect(x: center.x - 7, y: center.y - 6, width: 14, height: 12)
            let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            border.lineWidth = 1.2
            border.stroke()
            NSRect(x: frame.minX + 3, y: frame.minY + 3, width: 8, height: 1.2).fill()
            NSRect(x: frame.minX + 3, y: frame.minY + 6, width: 5, height: 1.2).fill()
        case .lastCommand, .selection:
            // A prompt chevron and a caret line, the shape of a command line.
            path.move(to: NSPoint(x: center.x - 6, y: center.y - 4))
            path.line(to: NSPoint(x: center.x - 2, y: center.y))
            path.line(to: NSPoint(x: center.x - 6, y: center.y + 4))
            path.stroke()
            NSRect(x: center.x + 0.5, y: center.y + 3, width: 6, height: 1.4).fill()
        }
    }

    @discardableResult
    private func drawShortcut(_ text: String, rightEdge: CGFloat, midY: CGFloat,
                              colors: TermsieConfig.Colors, dim: Bool) -> CGFloat {
        let font = UIFonts.system(size: 10, weight: .regular)
        let color = NSColor.hex(colors.headerText).withAlphaComponent(dim ? 0.25 : 0.5)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        guard size.width < bounds.width * 0.5 else { return 0 }
        string.draw(at: NSPoint(x: rightEdge - size.width, y: midY - size.height / 2))
        return size.width
    }

    private func shortLabel(for target: TerminalPane.CopyTarget) -> String {
        switch target {
        case .selection: return "Selection"
        case .lastCommandOutput: return "Last command output"
        case .wholeTerminal: return "Whole terminal"
        case .lastCommand: return "Last command"
        }
    }

    private func shortcut(for target: TerminalPane.CopyTarget) -> String {
        switch target {
        case .selection: return "⌘C"
        case .lastCommandOutput: return "⇧⌘C"
        case .wholeTerminal: return "⌃⌘C"
        case .lastCommand: return "⌥⌘C"
        }
    }

    // MARK: Tooltips

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildTooltips()
    }

    override func layout() {
        super.layout()
        rebuildTooltips()
    }

    private func rebuildTooltips() {
        removeAllToolTips()
        for row in Self.rows {
            let text: String
            switch row {
            case .autoCopy:
                text = "Put every mouse selection on the clipboard as soon as it is made."
            case .action(let target):
                text = target.detail
            }
            addToolTip(rect(of: row), owner: text as NSString, userData: nil)
        }
    }
}
