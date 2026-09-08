import AppKit
import SwiftTerm

/// Caches one terminal's thumbnail and decides when it actually needs redrawing.
///
/// The fingerprint is the vector of per-row `BufferLine.generation` counters plus the scroll
/// position, size, and cursor. That catches in-place redraws (a progress bar rewriting one line),
/// scrolling, and alt-screen switches, while correctly reporting *no change* when bytes arrived
/// that changed nothing visible.
final class ThumbnailSource {
    private(set) var cached: CGImage?
    /// Exposed so tests can assert the overhead budget is respected.
    private(set) var renderCount = 0

    private var generations: [UInt64] = []
    private var lastTop = -1
    private var lastCols = 0
    private var lastRows = 0
    private var lastCursor = (x: -1, y: -1)
    private var lastScale: CGFloat = 0
    private var lastSize: CGSize = .zero
    private var lastBackground: NSColor?

    func invalidate() {
        generations = []
        lastCols = 0
        lastRows = 0
    }

    /// O(rows) integer comparisons, no allocation beyond the generation vector itself.
    func fingerprintChanged(_ terminal: Terminal) -> Bool {
        let rows = terminal.rows
        let cols = terminal.cols
        let top = terminal.getTopVisibleRow()
        let cursor = terminal.getCursorLocation()
        var changed = false
        if rows != lastRows || cols != lastCols || top != lastTop
            || cursor.x != lastCursor.x || cursor.y != lastCursor.y {
            changed = true
        }
        if generations.count != rows {
            generations = Array(repeating: 0, count: rows)
            changed = true
        }
        for r in 0..<rows {
            let g = terminal.getLine(row: r)?.generation ?? 0
            if generations[r] != g {
                generations[r] = g
                changed = true
            }
        }
        lastRows = rows
        lastCols = cols
        lastTop = top
        lastCursor = cursor
        return changed
    }

    /// Re-renders when the content, size, or backing scale changed. Returns the image to draw.
    @discardableResult
    func refresh(terminal: Terminal, size: CGSize, scale: CGFloat,
                 colors: TermsieConfig.Colors, showCursor: Bool,
                 background: NSColor? = nil, force: Bool = false) -> CGImage? {
        let geometryChanged = size != lastSize || scale != lastScale || background != lastBackground
        guard force || geometryChanged || fingerprintChanged(terminal) || cached == nil else {
            return cached
        }
        lastSize = size
        lastScale = scale
        lastBackground = background
        cached = ThumbnailRenderer.render(terminal: terminal, size: size, scale: scale,
                                          colors: colors, showCursor: showCursor,
                                          background: background)
        renderCount += 1
        return cached
    }

    func setRecipe(_ definition: TerminalDefinition, size: CGSize, scale: CGFloat,
                   colors: TermsieConfig.Colors, background: NSColor? = nil) -> CGImage? {
        if cached != nil, background == lastBackground { return cached }
        lastSize = size
        lastScale = scale
        lastBackground = background
        cached = ThumbnailRenderer.renderRecipe(definition: definition, size: size,
                                                scale: scale, colors: colors, background: background)
        return cached
    }
}
