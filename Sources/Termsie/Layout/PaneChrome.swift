import AppKit
import TermsieCore

// ChromeZone and PaneChrome's geometry live in TermsieCore; the cursors and font metrics they
// meet on screen are AppKit's.

extension ChromeZone {
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
