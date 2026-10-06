import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// A Direct2D drawing surface for one window. All coordinates are device-independent pixels.
final class Renderer {
    private(set) var handle: OpaquePointer?
    private weak var owner: Window?
    private(set) var dpi: Float = 96
    private var pixelSize: (width: Int, height: Int) = (0, 0)

    init?(window: Window) {
        guard let hwnd = window.hwnd, let r = tw_renderer_create(raw(hwnd)) else { return nil }
        handle = r
        owner = window
    }

    deinit {
        if let handle { tw_renderer_destroy(handle) }
    }

    /// Re-reads the window's size and DPI.
    func syncSize() {
        guard let owner else { return }
        let size = owner.clientPixelSize
        let d = owner.dpi
        guard size != pixelSize || d != dpi else { return }
        pixelSize = size
        dpi = d
        tw_renderer_resize(handle, UINT(max(size.width, 1)), UINT(max(size.height, 1)), d)
    }

    /// Draws one frame. Returns false when the device was lost and the renderer must be rebuilt.
    func draw(_ body: () -> Void) -> Bool {
        guard tw_renderer_begin(handle) != 0 else { return true }
        body()
        return tw_renderer_end(handle) != 0
    }

    /// Draws one frame into a PNG instead of the window.
    func snapshot(to path: String, width: Int, height: Int, _ body: () -> Void) -> Bool {
        guard tw_snapshot_begin(handle, UINT(max(width, 1)), UINT(max(height, 1)), dpi) != 0 else { return false }
        body()
        return withWide(path) { tw_snapshot_end(handle, $0) } != 0
    }

    // MARK: Primitives

    func clear(_ c: TWColor) { tw_clear(handle, c) }

    func fill(_ r: CGRect, _ c: TWColor) {
        tw_fill_rect(handle, Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), c)
    }

    func fillRounded(_ r: CGRect, radius: CGFloat, _ c: TWColor) {
        tw_fill_rounded_rect(handle, Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), Float(radius), c)
    }

    func stroke(_ r: CGRect, width: CGFloat = 1, _ c: TWColor) {
        tw_stroke_rect(handle, Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), Float(width), c)
    }

    func strokeRounded(_ r: CGRect, radius: CGFloat, width: CGFloat = 1, _ c: TWColor) {
        tw_stroke_rounded_rect(handle, Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), Float(radius),
                               Float(width), c)
    }

    func line(from a: CGPoint, to b: CGPoint, width: CGFloat = 1, _ c: TWColor) {
        tw_draw_line(handle, Float(a.x), Float(a.y), Float(b.x), Float(b.y), Float(width), c)
    }

    func fillCircle(center: CGPoint, radius: CGFloat, _ c: TWColor) {
        tw_fill_ellipse(handle, Float(center.x), Float(center.y), Float(radius), Float(radius), c)
    }

    func shadow(_ r: CGRect, radius: CGFloat, spread: CGFloat, opacity: Double) {
        tw_draw_shadow(handle, Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), Float(radius),
                       Float(spread), Float(opacity))
    }

    func clipped(_ r: CGRect, _ body: () -> Void) {
        tw_push_clip(handle, Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        body()
        tw_pop_clip(handle)
    }

    func clippedRounded(_ r: CGRect, radius: CGFloat, _ body: () -> Void) {
        guard radius > 0.5 else { clipped(r, body); return }
        tw_push_rounded_clip(handle, Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), Float(radius))
        body()
        tw_pop_rounded_clip(handle)
    }

    enum Align: Int32 { case left = 0, center = 1, right = 2 }

    /// One line of interface text, vertically centred in `r`, truncated with an ellipsis.
    func text(_ s: String, in r: CGRect, font: Font, color: TWColor, align: Align = .left) {
        guard !s.isEmpty, r.width > 0 else { return }
        let units = Array(s.utf16)
        units.withUnsafeBufferPointer { buf in
            tw_draw_text(handle, font.handle, buf.baseAddress, Int32(buf.count), Float(r.minX), Float(r.minY),
                         Float(r.width), Float(r.height), align.rawValue, color)
        }
    }

    /// A run of terminal text placed on the grid. `cells` holds each UTF-16 unit's column count.
    func cells(_ units: [WCHAR], widths: [UInt8], at origin: CGPoint, font: Font, metrics: CellMetrics, color: TWColor) {
        guard !units.isEmpty else { return }
        units.withUnsafeBufferPointer { text in
            widths.withUnsafeBufferPointer { w in
                tw_draw_cells(handle, font.handle, text.baseAddress, Int32(text.count), w.baseAddress,
                              Float(origin.x), Float(origin.y), Float(metrics.cellWidth), Float(metrics.cellHeight),
                              Float(metrics.baseline), color)
            }
        }
    }
}

/// The size of one character cell, in DIPs, snapped to whole device pixels.
struct CellMetrics: Equatable {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var baseline: CGFloat
    var underlineY: CGFloat
    var underlineThickness: CGFloat

    static let fallback = CellMetrics(cellWidth: 8, cellHeight: 17, baseline: 13, underlineY: 15, underlineThickness: 1)
}

/// A DirectWrite font. Shared through `FontCache`, so a family and size is created once.
final class Font {
    let handle: OpaquePointer?
    let family: String
    let size: Double
    let bold: Bool
    let italic: Bool

    init(family: String, size: Double, bold: Bool = false, italic: Bool = false) {
        self.family = family
        self.size = size
        self.bold = bold
        self.italic = italic
        handle = withWide(family) { tw_font_create($0, Float(size), bold ? 700 : 400, italic ? 1 : 0) }
    }

    deinit {
        if let handle { tw_font_destroy(handle) }
    }

    func metrics(dpi: Float) -> CellMetrics {
        guard let handle else { return .fallback }
        var m = TWFontMetrics()
        tw_font_metrics(handle, dpi, &m)
        return CellMetrics(cellWidth: CGFloat(m.cellWidth), cellHeight: CGFloat(m.cellHeight),
                           baseline: CGFloat(m.baseline), underlineY: CGFloat(m.underlinePosition),
                           underlineThickness: CGFloat(m.underlineThickness))
    }

    func width(of s: String) -> CGFloat {
        let units = Array(s.utf16)
        return units.withUnsafeBufferPointer { CGFloat(tw_measure_text(handle, $0.baseAddress, Int32($0.count))) }
    }
}

enum FontCache {
    private static var fonts: [String: Font] = [:]

    static func font(_ family: String, _ size: Double, bold: Bool = false, italic: Bool = false) -> Font {
        let key = "\(family)|\(size)|\(bold)|\(italic)"
        if let f = fonts[key] { return f }
        let f = Font(family: family, size: size, bold: bold, italic: italic)
        fonts[key] = f
        return f
    }

    static func exists(_ family: String) -> Bool {
        withWide(family) { tw_font_family_exists($0) != 0 }
    }

    /// Installed families, monospaced ones only when asked.
    static func families(monospacedOnly: Bool) -> [String] {
        var buffer = [WCHAR](repeating: 0, count: 1 << 18)
        let count = Int(tw_font_families(&buffer, Int32(buffer.count), monospacedOnly ? 1 : 0))
        var names: [String] = []
        var start = 0
        for i in buffer.indices where buffer[i] == 0 {
            if names.count >= count { break }
            if i > start { names.append(String(decoding: buffer[start..<i], as: UTF16.self)) }
            start = i + 1
        }
        return names
    }

    /// The Windows interface font.
    static func ui(_ size: Double = 12, bold: Bool = false) -> Font {
        font("Segoe UI", size, bold: bold)
    }
}
