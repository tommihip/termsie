import AppKit

/// The strip along the bottom of the terminal list: New Terminal, and Run All beside it.
final class SidebarFooterView: NSView {
    static let height: CGFloat = 30

    enum Zone { case add, runAll }

    var onAdd: (() -> Void)?
    var onRunAll: (() -> Void)?
    /// Whether any terminal has startup commands. Run All is shown dimmed and does nothing when
    /// none does, rather than disappearing and moving New Terminal about.
    var runAllEnabled = false {
        didSet { if runAllEnabled != oldValue { needsDisplay = true; updateToolTips() } }
    }
    private var hovering: Zone? { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateToolTips()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Geometry

    /// Labels need room; below this the two buttons are icons only.
    private var showsLabels: Bool { bounds.width >= 150 }

    private var runAllWidth: CGFloat {
        guard showsLabels else { return min(30, bounds.width / 2) }
        return Self.labelWidth("Run All") + 30
    }

    func rect(for zone: Zone) -> NSRect {
        let split = bounds.width - runAllWidth
        switch zone {
        case .add: return NSRect(x: 0, y: 0, width: split, height: bounds.height)
        case .runAll: return NSRect(x: split, y: 0, width: runAllWidth, height: bounds.height)
        }
    }

    func zone(at point: NSPoint) -> Zone? {
        if rect(for: .runAll).contains(point) { return .runAll }
        if rect(for: .add).contains(point) { return .add }
        return nil
    }

    private static func labelWidth(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: UIFonts.system(size: 11, weight: .medium)]).size().width
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
    }

    private func updateToolTips() {
        removeAllToolTips()
        addToolTip(rect(for: .add), owner: "New terminal (\u{2318}D)" as NSString, userData: nil)
        let run = runAllEnabled ? "Run the startup commands of every terminal in this workspace"
                                : "No terminal in this workspace has startup commands"
        addToolTip(rect(for: .runAll), owner: run as NSString, userData: nil)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = zone(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { hovering = zone(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovering = nil }

    override func mouseUp(with event: NSEvent) {
        switch zone(at: convert(event.locationInWindow, from: nil)) {
        case .add: onAdd?()
        case .runAll: if runAllEnabled { onRunAll?() } else { NSSound.beep() }
        case nil: break
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let colors = ConfigStore.shared.config.colors
        if let hovering, hovering == .add || runAllEnabled {
            NSColor.hex(colors.sidebarSelection).withAlphaComponent(0.8).setFill()
            rect(for: hovering).fill()
        }
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let split = rect(for: .runAll)
        NSRect(x: split.minX, y: 7, width: 1, height: bounds.height - 14).fill()

        let midY = bounds.midY
        drawAdd(colors: colors, midY: midY)
        drawRunAll(in: split, colors: colors, midY: midY)
    }

    private func tint(for zone: Zone, colors: TermsieConfig.Colors) -> NSColor {
        if zone == .runAll, !runAllEnabled { return NSColor.hex(colors.headerText).withAlphaComponent(0.4) }
        return NSColor.hex(hovering == zone ? colors.headerActiveText : colors.headerText)
    }

    private func drawAdd(colors: TermsieConfig.Colors, midY: CGFloat) {
        let tint = tint(for: .add, colors: colors)
        let x: CGFloat = showsLabels ? 12 : rect(for: .add).midX
        // A drawn plus rather than a text glyph, so it stays crisp and centred at any size.
        let plus = NSBezierPath()
        plus.lineWidth = 1.6
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: x, y: midY - 5)); plus.line(to: NSPoint(x: x, y: midY + 5))
        plus.move(to: NSPoint(x: x - 5, y: midY)); plus.line(to: NSPoint(x: x + 5, y: midY))
        tint.setStroke()
        plus.stroke()

        guard showsLabels else { return }
        let label = NSAttributedString(string: "New Terminal", attributes: [
            .font: UIFonts.system(size: 11, weight: .medium), .foregroundColor: tint,
        ])
        label.draw(at: NSPoint(x: x + 14, y: midY - label.size().height / 2))
    }

    private func drawRunAll(in zone: NSRect, colors: TermsieConfig.Colors, midY: CGFloat) {
        let tint = tint(for: .runAll, colors: colors)
        let x = showsLabels ? zone.minX + 11 : zone.midX - 3.5
        let play = NSBezierPath()
        play.move(to: NSPoint(x: x, y: midY - 5))
        play.line(to: NSPoint(x: x + 8, y: midY))
        play.line(to: NSPoint(x: x, y: midY + 5))
        play.close()
        play.lineJoinStyle = .round
        play.lineWidth = 1
        tint.setFill()
        tint.setStroke()
        play.fill()
        play.stroke()

        guard showsLabels else { return }
        let label = NSAttributedString(string: "Run All", attributes: [
            .font: UIFonts.system(size: 11, weight: .medium), .foregroundColor: tint,
        ])
        label.draw(at: NSPoint(x: x + 13, y: midY - label.size().height / 2))
    }
}
