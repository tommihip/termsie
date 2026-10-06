import Foundation
import WinSDK
import CTermsieWin
import SwiftTerm
import TermsieCore

/// The colours a terminal is drawn with, resolved from the config and the environment tint.
struct TerminalPalette {
    var foreground: RGBA
    var background: RGBA
    var cursor: RGBA
    var selection: RGBA
    var ansi: [RGBA]

    init(config: TermsieConfig, background: RGBA) {
        foreground = RGBA.hex(config.colors.foreground)
        self.background = background
        cursor = RGBA.hex(config.colors.cursor)
        selection = RGBA.hex(config.colors.selection)
        ansi = config.colors.ansi.map { RGBA.hex($0) }
    }

    func color(_ c: Attribute.Color, foreground isForeground: Bool, bold: Bool = false) -> RGBA {
        switch c {
        case .defaultColor:
            return isForeground ? foreground : background
        case .defaultInvertedColor:
            return isForeground ? background : foreground
        case .ansi256(let code):
            var i = Int(code)
            // Bold text in one of the first eight colours uses its bright variant, as xterm does.
            if bold && isForeground && i < 8 { i += 8 }
            return RGBA.ansi256(i, palette: ansi)
        case .trueColor(let r, let g, let b):
            return RGBA(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
        }
    }
}

/// The four faces a terminal draws with, and the cell they share.
struct TerminalFonts {
    let regular: Font
    let bold: Font
    let italic: Font
    let boldItalic: Font
    let metrics: CellMetrics

    init(family: String, size: Double, dpi: Float) {
        regular = FontCache.font(family, size)
        bold = FontCache.font(family, size, bold: true)
        italic = FontCache.font(family, size, italic: true)
        boldItalic = FontCache.font(family, size, bold: true, italic: true)
        metrics = regular.metrics(dpi: dpi)
    }

    func face(bold b: Bool, italic i: Bool) -> Font {
        switch (b, i) {
        case (false, false): return regular
        case (true, false): return bold
        case (false, true): return italic
        case (true, true): return boldItalic
        }
    }
}

/// A search hit on screen, in buffer line and column terms.
struct TextMatch: Equatable {
    var line: Int
    var start: Int
    var end: Int   // exclusive
}

/// Draws a terminal's visible screen from its character buffer.
enum TerminalPainter {
    struct Options {
        var focused: Bool
        /// False during the "off" half of a blinking cursor.
        var cursorPhaseOn: Bool
        /// The first grid column drawn, for a terminal that does not wrap and has scrolled sideways.
        var firstColumn: Int = 0
        var matches: [TextMatch] = []
        var currentMatch: TextMatch?
    }

    private struct RunStyle: Equatable {
        var color: RGBA
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var strike: Bool
    }

    static func draw(_ session: TerminalSession, in rect: CGRect, renderer: Renderer, fonts: TerminalFonts,
                     palette: TerminalPalette, options: Options) {
        let terminal = session.terminal!
        let m = fonts.metrics
        let rows = terminal.rows
        let cols = terminal.cols
        let first = max(0, min(options.firstColumn, cols - 1))
        let visibleCols = max(1, min(cols - first, Int((rect.width / m.cellWidth).rounded(.up)) + 1))
        let lastCol = min(cols, first + visibleCols)
        let topLine = session.viewTopLine

        renderer.clipped(rect) {
            for r in 0..<rows {
                guard let line = session.visibleLine(r) else { continue }
                let y = rect.minY + CGFloat(r) * m.cellHeight
                guard y < rect.maxY else { break }
                drawRow(line, terminal: terminal, y: y, x0: rect.minX, first: first, last: min(lastCol, line.count),
                        renderer: renderer, fonts: fonts, palette: palette)
            }

            drawMatches(options, topLine: topLine, rows: rows, rect: rect, first: first, metrics: m, renderer: renderer)
            drawSelection(session, topLine: topLine, rows: rows, cols: cols, rect: rect, first: first,
                          metrics: m, renderer: renderer, palette: palette)
            drawCursor(session, rect: rect, first: first, renderer: renderer, fonts: fonts, palette: palette,
                       options: options)
        }
    }

