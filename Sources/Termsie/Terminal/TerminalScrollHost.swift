import AppKit
import SwiftTerm

/// Holds one terminal view inside a pane and supplies the two things SwiftTerm has no notion of:
/// the blank margin around the text, and sideways scrolling when lines are not wrapped.
///
/// SwiftTerm derives its column count straight from its own frame width and draws text hard against
/// that frame's edge, so padding here is simply a smaller frame inside a clipping host. "Do not
/// wrap" is the same trick in the other direction: a terminal genuinely discards whatever runs past
/// its last column, so the only way to keep a long line readable is to make the grid *wider* than
/// the pane and slide it. This view owns that offset and the scroller that drives it.
final class TerminalScrollHost: NSView {
    let terminalView: TermsieTerminalView

    var padding: CGFloat = 0 {
        didSet { if padding != oldValue { invalidate() } }
    }

    var wrapsLines = true {
        didSet {
            guard wrapsLines != oldValue else { return }
            if wrapsLines { scrollOffset = 0 }
            updateScrollMonitor()
            invalidate()
        }
    }

    var unwrappedColumns = 200 {
        didSet { if unwrappedColumns != oldValue, !wrapsLines { invalidate() } }
    }

    /// Painted into the margin the padding leaves around the terminal, so the gap belongs to the
    /// terminal rather than showing the window through it.
    var backgroundColor: NSColor = .clear {
        didSet { if backgroundColor != oldValue { needsDisplay = true } }
    }

    /// The horizontal scroller only earns its place when text actually runs past the right edge,
    /// so an unwrapped terminal showing nothing but short prompts looks like any other.
    /// Clips the terminal to the padded box. Without it the margin would only look like a margin
    /// while the offset was zero: a scrolled terminal would slide its text straight into the
    /// left-hand gap the padding is there to hold open.
    private let clip = NSView()
    private let scroller: NSScroller
    private var scrollOffset: CGFloat = 0
    private var maxOffset: CGFloat = 0
    private var scrollMonitor: Any?
    private var measuredColumns = 0
    private var measuredAt: CFTimeInterval = 0
    private var extentWork: DispatchWorkItem?
    private var wantsCursorReveal = false

    init(terminalView: TermsieTerminalView) {
        self.terminalView = terminalView
        // NSScroller reads its orientation off the frame it is born with, and there is no way to
        // set it afterwards, so this one has to start out wider than it is tall.
        scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizingMask = []
        terminalView.autoresizingMask = []
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.autoresizingMask = []
        clip.addSubview(terminalView)
        addSubview(clip)

        scroller.scrollerStyle = .overlay
        scroller.knobStyle = .light
        scroller.controlSize = .small
        scroller.isHidden = true
        scroller.target = self
        scroller.action = #selector(scrollerMoved)
        addSubview(scroller, positioned: .above, relativeTo: clip)

        // The caret is chased only after the shell has echoed the keystroke: at the moment the
        // byte is sent it is still sitting where it was before.
        terminalView.onUserInput = { [weak self] in
            self?.wantsCursorReveal = true
            self?.scheduleExtentUpdate()
        }
        terminalView.onOutput = { [weak self] in self?.scheduleExtentUpdate() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        extentWork?.cancel()
    }

    /// The monitor is a process-wide hook, so it is tied to being on screen rather than to this
    /// object's lifetime: a closed terminal must stop watching every scroll in the app at once,
    /// not whenever it happens to be released.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScrollMonitor()
    }

    private func invalidate() {
        needsLayout = true
        needsDisplay = true
        layoutSubtreeIfNeeded()
    }

    // MARK: Geometry

    /// The box the terminal itself gets, the pane's bounds less the padding on every side.
    private var textBox: NSRect {
        let p = min(padding, max(0, min(bounds.width, bounds.height) / 2 - 1))
        return bounds.insetBy(dx: p, dy: p)
    }

    /// SwiftTerm's own cell width, snapped the way it snaps it. Deriving this from the font again
    /// rather than asking the view keeps us one rounding rule away from a column-count mismatch,
    /// so it copies SwiftTerm's arithmetic exactly.
    private var cellWidth: CGFloat {
        let font = terminalView.font
        var glyph = font.glyph(withName: "W")
        if glyph == 0 { glyph = font.glyph(withName: "n") }
        let advance = glyph == 0 ? font.maximumAdvancement.width : font.advancement(forGlyph: glyph).width
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return max(1, (advance * scale).rounded() / scale)
    }

