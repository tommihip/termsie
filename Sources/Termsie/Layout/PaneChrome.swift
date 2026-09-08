import AppKit

/// Which part of a floating terminal's frame the mouse is over.
enum ChromeZone {
    case move
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var resizesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var resizesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var resizesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var resizesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

    var cursor: NSCursor {
        switch self {
        case .move: return .openHand
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        // AppKit exposes no public diagonal resize cursor; the dominant axis reads fine.
        case .topLeft, .bottomRight, .topRight, .bottomLeft: return .resizeLeftRight
        }
    }
}

enum PaneChrome {
    /// The chrome ring around each terminal. This is real dead space, not an overlay: if we stole
    /// it back from the terminal view via hitTest, SwiftTerm's own I-beam cursor rect would sit on
    /// top of ours and win, showing a text cursor over the resize edge.
    static let border: CGFloat = 4
    /// Extra top strip that stays grabbable when headers are hidden.
    static let headlessGrip: CGFloat = 6
    /// Edge zones widen to this at the corners, the standard macOS window-frame feel.
    static let corner: CGFloat = 12
    static let minSize = NSSize(width: 180, height: 96)
    /// How much of a terminal must stay on the canvas when the window shrinks.
    static let keepVisible: CGFloat = 110
    static let snapThreshold: CGFloat = 8
    static let cascadeStep: CGFloat = 28

    /// Which zone a point in pane coordinates falls in. `nil` means the interior.
    /// The pane view is unflipped, so larger y is the top.
    static func zone(at p: NSPoint, in bounds: NSRect) -> ChromeZone? {
        let b = border, c = corner
        let left = p.x <= b, right = p.x >= bounds.maxX - b
        let bottom = p.y <= b, top = p.y >= bounds.maxY - b
        guard left || right || top || bottom else { return nil }
        let nearL = p.x <= c, nearR = p.x >= bounds.maxX - c
        let nearB = p.y <= c, nearT = p.y >= bounds.maxY - c
        if (left || right) && nearT { return left ? .topLeft : .topRight }
        if (left || right) && nearB { return left ? .bottomLeft : .bottomRight }
        if (top || bottom) && nearL { return top ? .topLeft : .bottomLeft }
        if (top || bottom) && nearR { return top ? .topRight : .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        return .bottom
    }

    /// Applies a drag delta to a starting frame for the given zone.
    /// Works in the canvas's flipped space, so `top` is the smaller y.
    static func propose(_ start: NSRect, zone: ChromeZone, delta: NSPoint) -> NSRect {
        var r = start
        switch zone {
        case .move:
            r.origin.x += delta.x
            r.origin.y += delta.y
            return r
        default:
            break
        }
        if zone.resizesLeft {
            let newX = min(start.minX + delta.x, start.maxX - minSize.width)
            r.size.width = start.maxX - newX
            r.origin.x = newX
        }
        if zone.resizesRight {
            r.size.width = max(minSize.width, start.width + delta.x)
        }
        if zone.resizesTop {
            let newY = min(start.minY + delta.y, start.maxY - minSize.height)
            r.size.height = start.maxY - newY
            r.origin.y = newY
        }
        if zone.resizesBottom {
            r.size.height = max(minSize.height, start.height + delta.y)
        }
        return r
    }
}

/// Terminal cell metrics, used to quantize resizes so the emulator only reflows when the grid
/// actually changes. Reflow is O(scrollback) and sends SIGWINCH, so doing it per mouse-move is
/// the single most expensive mistake available here.
enum TerminalMetrics {
    static func cellSize(for font: NSFont) -> CGSize {
        let ctFont = font as CTFont
        let h = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        var glyph = font.glyph(withName: "W")
        if glyph == 0 { glyph = font.glyph(withName: "n") }
        let w = glyph == 0 ? font.maximumAdvancement.width : font.advancement(forGlyph: glyph).width
        return CGSize(width: max(w.rounded(), 1), height: max(h, 1))
    }
}
