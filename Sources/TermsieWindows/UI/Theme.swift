import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// Sizes and colours of the Windows interface. Sizes match the macOS app's so the two read as
/// the same program; colours come from the config, so a theme set in config.json applies to both.
enum Theme {
    static var config: TermsieConfig { ConfigStore.shared.config }
    static var colors: TermsieConfig.Colors { config.colors }

    static func color(_ hex: String, alpha: Double? = nil) -> TWColor {
        TWColor(RGBA.hex(hex), alpha: alpha)
    }

    // MARK: Metrics

    /// The strip across the top: menu button, tabs, new-tab button.
    static let topBarHeight: CGFloat = 34
    static let headerHeight: CGFloat = 26
    static let footerHeight: CGFloat = 30
    static let copyRowHeight: CGFloat = 24
    static let copyHeaderHeight: CGFloat = 20
    static let dividerWidth: CGFloat = 1
    static let dividerGrab: CGFloat = 6
    static let sidebarMinWidth: CGFloat = 44
    static let sidebarMaxWidth: CGFloat = 420
    static let trafficDiameter: CGFloat = 12
    static let trafficSpacing: CGFloat = 8
    static var trafficWidth: CGFloat { trafficDiameter * 3 + trafficSpacing * 2 }
    static let pillHeight: CGFloat = 14
    static let pillRadius: CGFloat = 3
    static let findBarHeight: CGFloat = 30
    static let findBarWidth: CGFloat = 340
    static let scrollBarWidth: CGFloat = 4

    // MARK: Fonts

    static func ui(_ size: Double = 11, bold: Bool = false) -> Font {
        FontCache.ui(size, bold: bold)
    }

    /// Monospaced interface text: folders in the list and headers.
    static func mono(_ size: Double = 10) -> Font {
        FontCache.font(FontCache.exists("Cascadia Mono") ? "Cascadia Mono" : "Consolas", size)
    }
}

/// The small drawn elements shared by terminal headers and the terminal list, so the two cannot
/// drift apart visually.
enum Badge: Equatable {
    case none
    case activity
    case bell
    case warning
    case exited(Int32?)
}

