import Foundation

/// Which part of a floating terminal's frame the mouse is over.
public enum ChromeZone {
    case move
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    public var resizesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    public var resizesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    public var resizesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    public var resizesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

}

public enum PaneChrome {
    /// The chrome ring around each terminal. This is real dead space, not an overlay: if we stole
    /// it back from the terminal view via hitTest, SwiftTerm's own I-beam cursor rect would sit on
    /// top of ours and win, showing a text cursor over the resize edge.
    public static let border: CGFloat = 4
    /// Extra top strip that stays grabbable when headers are hidden.
    public static let headlessGrip: CGFloat = 6
    /// Edge zones widen to this at the corners, the standard window-frame feel.
    public static let corner: CGFloat = 12
    public static let minSize = NSSize(width: 180, height: 96)
    /// How much of a terminal must stay on the canvas when the window shrinks.
    public static let keepVisible: CGFloat = 110
    public static let snapThreshold: CGFloat = 8
    public static let cascadeStep: CGFloat = 28

    /// Which zone a point in pane coordinates falls in. `nil` means the interior.
    /// AppKit's pane view is unflipped, so larger y is the top; pass `flipped` where y grows down.
    public static func zone(at p: NSPoint, in bounds: NSRect, flipped: Bool = false) -> ChromeZone? {
        let b = border, c = corner
        let left = p.x <= bounds.minX + b, right = p.x >= bounds.maxX - b
        let low = p.y <= bounds.minY + b, high = p.y >= bounds.maxY - b
        let bottom = flipped ? high : low, top = flipped ? low : high
        guard left || right || top || bottom else { return nil }
        let nearL = p.x <= bounds.minX + c, nearR = p.x >= bounds.maxX - c
        let nearLow = p.y <= bounds.minY + c, nearHigh = p.y >= bounds.maxY - c
        let nearB = flipped ? nearHigh : nearLow, nearT = flipped ? nearLow : nearHigh
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
    public static func propose(_ start: NSRect, zone: ChromeZone, delta: NSPoint) -> NSRect {
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
