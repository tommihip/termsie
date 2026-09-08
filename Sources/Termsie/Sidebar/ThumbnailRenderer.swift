import AppKit
import SwiftTerm

/// Renders a terminal's visible screen as a miniature.
///
/// This reads the character buffer, not pixels, and that is the whole point: the terminals are
/// Metal-backed, and `cacheDisplay(in:)` / `CALayer.render(in:)` cannot capture a CAMetalLayer —
/// they return a blank rectangle. Window capture would work but demands Screen Recording
/// permission for a sidebar thumbnail. Reading the buffer is renderer-independent, needs no
/// permission, and costs a few dozen rectangle fills.
enum ThumbnailRenderer {
    /// Draws a screen as coloured blocks: one background run per colour change, and half-height
    /// bars for ink, which read as lines of text at this scale far better than solid blocks would.
    static func render(terminal: Terminal, size: CGSize, scale: CGFloat,
                       colors: TermsieConfig.Colors, showCursor: Bool,
                       background: NSColor? = nil) -> CGImage? {
        let cols = max(terminal.cols, 1)
        let rows = max(terminal.rows, 1)
        let pw = max(Int(size.width * scale), 1)
        let ph = max(Int(size.height * scale), 1)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .none

        let bg = (background ?? NSColor.hex(colors.background)).withAlphaComponent(1)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        let sx = size.width / CGFloat(cols)
        let sy = size.height / CGFloat(rows)
        let palette = Palette(colors: colors, background: bg)

        // Batch by colour so the whole thumbnail is a handful of fills rather than one per cell.
        var bgRuns: [NSColor: [CGRect]] = [:]
        var inkRuns: [NSColor: [CGRect]] = [:]

        for r in 0..<rows {
            guard let line = terminal.getLine(row: r) else { continue }
            // Flip: the context's origin is bottom-left, the terminal's row 0 is at the top.
            let y = size.height - CGFloat(r + 1) * sy
            let limit = min(line.count, cols)

            var runStart = 0
            var runColor: NSColor?
            var inkStart = -1
            var inkColor: NSColor?

            func flushBG(_ end: Int) {
                if let c = runColor, end > runStart, c != bg {
                    bgRuns[c, default: []].append(CGRect(x: CGFloat(runStart) * sx, y: y,
                                                         width: CGFloat(end - runStart) * sx, height: sy))
                }
            }
            func flushInk(_ end: Int) {
                if let c = inkColor, inkStart >= 0, end > inkStart {
                    inkRuns[c, default: []].append(CGRect(x: CGFloat(inkStart) * sx, y: y + sy * 0.25,
                                                          width: CGFloat(end - inkStart) * sx, height: sy * 0.5))
                }
            }

            for c in 0..<limit {
                let cd = line[c]
                let attr = cd.attribute
                let style = attr.style
                var fg = palette.color(attr.fg, isForeground: true)
                var bgc = palette.color(attr.bg, isForeground: false)
                if style.contains(.inverse) { swap(&fg, &bgc) }
                if style.contains(.dim) { fg = fg.withAlphaComponent(0.55) }

                if bgc != runColor {
                    flushBG(c)
                    runStart = c
                    runColor = bgc
                }

                let scalar = cd.getCharacter().unicodeScalars.first?.value ?? 0
                let isInk = scalar > 32 && !style.contains(.invisible)
                if isInk {
                    if inkStart < 0 || fg != inkColor {
                        flushInk(c)
                        inkStart = c
                        inkColor = fg
                    }
                } else if inkStart >= 0 {
                    flushInk(c)
                    inkStart = -1
                    inkColor = nil
                }
            }
            flushBG(limit)
            flushInk(limit)
        }

        for (color, rects) in bgRuns {
            ctx.setFillColor(color.cgColor)
            ctx.fill(rects)
        }
        for (color, rects) in inkRuns {
            ctx.setFillColor(color.cgColor)
            ctx.fill(rects)
        }

        if showCursor {
            let loc = terminal.getCursorLocation()
            if loc.y >= 0, loc.y < rows, loc.x >= 0, loc.x < cols {
                ctx.setFillColor(NSColor.hex(colors.cursor).cgColor)
                ctx.fill(CGRect(x: CGFloat(loc.x) * sx,
                                y: size.height - CGFloat(loc.y + 1) * sy,
                                width: max(sx * 1.5, 1), height: sy))
            }
        }
        return ctx.makeImage()
    }

    /// What to show for a terminal that has never been opened: its folder and the commands it
    /// will run, which beats a blank rectangle or a stale picture.
    static func renderRecipe(definition: TerminalDefinition, size: CGSize, scale: CGFloat,
                             colors: TermsieConfig.Colors, background: NSColor? = nil) -> CGImage? {
        let pw = max(Int(size.width * scale), 1)
        let ph = max(Int(size.height * scale), 1)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        ctx.scaleBy(x: scale, y: scale)

        (background ?? NSColor.hex(colors.background)).withAlphaComponent(1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let border = NSBezierPath(rect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.hex(colors.inactiveBorder).setStroke()
        border.stroke()

        var lines: [String] = []
        if let cwd = definition.cwd, !cwd.isEmpty { lines.append(ProcessInspector.abbreviateHome(cwd)) }
        lines.append(contentsOf: definition.startupCommands.prefix(3))
        let font = NSFont.monospacedSystemFont(ofSize: 4.5, weight: .regular)
        var y = size.height - 8
        for line in lines.prefix(4) {
            let s = NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: NSColor.hex(colors.headerText),
            ])
            s.draw(with: NSRect(x: 4, y: y - 6, width: size.width - 8, height: 6),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y -= 7
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Resolves SwiftTerm attribute colours against the user's configured palette.
    /// `Terminal.installedColors` is internal, but Termsie owns the palette anyway.
    private struct Palette {
        let ansi: [NSColor]
        let foreground: NSColor
        let background: NSColor

        init(colors: TermsieConfig.Colors, background: NSColor) {
            ansi = colors.ansi.map { NSColor.hex($0) }
            foreground = NSColor.hex(colors.foreground)
            self.background = background
        }

        func color(_ c: Attribute.Color, isForeground: Bool) -> NSColor {
            switch c {
            case .defaultColor:
                return isForeground ? foreground : background
            case .defaultInvertedColor:
                return isForeground ? background : foreground
            case .ansi256(let code):
                return ansi256(Int(code))
            case .trueColor(let r, let g, let b):
                return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                               blue: CGFloat(b) / 255, alpha: 1)
            }
        }

        private func ansi256(_ i: Int) -> NSColor {
            if i < 16, i < ansi.count { return ansi[i] }
            if i >= 232 {
                let level = CGFloat(8 + 10 * (i - 232)) / 255
                return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
            }
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            let n = i - 16
            let r = levels[(n / 36) % 6] / 255
            let g = levels[(n / 6) % 6] / 255
            let b = levels[n % 6] / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }
}