enum Draw {
    /// The terminal's number as a filled pill. Returns the rect it occupied.
    @discardableResult
    static func indexPill(_ number: Int, at origin: CGPoint, active: Bool, renderer: Renderer, dim: Double = 1) -> CGRect {
        let c = Theme.colors
        let text = "\(number)"
        let font = Theme.ui(10, bold: true)
        let width = max(16, font.width(of: text) + 8)
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: Theme.pillHeight)
        renderer.fillRounded(rect, radius: Theme.pillRadius,
                             Theme.color(active ? c.activeBorder : c.inactiveBorder, alpha: dim))
        renderer.text(text, in: rect, font: font,
                      color: active ? TWColor.white.withAlpha(Float(dim)) : Theme.color(c.headerText, alpha: dim),
                      align: .center)
        return rect
    }

    /// A labelled pill, filled or outlined, right-aligned at `rightEdge`.
    @discardableResult
    static func label(_ text: String, rightEdge: CGFloat, midY: CGFloat, color: TWColor, filled: Bool,
                      renderer: Renderer) -> CGRect {
        let font = Theme.ui(9.5, bold: true)
        let width = font.width(of: text) + 8
        let rect = CGRect(x: rightEdge - width, y: (midY - Theme.pillHeight / 2).rounded(), width: width,
                          height: Theme.pillHeight)
        if filled {
            renderer.fillRounded(rect, radius: Theme.pillRadius, color)
            renderer.text(text, in: rect, font: font, color: TWColor.black.withAlpha(0.9), align: .center)
        } else {
            renderer.strokeRounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: Theme.pillRadius, color)
            renderer.text(text, in: rect, font: font, color: color, align: .center)
        }
        return rect
    }

    @discardableResult
    static func dot(rightEdge: CGFloat, midY: CGFloat, color: TWColor, diameter: CGFloat = 8, renderer: Renderer) -> CGRect {
        let r = CGRect(x: rightEdge - diameter, y: midY - diameter / 2, width: diameter, height: diameter)
        renderer.fillCircle(center: CGPoint(x: r.midX, y: r.midY), radius: diameter / 2, color)
        return r
    }

    /// Whichever badge applies, right-aligned. Returns the new right edge.
    static func badge(_ badge: Badge, rightEdge: CGFloat, midY: CGFloat, renderer: Renderer) -> CGFloat {
        let c = Theme.colors
        switch badge {
        case .none:
            return rightEdge
        case .activity:
            return dot(rightEdge: rightEdge, midY: midY, color: Theme.color(c.activity), renderer: renderer).minX - 8
        case .bell:
            return label("BELL", rightEdge: rightEdge, midY: midY, color: Theme.color(c.bell), filled: true,
                         renderer: renderer).minX - 6
        case .warning:
            return label("!", rightEdge: rightEdge, midY: midY, color: Theme.color(c.warning), filled: true,
                         renderer: renderer).minX - 6
        case .exited(let code):
            let text = code.map { "exited \($0)" } ?? "exited"
            return label(text, rightEdge: rightEdge, midY: midY, color: Theme.color(code == 0 ? c.exited : c.bell),
                         filled: false, renderer: renderer).minX - 6
        }
    }

    /// Filled accent: running a job. Filled grey: idle shell. Hollow ring: closed.
    static func statusDot(in rect: CGRect, isOpen: Bool, isBusy: Bool, renderer: Renderer) {
        let c = Theme.colors
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if isOpen {
            renderer.fillCircle(center: center, radius: rect.width / 2,
                                Theme.color(isBusy ? c.activeBorder : c.headerText))
        } else {
            tw_draw_ellipse_outline(renderer, center, rect.width / 2 - 0.5, Theme.color(c.exited))
        }
    }

    /// A play triangle, drawn rather than typed so it is crisp at any scale.
    static func play(in rect: CGRect, color: TWColor, renderer: Renderer) {
        let inset = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.25)
        let rows = max(1, Int(inset.height.rounded()))
        // Horizontal slices of the triangle: exact at small sizes, where a path would blur.
        for i in 0..<rows {
            let t = (CGFloat(i) + 0.5) / CGFloat(rows)
            let w = inset.width * (1 - abs(t - 0.5) * 2)
            renderer.fill(CGRect(x: inset.minX, y: inset.minY + CGFloat(i), width: max(w, 0.5), height: 1), color)
        }
    }

    static func plus(in rect: CGRect, color: TWColor, renderer: Renderer) {
        let s = min(rect.width, rect.height) * 0.55
        let c = CGPoint(x: rect.midX, y: rect.midY)
        renderer.line(from: CGPoint(x: c.x - s / 2, y: c.y), to: CGPoint(x: c.x + s / 2, y: c.y), width: 1.4, color)
        renderer.line(from: CGPoint(x: c.x, y: c.y - s / 2), to: CGPoint(x: c.x, y: c.y + s / 2), width: 1.4, color)
    }

    static func cross(in rect: CGRect, color: TWColor, renderer: Renderer, width: CGFloat = 1.2) {
        let s = min(rect.width, rect.height) * 0.5
        let c = CGPoint(x: rect.midX, y: rect.midY)
        renderer.line(from: CGPoint(x: c.x - s / 2, y: c.y - s / 2), to: CGPoint(x: c.x + s / 2, y: c.y + s / 2), width: width, color)
        renderer.line(from: CGPoint(x: c.x - s / 2, y: c.y + s / 2), to: CGPoint(x: c.x + s / 2, y: c.y - s / 2), width: width, color)
    }

    /// Three bars: the menu button.
    static func menuGlyph(in rect: CGRect, color: TWColor, renderer: Renderer) {
        let w = min(rect.width, 14)
        let x = rect.midX - w / 2
        for i in -1...1 {
            let y = (rect.midY + CGFloat(i) * 4.5).rounded() + 0.5
            renderer.line(from: CGPoint(x: x, y: y), to: CGPoint(x: x + w, y: y), width: 1.3, color)
        }
    }
}

/// An outlined circle, for the closed-terminal dot.
private func tw_draw_ellipse_outline(_ renderer: Renderer, _ center: CGPoint, _ radius: CGFloat, _ color: TWColor) {
    renderer.strokeRounded(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                           radius: radius, width: 1, color)
}
