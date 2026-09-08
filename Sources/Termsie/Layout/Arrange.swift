import AppKit

/// Layout helpers that give back the convenience the split tree used to provide.
/// Pure geometry over `(canvas, count) -> [NSRect]` so it can be reasoned about without views.
/// All rects are in the canvas's flipped space: y grows downward, so "top" is the smaller y.
enum Arrange {
    /// An even grid, preferring more columns than rows because screens are wide.
    /// Uses cumulative rounding so adjacent tiles share an exact edge with no seam.
    static func tileGrid(in canvas: NSRect, count n: Int) -> [NSRect] {
        guard n > 0 else { return [] }
        let cols = max(1, Int(ceil(sqrt(Double(n)))))
        let rows = max(1, Int(ceil(Double(n) / Double(cols))))
        var out: [NSRect] = []
        for i in 0..<n {
            let row = i / cols
            let inRow = i % cols
            // The last row stretches its tiles to fill the width.
            let k = (row == rows - 1) ? (n - row * cols) : cols
            let x0 = canvas.minX + (canvas.width * CGFloat(inRow) / CGFloat(k)).rounded()
            let x1 = canvas.minX + (canvas.width * CGFloat(inRow + 1) / CGFloat(k)).rounded()
            let y0 = canvas.minY + (canvas.height * CGFloat(row) / CGFloat(rows)).rounded()
            let y1 = canvas.minY + (canvas.height * CGFloat(row + 1) / CGFloat(rows)).rounded()
            out.append(NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        return out
    }

    /// Overlapping windows stepped down and to the right, wrapping when they run out of room.
    static func cascade(in canvas: NSRect, count n: Int) -> [NSRect] {
        guard n > 0 else { return [] }
        let step = PaneChrome.cascadeStep
        let w = max(PaneChrome.minSize.width, canvas.width * 0.72)
        let h = max(PaneChrome.minSize.height, canvas.height * 0.72)
        let slots = max(1, Int(min((canvas.width - w) / step, (canvas.height - h) / step)) + 1)
        return (0..<n).map { i in
            let s = CGFloat(i % slots)
            let wrap = CGFloat(i / slots)
            return NSRect(x: canvas.minX + s * step + wrap * step / 2,
                          y: canvas.minY + s * step + wrap * step / 2,
                          width: w, height: h)
        }
    }

    enum Half { case left, right, top, bottom, full, center }

    /// Halves tile the canvas exactly: floor plus subtraction leaves no rounding gap.
    static func half(_ which: Half, in c: NSRect) -> NSRect {
        let halfW = (c.width / 2).rounded(.down)
        let halfH = (c.height / 2).rounded(.down)
        switch which {
        case .left:   return NSRect(x: c.minX, y: c.minY, width: halfW, height: c.height)
        case .right:  return NSRect(x: c.minX + halfW, y: c.minY, width: c.width - halfW, height: c.height)
        case .top:    return NSRect(x: c.minX, y: c.minY, width: c.width, height: halfH)
        case .bottom: return NSRect(x: c.minX, y: c.minY + halfH, width: c.width, height: c.height - halfH)
        case .full:   return c
        case .center:
            let w = max(PaneChrome.minSize.width, c.width * 0.66)
            let h = max(PaneChrome.minSize.height, c.height * 0.66)
            return NSRect(x: c.midX - w / 2, y: c.midY - h / 2, width: w, height: h)
        }
    }

    /// Where to put a newly created terminal: the next free cascade slot, offset from whatever is
    /// already there so it never lands exactly on top of an existing window.
    static func nextSlot(in canvas: NSRect, existing: [NSRect]) -> NSRect {
        let w = max(PaneChrome.minSize.width, canvas.width * 0.62)
        let h = max(PaneChrome.minSize.height, canvas.height * 0.66)
        let step = PaneChrome.cascadeStep
        let maxSlots = max(1, Int(min((canvas.width - w) / step, (canvas.height - h) / step)) + 1)
        for slot in 0..<maxSlots {
            let r = NSRect(x: canvas.minX + CGFloat(slot) * step,
                           y: canvas.minY + CGFloat(slot) * step,
                           width: w, height: h)
            let taken = existing.contains { abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 }
            if !taken { return r }
        }
        return NSRect(x: canvas.minX, y: canvas.minY, width: w, height: h)
    }
}