    /// The width the terminal view is given. Wrapped, that is the visible box; unwrapped, it is
    /// whatever holds `unwrappedColumns` columns.
    ///
    /// The unwrapped case is expressed as a *delta* from SwiftTerm's own optimal size rather than
    /// computed from scratch, because SwiftTerm reserves an unpublished strip on the right for its
    /// vertical scroller. Borrowing its arithmetic means never having to guess that strip's width,
    /// and the expression settles after one layout pass: once the grid is the width we asked for,
    /// `getOptimalFrameSize` returns exactly what we return here.
    private func contentWidth(in box: NSRect) -> CGFloat {
        guard !wrapsLines else { return box.width }
        let cols = terminalView.getTerminal().cols
        let optimal = terminalView.getOptimalFrameSize().width
        guard cols > 0, optimal > 0 else {
            return max(box.width, CGFloat(unwrappedColumns) * cellWidth)
        }
        return max(box.width, optimal + CGFloat(unwrappedColumns - cols) * cellWidth)
    }

    override func layout() {
        super.layout()
        let box = textBox
        guard box.width > 0, box.height > 0 else { return }
        let width = contentWidth(in: box)
        maxOffset = max(0, width - box.width)
        scrollOffset = min(max(scrollOffset, 0), maxOffset)

        if clip.frame != box { clip.frame = box }
        let frame = NSRect(x: -scrollOffset, y: 0, width: width, height: box.height)
        if terminalView.frame != frame { terminalView.frame = frame }
        updateScroller()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard backgroundColor.alphaComponent > 0 else { return }
        backgroundColor.setFill()
        // Only the margin is painted. Filling the whole thing and letting the terminal draw over
        // it would composite two translucent backgrounds and make the pane darker than it asked
        // to be, which is exactly what a user lowering the opacity would notice first.
        for rect in Self.margins(around: clip.frame, in: bounds) {
            rect.intersection(dirtyRect).fill()
        }
    }

