import AppKit

/// The red / yellow / green buttons, drawn the way macOS draws them: plain circles that reveal
/// their glyphs when the pointer is anywhere over the group.
///
/// Mapped to what those buttons mean for a terminal inside the window: close it (it stays in the
/// list), roll it up to its header, or maximize it to fill the canvas.
final class TrafficLightsView: NSView {
    enum Button: Int, CaseIterable {
        case close, collapse, zoom

        var color: NSColor {
            switch self {
            case .close: return NSColor(srgbRed: 0.996, green: 0.373, blue: 0.345, alpha: 1)
            case .collapse: return NSColor(srgbRed: 0.996, green: 0.741, blue: 0.180, alpha: 1)
            case .zoom: return NSColor(srgbRed: 0.156, green: 0.804, blue: 0.259, alpha: 1)
            }
        }
        var glyphColor: NSColor {
            switch self {
            case .close: return NSColor(srgbRed: 0.46, green: 0.03, blue: 0.03, alpha: 1)
            case .collapse: return NSColor(srgbRed: 0.46, green: 0.30, blue: 0.01, alpha: 1)
            case .zoom: return NSColor(srgbRed: 0.02, green: 0.35, blue: 0.06, alpha: 1)
            }
        }
    }

    static let diameter: CGFloat = 12
    static let spacing: CGFloat = 8
    static var width: CGFloat { diameter * 3 + spacing * 2 }

    var onClose: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onZoom: (() -> Void)?
    /// Inactive terminals show grey buttons, exactly like a background macOS window.
    var isActive = false { didSet { needsDisplay = true } }
    var isCollapsed = false { didSet { needsDisplay = true } }
    var isZoomed = false { didSet { needsDisplay = true } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed: Button?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
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

    private func rect(for button: Button) -> NSRect {
        let i = CGFloat(button.rawValue)
        return NSRect(x: i * (Self.diameter + Self.spacing),
                      y: (bounds.height - Self.diameter) / 2,
                      width: Self.diameter, height: Self.diameter)
    }

    private func button(at point: NSPoint) -> Button? {
        Button.allCases.first { rect(for: $0).insetBy(dx: -2, dy: -2).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for button in Button.allCases {
            let r = rect(for: button)
            var fill = isActive ? button.color : NSColor(white: 0.42, alpha: 0.55)
            if pressed == button { fill = fill.blended(withFraction: 0.25, of: .black) ?? fill }
            fill.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor(white: 0, alpha: 0.18).setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            if hovering { drawGlyph(for: button, in: r) }
        }
    }

    private func drawGlyph(for button: Button, in r: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        let c = NSPoint(x: r.midX, y: r.midY)
        let d: CGFloat = 3
        switch button {
        case .close:
            path.move(to: NSPoint(x: c.x - d, y: c.y - d)); path.line(to: NSPoint(x: c.x + d, y: c.y + d))
            path.move(to: NSPoint(x: c.x + d, y: c.y - d)); path.line(to: NSPoint(x: c.x - d, y: c.y + d))
        case .collapse:
            // A minus, or a plus when already rolled up, matching what the click will do.
            path.move(to: NSPoint(x: c.x - d, y: c.y)); path.line(to: NSPoint(x: c.x + d, y: c.y))
            if isCollapsed {
                path.move(to: NSPoint(x: c.x, y: c.y - d)); path.line(to: NSPoint(x: c.x, y: c.y + d))
            }
        case .zoom:
            if isZoomed {
                path.move(to: NSPoint(x: c.x - d, y: c.y - d)); path.line(to: NSPoint(x: c.x + d, y: c.y - d))
                path.line(to: NSPoint(x: c.x - d, y: c.y + d)); path.close()
            } else {
                path.move(to: NSPoint(x: c.x - d, y: c.y + d)); path.line(to: NSPoint(x: c.x - d, y: c.y - d))
                path.line(to: NSPoint(x: c.x + d, y: c.y - d)); path.close()
            }
        }
        button.glyphColor.setStroke()
        button.glyphColor.setFill()
        path.stroke()
    }

    // The buttons must not start a window drag, so this view consumes the whole gesture.
    override func mouseDown(with event: NSEvent) {
        pressed = button(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let over = button(at: convert(event.locationInWindow, from: nil))
        if over != pressed && pressed != nil && over == nil { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let target = button(at: convert(event.locationInWindow, from: nil))
        let wasPressed = pressed
        pressed = nil
        needsDisplay = true
        guard let target, target == wasPressed else { return }
        switch target {
        case .close: onClose?()
        case .collapse: onCollapse?()
        case .zoom: onZoom?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}
