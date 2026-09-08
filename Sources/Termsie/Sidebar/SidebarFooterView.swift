import AppKit

/// The strip along the bottom of the terminal list holding the add button.
final class SidebarFooterView: NSView {
    static let height: CGFloat = 30

    var onAdd: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        toolTip = "New terminal (\u{2318}D)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let colors = ConfigStore.shared.config.colors
        if hovering {
            NSColor.hex(colors.sidebarSelection).withAlphaComponent(0.8).setFill()
            bounds.fill()
        }
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let tint = NSColor.hex(hovering ? colors.headerActiveText : colors.headerText)
        let midY = bounds.midY
        let x: CGFloat = 12

        // A drawn plus rather than a text glyph, so it stays crisp and centred at any size.
        let plus = NSBezierPath()
        plus.lineWidth = 1.6
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: x, y: midY - 5)); plus.line(to: NSPoint(x: x, y: midY + 5))
        plus.move(to: NSPoint(x: x - 5, y: midY)); plus.line(to: NSPoint(x: x + 5, y: midY))
        tint.setStroke()
        plus.stroke()

        let label = NSAttributedString(string: "New Terminal", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: tint,
        ])
        label.draw(at: NSPoint(x: x + 14, y: midY - label.size().height / 2))
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onAdd?()
    }
}