    private static func drawRow(_ line: BufferLine, terminal: Terminal, y: CGFloat, x0: CGFloat, first: Int, last: Int,
                                renderer: Renderer, fonts: TerminalFonts, palette: TerminalPalette) {
        let m = fonts.metrics
        guard last > first else { return }

        // Backgrounds: one fill per run of a non-default colour.
        var runStart = first
        var runColor: RGBA?
        func flushBackground(_ end: Int) {
            if let c = runColor, end > runStart {
                renderer.fill(CGRect(x: x0 + CGFloat(runStart - first) * m.cellWidth, y: y,
                                     width: CGFloat(end - runStart) * m.cellWidth, height: m.cellHeight), TWColor(c))
            }
        }
        for c in first..<last {
            let attr = line[c].attribute
            let bg: RGBA?
            if attr.style.contains(.inverse) {
                bg = palette.color(attr.fg, foreground: true, bold: attr.style.contains(.bold))
            } else if attr.bg == .defaultColor {
                bg = nil   // the pane's own background, already drawn with its opacity
            } else {
                bg = palette.color(attr.bg, foreground: false)
            }
            if bg != runColor {
                flushBackground(c)
                runStart = c
                runColor = bg
            }
        }
        flushBackground(last)

        // Text: runs of one style, each character pinned to its cell.
        var units: [WCHAR] = []
        var widths: [UInt8] = []
        var textStart = first
        var style: RunStyle?
        func flushText() {
            guard let s = style, !units.isEmpty else { units.removeAll(); widths.removeAll(); return }
            let origin = CGPoint(x: x0 + CGFloat(textStart - first) * m.cellWidth, y: y)
            renderer.cells(units, widths: widths, at: origin, font: fonts.face(bold: s.bold, italic: s.italic),
                           metrics: m, color: TWColor(s.color))
            let columns = widths.reduce(0) { $0 + Int($1) }
            let width = CGFloat(columns) * m.cellWidth
            if s.underline {
                renderer.fill(CGRect(x: origin.x, y: y + min(m.underlineY, m.cellHeight - m.underlineThickness),
                                     width: width, height: m.underlineThickness), TWColor(s.color))
            }
            if s.strike {
                renderer.fill(CGRect(x: origin.x, y: y + (m.baseline * 0.62).rounded(),
                                     width: width, height: m.underlineThickness), TWColor(s.color))
            }
            units.removeAll(keepingCapacity: true)
            widths.removeAll(keepingCapacity: true)
        }

        var c = first
        while c < last {
            let cell = line[c]
            let cellWidth = max(Int(cell.width), 1)
            if cell.width == 0 { c += 1; continue }   // the second half of a wide character
            let attr = cell.attribute
            let s = attr.style
            let ch = terminal.getCharacter(for: cell)
            let blank = ch == "\u{0}" || ch == " " || s.contains(.invisible)
            if blank {
                flushText()
                style = nil
                c += cellWidth
                continue
            }
            var fg = palette.color(attr.fg, foreground: true, bold: s.contains(.bold))
            if s.contains(.inverse) { fg = palette.color(attr.bg, foreground: false) }
            if s.contains(.dim) { fg = fg.blended(withFraction: 0.45, of: palette.background) }
            let runStyle = RunStyle(color: fg, bold: s.contains(.bold), italic: s.contains(.italic),
                                    underline: s.contains(.underline) || attr.underlineStyle != .none,
                                    strike: s.contains(.crossedOut))
            if runStyle != style {
                flushText()
                style = runStyle
                textStart = c
            }
            if units.isEmpty { textStart = c }
            appendCharacter(ch, cells: cellWidth, units: &units, widths: &widths)
            c += cellWidth
        }
        flushText()
    }

    /// Adds one grid character: its first code unit takes the cell width, the rest none.
    private static func appendCharacter(_ ch: Character, cells: Int, units: inout [WCHAR], widths: inout [UInt8]) {
        if let ascii = ch.asciiValue {
            units.append(WCHAR(ascii))
            widths.append(UInt8(cells))
            return
        }
        var firstUnit = true
        for unit in String(ch).utf16 {
            units.append(unit)
            widths.append(firstUnit ? UInt8(cells) : 0)
            firstUnit = false
        }
    }

