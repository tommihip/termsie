import AppKit

/// The area terminals float in. Replaces the old nested split tree.
///
/// Two invariants hold this together:
///
/// 1. **Fractional frames are the source of truth.** Pixel frames are derived from them on every
///    resize. Clamping a terminal to fit a small window never writes back to the fraction, so
///    shrinking then re-growing the window is exactly idempotent instead of drifting.
/// 2. **Z-order changes never detach a view.** Terminals are Metal-backed; removing and re-adding
///    one would churn `viewDidMoveToWindow` and disturb its CAMetalLayer binding.
final class PaneCanvasView: NSView {
    weak var controller: TerminalWindowController?

    /// Terminals in stable creation order. This drives numbering; stacking lives in `subviews`.
    private(set) var panes: [TerminalPane] = []
    private var nextZ = 1

    /// Shown when every terminal is closed but the window still has saved ones.
    var emptyMessage: String? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }


    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let colors = ConfigStore.shared.config.colors
        // Only a wash, not a fill: the window's blurred backdrop has to show through here.
        if ConfigStore.shared.config.blurBackground {
            NSColor.hex(colors.background).withAlphaComponent(0.25).setFill()
        } else {
            NSColor.hex(colors.background).setFill()
        }
        bounds.fill()
        guard let message = emptyMessage, panes.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFonts.system(size: 13),
            .foregroundColor: NSColor.hex(colors.headerText),
        ]
        let s = NSAttributedString(string: message, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    // MARK: Cursor
    //
    // Cursor rects, the usual mechanism, are resolved per view without regard to what is drawn on
    // top, so with terminals that overlap they let a background terminal claim the pointer over the
    // header of the one in front. They are disabled window-wide; `SidebarContainerView` owns the
    // pointer and asks this for canvas points. `hitTest` then gives the same answer that click
    // handling already gives.

    /// The pointer shape for a canvas point.
    ///
    /// `hitTest` walks subviews front to back, so the terminal actually visible at that point is
    /// the one consulted, and its chrome wins over anything drawn behind it.
    func cursor(at point: NSPoint) -> NSCursor {
        // Walk up from the deepest view, because a hit inside a terminal usually lands on one of
        // SwiftTerm's own subviews (the caret, the scroller) rather than the terminal itself.
        var view = hitTestSubviews(point)
        while let current = view {
            if current is TermsieTerminalView { return .iBeam }
            if current is NSTextView { return .iBeam }
            if let field = current as? NSTextField, field.isEditable { return .iBeam }
            if let pane = current as? TerminalPane {
                return pane.cursor(at: pane.convert(point, from: self))
            }
            view = current.superview
        }
        return .arrow
    }

    /// The terminal visible at a canvas point, or nil for bare canvas.
    func topmostPane(at point: NSPoint) -> TerminalPane? {
        var view: NSView? = hitTestSubviews(point)
        while let current = view, !(current is TerminalPane) { view = current.superview }
        return view as? TerminalPane
    }

    /// The deepest view at a point given in *this* view's coordinates.
    ///
    /// `NSView.hitTest` takes a point in the receiver's **superview** coordinates, so it is asked
    /// of each subview in turn instead. Reversed, because subviews run back to front.
    private func hitTestSubviews(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(point) { return hit }
        }
        return nil
    }

    // MARK: Membership

    func add(_ pane: TerminalPane, fraction: NSRect) {
        pane.autoresizingMask = []
        pane.layoutFraction = clampFraction(fraction)
        pane.zIndex = nextZ
        nextZ += 1
        panes.append(pane)
        addSubview(pane)
        applyFractions()
        reorderZ()
        needsDisplay = true
    }

    func remove(_ pane: TerminalPane) {
        panes.removeAll { $0 === pane }
        pane.removeFromSuperview()
        needsDisplay = true
    }

    // MARK: Z-order

    /// Brings a terminal to the front without detaching it from the hierarchy.
    func raise(_ pane: TerminalPane) {
        // Almost every click lands on the frontmost terminal already, so this early-return means
        // an in-flight SwiftTerm selection drag is essentially never disturbed by reordering.
        guard subviews.last !== pane else { return }
        pane.zIndex = nextZ
        nextZ += 1
        reorderZ()
    }

    func sendToBack(_ pane: TerminalPane) {
        let lowest = panes.map(\.zIndex).min() ?? 0
        pane.zIndex = lowest - 1
        reorderZ()
    }

    private func reorderZ() {
        // sortSubviews reorders in place: no removeFromSuperview, so the Metal layer's window
        // binding, the first responder, and SwiftTerm's tracking areas are all left alone.
        sortSubviews({ a, b, _ in
            let za = (a as? TerminalPane)?.zIndex ?? Int.min
            let zb = (b as? TerminalPane)?.zIndex ?? Int.min
            if za < zb { return .orderedAscending }
            if za > zb { return .orderedDescending }
            return .orderedSame
        }, context: nil)
    }

    // MARK: Geometry

    private func clampFraction(_ f: NSRect) -> NSRect {
        var r = f
        r.size.width = min(max(r.width, 0.05), 1)
        r.size.height = min(max(r.height, 0.05), 1)
        r.origin.x = min(max(r.minX, -0.5), 1 - 0.05)
        r.origin.y = min(max(r.minY, 0), 1 - 0.05)
        return r
    }

    func rect(for fraction: NSRect) -> NSRect {
        let c = bounds
        var r = NSRect(x: c.minX + fraction.minX * c.width,
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

    func fraction(for rect: NSRect) -> NSRect {
        let c = bounds
        guard c.width > 0, c.height > 0 else { return NSRect(x: 0, y: 0, width: 1, height: 1) }
        return NSRect(x: (rect.minX - c.minX) / c.width,
                      y: (rect.minY - c.minY) / c.height,
                      width: rect.width / c.width,
                      height: rect.height / c.height)
    }

    /// Re-derives every pixel frame from its fraction. Deliberately ignores the old size.
    func applyFractions() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        for pane in panes {
            var r = rect(for: pane.layoutFraction)
            // A rolled-up terminal keeps its stored fraction untouched, so expanding restores the
            // exact size it had before.
            if pane.isCollapsed { r.size.height = pane.collapsedHeight }
            if pane.frame != r { pane.frame = r }
        }
    }

    /// Records a terminal's current pixel frame back into its fraction. Called once at the end of a
    /// gesture or an arrange command, never from clamping.
    func commitFraction(for pane: TerminalPane) {
        var f = clampFraction(fraction(for: pane.frame))
        // Never record the rolled-up height as the terminal's real size.
        if pane.isCollapsed { f.size.height = pane.layoutFraction.height }
        pane.layoutFraction = f
        controller?.canvasGeometryChanged(pane)
    }

    func setFraction(_ f: NSRect, for pane: TerminalPane, commit: Bool = true) {
        pane.layoutFraction = clampFraction(f)
        let r = rect(for: pane.layoutFraction)
        if pane.frame != r { pane.frame = r }
        if commit { controller?.canvasGeometryChanged(pane) }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutForWindowResize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutForWindowResize()
    }

    /// How the terminals respond when the window itself changes size.
    ///
    /// Scaling re-derives every frame from its fraction, so the arrangement is preserved
    /// proportionally. Holding still keeps the pixel frames and instead rewrites the fractions to
    /// match, which keeps "the fraction is the source of truth" true in both modes.
    private func layoutForWindowResize() {
        if ConfigStore.shared.config.resizeTerminalsWithWindow {
            applyFractions()
        } else {
            holdTerminalsInPlace()
        }
    }

    private func holdTerminalsInPlace() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        for pane in panes {
            var r = pane.frame
            // Terminals keep their size, but a shrinking window must not leave one unreachable.
            let keep = PaneChrome.keepVisible
            r.origin.x = min(max(r.minX, bounds.minX - max(0, r.width - keep)), max(bounds.minX, bounds.maxX - keep))
            r.origin.y = min(max(r.minY, bounds.minY), max(bounds.minY, bounds.maxY - min(keep, r.height)))
            if pane.isCollapsed { r.size.height = pane.collapsedHeight }
            if pane.frame != r { pane.frame = r }
            var f = fraction(for: pane.frame)
            if pane.isCollapsed { f.size.height = pane.layoutFraction.height }
            pane.layoutFraction = clampFraction(f)
        }
    }

    // MARK: Snapping

    /// Snap targets are recomputed from the raw proposed frame on every event, so stickiness comes
    /// out naturally with no hysteresis state to keep straight.
    func resolve(_ proposed: NSRect, for pane: TerminalPane, zone: ChromeZone, snapping: Bool) -> NSRect {
        guard snapping else { return proposed }
        let t = PaneChrome.snapThreshold
        var r = proposed

        var xTargets: [CGFloat] = [bounds.minX, bounds.maxX]
        var yTargets: [CGFloat] = [bounds.minY, bounds.maxY]
        for other in panes where other !== pane {
            let o = other.frame
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

    // MARK: Arrange

    func tileGrid() {
        let frames = Arrange.tileGrid(in: bounds, count: panes.count)
        for (pane, frame) in zip(panes, frames) {
            pane.clearZoom()
            setFraction(fraction(for: frame), for: pane, commit: false)
        }
        controller?.canvasGeometryChanged(nil)
    }

    func cascade() {
        let frames = Arrange.cascade(in: bounds, count: panes.count)
        for (pane, frame) in zip(panes, frames) {
            pane.clearZoom()
            setFraction(fraction(for: frame), for: pane, commit: false)
        }
        for pane in panes { raise(pane) }
        controller?.canvasGeometryChanged(nil)
    }

    func place(_ pane: TerminalPane, _ half: Arrange.Half) {
        pane.clearZoom()
        setFraction(fraction(for: Arrange.half(half, in: bounds)), for: pane)
        raise(pane)
    }

    var occupiedFrames: [NSRect] { panes.map(\.frame) }
}
