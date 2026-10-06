import Foundation

/// The arithmetic of the floating canvas, independent of any view system: fractional frames to
/// pixel frames and back, keeping terminals reachable when the canvas shrinks, and edge snapping.
///
/// The same rules as the macOS canvas:
///
/// 1. **Fractional frames are the source of truth.** Pixel frames are derived from them on every
///    resize. Clamping a terminal to fit a small canvas never writes back to the fraction, so
///    shrinking then re-growing is exactly idempotent instead of drifting.
/// 2. Snap targets are recomputed from the raw proposed frame on every event, so stickiness comes
///    out naturally with no hysteresis state.
///
/// All rects are in flipped space: y grows downward, so "top" is the smaller y.
public struct CanvasGeometry {
    public var bounds: CGRect

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    public static func clampFraction(_ f: CGRect) -> CGRect {
        var r = f
        r.size.width = min(max(r.width, 0.05), 1)
        r.size.height = min(max(r.height, 0.05), 1)
        r.origin.x = min(max(r.minX, -0.5), 1 - 0.05)
        r.origin.y = min(max(r.minY, 0), 1 - 0.05)
        return r
    }

    /// The pixel frame for a fraction, kept at least `PaneChrome.keepVisible` on the canvas.
    public func rect(for fraction: CGRect) -> CGRect {
        let c = bounds
        var r = CGRect(x: c.minX + fraction.minX * c.width,
                       y: c.minY + fraction.minY * c.height,
                       width: fraction.width * c.width,
                       height: fraction.height * c.height)
        r.size.width = min(max(r.width, PaneChrome.minSize.width), max(c.width, PaneChrome.minSize.width))
        r.size.height = min(max(r.height, PaneChrome.minSize.height), max(c.height, PaneChrome.minSize.height))
        let keep = PaneChrome.keepVisible
        r.origin.x = min(max(r.minX, c.minX - max(0, r.width - keep)), max(c.minX, c.maxX - keep))
        r.origin.y = min(max(r.minY, c.minY), max(c.minY, c.maxY - min(keep, r.height)))
        return r.integral
    }

    public func fraction(for rect: CGRect) -> CGRect {
        let c = bounds
        guard c.width > 0, c.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (rect.minX - c.minX) / c.width,
                      y: (rect.minY - c.minY) / c.height,
                      width: rect.width / c.width,
                      height: rect.height / c.height)
    }

    /// A frame held still while the canvas shrinks, moved only as far as keeps it reachable.
    public func keepingReachable(_ frame: CGRect) -> CGRect {
        var r = frame
        let keep = PaneChrome.keepVisible
        r.origin.x = min(max(r.minX, bounds.minX - max(0, r.width - keep)), max(bounds.minX, bounds.maxX - keep))
        r.origin.y = min(max(r.minY, bounds.minY), max(bounds.minY, bounds.maxY - min(keep, r.height)))
        return r
    }

    /// Snaps the edges being dragged to the canvas edges and to the edges of terminals alongside.
    public func resolve(_ proposed: CGRect, others: [CGRect], zone: ChromeZone, snapping: Bool) -> CGRect {
        guard snapping else { return proposed }
        let t = PaneChrome.snapThreshold
        var r = proposed

        var xTargets: [CGFloat] = [bounds.minX, bounds.maxX]
        var yTargets: [CGFloat] = [bounds.minY, bounds.maxY]
        for o in others {
            // Only peers we actually run alongside should tug; a terminal in the far corner should not.
            if o.minY - t < r.maxY && o.maxY + t > r.minY { xTargets.append(contentsOf: [o.minX, o.maxX]) }
            if o.minX - t < r.maxX && o.maxX + t > r.minX { yTargets.append(contentsOf: [o.minY, o.maxY]) }
        }

        // Sources are the edges actually being dragged, so a left-edge resize never snaps the right edge.
        var xSources: [CGFloat] = []
        var ySources: [CGFloat] = []
        switch zone {
        case .move:
            xSources = [r.minX, r.maxX]
            ySources = [r.minY, r.maxY]
        default:
            if zone.resizesLeft { xSources.append(r.minX) }
            if zone.resizesRight { xSources.append(r.maxX) }
            if zone.resizesTop { ySources.append(r.minY) }
            if zone.resizesBottom { ySources.append(r.maxY) }
        }

        func bestDelta(sources: [CGFloat], targets: [CGFloat]) -> CGFloat? {
            var best: CGFloat?
            for s in sources {
                for target in targets {
                    let d = target - s
                    if abs(d) <= t, best == nil || abs(d) < abs(best!) { best = d }
                }
            }
            return best
        }

        if let dx = bestDelta(sources: xSources, targets: xTargets) {
            if zone == .move { r.origin.x += dx }
            else if zone.resizesLeft { r.size.width -= dx; r.origin.x += dx }
            else if zone.resizesRight { r.size.width += dx }
        }
        if let dy = bestDelta(sources: ySources, targets: yTargets) {
            if zone == .move { r.origin.y += dy }
            else if zone.resizesTop { r.size.height -= dy; r.origin.y += dy }
            else if zone.resizesBottom { r.size.height += dy }
        }
        r.size.width = max(r.width, PaneChrome.minSize.width)
        r.size.height = max(r.height, PaneChrome.minSize.height)
        return r
    }

    public enum Direction { case left, right, up, down }

    /// The frame to move focus to from `active` in a direction: a cone plus distance, which keeps
    /// working once terminals overlap. Returns an index into `candidates`.
    public static func neighbor(of active: CGRect, in candidates: [CGRect], direction: Direction) -> Int? {
        let ac = CGPoint(x: active.midX, y: active.midY)
        func overlapX(_ r: CGRect) -> CGFloat { min(active.maxX, r.maxX) - max(active.minX, r.minX) }
        func overlapY(_ r: CGRect) -> CGFloat { min(active.maxY, r.maxY) - max(active.minY, r.minY) }
        func pick(slope: CGFloat) -> Int? {
            var best: (Int, CGFloat)?
            for (i, r) in candidates.enumerated() {
                let dx = r.midX - ac.x, dy = r.midY - ac.y
                let along: CGFloat, across: CGFloat, overlap: CGFloat
                switch direction {
                case .left: along = -dx; across = abs(dy); overlap = overlapY(r)
                case .right: along = dx; across = abs(dy); overlap = overlapY(r)
                case .up: along = -dy; across = abs(dx); overlap = overlapX(r)
                case .down: along = dy; across = abs(dx); overlap = overlapX(r)
                }
                guard along > 1, across <= along * slope else { continue }
                let score = along + across * 0.5 - max(overlap, 0) * 0.25
                if best == nil || score < best!.1 { best = (i, score) }
            }
            return best?.0
        }
        return pick(slope: 1.0) ?? pick(slope: 3.0)
    }
}