    private static func drawSelection(_ session: TerminalSession, topLine: Int, rows: Int, cols: Int, rect: CGRect,
                                      first: Int, metrics m: CellMetrics, renderer: Renderer, palette: TerminalPalette) {
        guard let sel = session.selection, sel.active, sel.hasSelectionRange else { return }
        var a = sel.start, b = sel.end
        if Position.compare(a, b) == .after { swap(&a, &b) }
        let color = TWColor(palette.selection, alpha: 0.75)
        for r in 0..<rows {
            let line = topLine + r
            guard line >= a.row, line <= b.row else { continue }
            var from = line == a.row ? a.col : 0
            var to = line == b.row ? b.col : cols
            if sel.selectionMode == .row || sel.selectingRows { from = 0; to = cols }
            from = max(from, first)
            guard to > from else { continue }
            renderer.fill(CGRect(x: rect.minX + CGFloat(from - first) * m.cellWidth,
                                 y: rect.minY + CGFloat(r) * m.cellHeight,
                                 width: CGFloat(to - from) * m.cellWidth, height: m.cellHeight), color)
        }
    }

    private static func drawMatches(_ options: Options, topLine: Int, rows: Int, rect: CGRect, first: Int,
                                    metrics m: CellMetrics, renderer: Renderer) {
        guard !options.matches.isEmpty else { return }
        for match in options.matches {
            let r = match.line - topLine
            guard r >= 0, r < rows else { continue }
            let current = match == options.currentMatch
            let color = current ? TWColor(r: 1, g: 0.6, b: 0.1, a: 0.75) : TWColor(r: 0.95, g: 0.8, b: 0.2, a: 0.35)
            let start = max(match.start, first)
            guard match.end > start else { continue }
            renderer.fill(CGRect(x: rect.minX + CGFloat(start - first) * m.cellWidth,
                                 y: rect.minY + CGFloat(r) * m.cellHeight,
                                 width: CGFloat(match.end - start) * m.cellWidth, height: m.cellHeight), color)
        }
    }

    private static func drawCursor(_ session: TerminalSession, rect: CGRect, first: Int, renderer: Renderer,
                                   fonts: TerminalFonts, palette: TerminalPalette, options: Options) {
        guard session.cursorVisible, !session.isScrolledBack, !session.hasExited else { return }
        let terminal = session.terminal!
        let loc = terminal.getCursorLocation()
        guard loc.y >= 0, loc.y < terminal.rows, loc.x >= first else { return }
        let m = fonts.metrics
        let x = rect.minX + CGFloat(min(loc.x, terminal.cols - 1) - first) * m.cellWidth
        let y = rect.minY + CGFloat(loc.y) * m.cellHeight
        let style = session.cursorStyle
        let blinks = style == .blinkBlock || style == .blinkBar || style == .blinkUnderline
        if blinks && options.focused && !options.cursorPhaseOn { return }
        let color = TWColor(palette.cursor)
        let cell = CGRect(x: x, y: y, width: m.cellWidth, height: m.cellHeight)
        switch style {
        case .blinkBar, .steadyBar:
            renderer.fill(CGRect(x: x, y: y, width: max(1.5, m.cellWidth * 0.12), height: m.cellHeight), color)
        case .blinkUnderline, .steadyUnderline:
            renderer.fill(CGRect(x: x, y: y + m.cellHeight - 2, width: m.cellWidth, height: 2), color)
        default:
            guard options.focused else {
                renderer.stroke(cell.insetBy(dx: 0.5, dy: 0.5), width: 1, color)
                return
            }
            renderer.fill(cell, color)
            // The character under a block cursor, in the background colour so it stays legible.
            if let line = session.visibleLine(loc.y), loc.x < line.count {
                let cd = line[loc.x]
                let ch = terminal.getCharacter(for: cd)
                if ch != "\u{0}", ch != " " {
                    var units: [WCHAR] = []
                    var widths: [UInt8] = []
                    appendCharacter(ch, cells: max(Int(cd.width), 1), units: &units, widths: &widths)
                    let s = cd.attribute.style
                    renderer.cells(units, widths: widths, at: CGPoint(x: x, y: y),
                                   font: fonts.face(bold: s.contains(.bold), italic: s.contains(.italic)),
                                   metrics: m, color: TWColor(palette.background, alpha: 1))
                }
            }
        }
    }
}