    /// The up-to-four strips of `outer` that `inner` does not cover.
    static func margins(around inner: NSRect, in outer: NSRect) -> [NSRect] {
        let hole = inner.intersection(outer)
        guard !hole.isEmpty else { return [outer] }
        var rects: [NSRect] = []
        if hole.minY > outer.minY {
            rects.append(NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: hole.minY - outer.minY))
        }
        if hole.maxY < outer.maxY {
            rects.append(NSRect(x: outer.minX, y: hole.maxY, width: outer.width, height: outer.maxY - hole.maxY))
        }
        if hole.minX > outer.minX {
            rects.append(NSRect(x: outer.minX, y: hole.minY, width: hole.minX - outer.minX, height: hole.height))
        }
        if hole.maxX < outer.maxX {
            rects.append(NSRect(x: hole.maxX, y: hole.minY, width: outer.maxX - hole.maxX, height: hole.height))
        }
        return rects
    }

    // MARK: Horizontal scrolling

    /// The rightmost column the visible rows actually reach.
    ///
    /// Measured over the rows on screen only: those are the ones the scrollbar is describing, and
    /// re-measuring the whole scrollback would cost more than the scrollbar is worth. Trailing
    /// spaces are not content — a shell that clears a line by writing blanks over it would
    /// otherwise make every row look full width.
    private func measureContentColumns() -> Int {
        let terminal = terminalView.getTerminal()
        let capture = TerminalTextCapture(terminal)
        let top = capture.screenTopRow
        var widest = 0
        for row in top..<(top + terminal.rows) {
            guard let line = capture.line(at: row) else { break }
            var text = line.translateToString(trimRight: true)
            while text.hasSuffix(" ") { text.removeLast() }
            widest = max(widest, text.count)
        }
        return widest
    }

    /// The measurement above, recomputed at most a few times a second. `layout()` asks for it on
    /// every event of a resize drag, and walking the screen that often would be the expensive part
    /// of a feature that is otherwise free.
    var contentColumns: Int {
        let now = CACurrentMediaTime()
        if now - measuredAt < 0.15 { return measuredColumns }
        measuredAt = now
        measuredColumns = measureContentColumns()
        return measuredColumns
    }

    /// How far past the visible box that content reaches.
    private var contentOverflow: CGFloat {
        guard maxOffset > 0 else { return 0 }
        let used = CGFloat(contentColumns) * cellWidth
        return max(0, min(maxOffset, used - textBox.width))
    }

    private func updateScroller() {
        let box = textBox
        let overflow = contentOverflow
        let height = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
        scroller.frame = NSRect(x: box.minX, y: box.minY, width: box.width, height: height)
        scroller.isHidden = overflow <= 0
        guard !scroller.isHidden else { return }
        let span = box.width + overflow
        scroller.knobProportion = span > 0 ? box.width / span : 1
        scroller.doubleValue = overflow > 0 ? Double(min(scrollOffset, overflow) / overflow) : 0
    }

    /// Re-reads how far the content reaches after a burst of output, and chases the caret if the
    /// user was the one who caused it.
    ///
    /// Debounced rather than run per burst: a command that prints for a second would otherwise
    /// walk the screen on every chunk, and the scrollbar only has to be right once the output
    /// stops. One work item is reused, so a long stream schedules exactly one measurement.
    func scheduleExtentUpdate() {
        guard !wrapsLines, extentWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.extentWork = nil
            self.measuredAt = 0
            self.updateScroller()
            if self.wantsCursorReveal {
                self.wantsCursorReveal = false
                self.revealCursor()
            }
        }
        extentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Sideways gestures have to be caught before AppKit delivers them, because SwiftTerm's
    /// `scrollWheel` is not `open` — and it returns early on a pure horizontal swipe without
    /// passing the event up the responder chain, so there is nothing left to catch afterwards.
    /// The monitor only exists while this terminal actually scrolls sideways.
    private func updateScrollMonitor() {
        if wrapsLines || window == nil {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        } else if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                (self?.consume(event) ?? false) ? nil : event
            }
        }
    }

    private func consume(_ event: NSEvent) -> Bool {
        guard let window, event.window === window,
              // hitTest rather than a bounds check, so the front terminal wins where two overlap.
              let hit = window.contentView?.hitTest(event.locationInWindow),
              hit.isDescendant(of: self) else { return false }
        let shifted = event.modifierFlags.contains(.shift)
        let sideways = shifted ? event.scrollingDeltaY : event.scrollingDeltaX
        let along = shifted ? event.scrollingDeltaX : event.scrollingDeltaY
        guard abs(sideways) > abs(along) else { return false }
        return scrollBy(-sideways)
    }

    @discardableResult
    func scrollBy(_ delta: CGFloat) -> Bool {
        guard maxOffset > 0 else { return false }
        let limit = contentOverflow
        guard limit > 0 else { return false }
        let next = min(max(scrollOffset + delta, 0), limit)
        guard next != scrollOffset else { return false }
        setOffset(next)
        return true
    }

    private func setOffset(_ offset: CGFloat) {
        scrollOffset = offset
        needsLayout = true
        needsDisplay = true
        layoutSubtreeIfNeeded()
    }

    @objc private func scrollerMoved() {
        let limit = contentOverflow
        guard limit > 0 else { return }
        switch scroller.hitPart {
        case .decrementPage: setOffset(max(0, scrollOffset - textBox.width))
        case .incrementPage: setOffset(min(limit, scrollOffset + textBox.width))
        case .decrementLine: setOffset(max(0, scrollOffset - cellWidth * 4))
        case .incrementLine: setOffset(min(limit, scrollOffset + cellWidth * 4))
        default: setOffset(min(limit, CGFloat(scroller.doubleValue) * limit))
        }
    }

    /// Keeps the caret on screen while typing. Without this an unwrapped terminal would let a long
    /// command run off the right edge and take the cursor with it.
    func revealCursor() {
        guard !wrapsLines, maxOffset > 0 else { return }
        let column = terminalView.getTerminal().getCursorLocation().x
        let cell = cellWidth
        let box = textBox
        let caretMin = CGFloat(column) * cell
        let caretMax = caretMin + cell
        var next = scrollOffset
        if caretMax > scrollOffset + box.width { next = caretMax - box.width }
        if caretMin < scrollOffset { next = caretMin }
        next = min(max(next, 0), maxOffset)
        guard next != scrollOffset else { return }
        setOffset(next)
    }

    // MARK: Introspection

    /// Whether the horizontal scrollbar is on screen, for headless assertions.
    var showsHorizontalScroller: Bool { !scroller.isHidden }
    var horizontalOffset: CGFloat { scrollOffset }
}
