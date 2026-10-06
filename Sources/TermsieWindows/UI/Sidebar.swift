import Foundation
import WinSDK
import CTermsieWin
import SwiftTerm
import TermsieCore

/// The terminal list down the side of a tab: one row per saved terminal with its number, a live
/// thumbnail, name and folder; the copy tools; and the New Terminal and Run All buttons.
///
/// Thumbnails are built from the character buffer, never from pixels, so they cost a handful of
/// rectangles and stay correct whatever draws the terminal.
final class Sidebar {
    weak var tab: TabController?
    var scroll: CGFloat = 0
    var hover: Hit?
    /// A row being dragged to a new place, and where the pointer is.
    var drag: (id: String, y: CGFloat)?
    private var thumbnails: [String: Thumbnail] = [:]
    private var copyFeedback: (target: CopyTarget, copied: Bool, until: Double)?

    enum Hit: Equatable {
        case row(String)
        case run(String)
        case newTerminal
        case runAll
        case copy(CopyTarget)
        case autoCopy
        case empty
    }

    // MARK: Metrics

    static let thumbnailSize = CGSize(width: 104, height: 65)
    static let gutter: CGFloat = 22
    static let margin: CGFloat = 6
    static let runButtonSize: CGFloat = 16

    struct RowMetrics: Equatable {
        var thumbnail: CGSize?
        var rowHeight: CGFloat
        var showsText: Bool

        static let textWidthBesideThumbnail: CGFloat = 112
        static let minThumbnailWidth: CGFloat = 48
        static let compactRowHeight: CGFloat = 40
        static let minThumbnailRowHeight: CGFloat = 64
        static let minTextWidth: CGFloat = 36
        static var leading: CGFloat { Sidebar.margin + Sidebar.gutter + 6 }
        static var fullWidth: CGFloat {
            leading + Sidebar.thumbnailSize.width + 8 + textWidthBesideThumbnail + Sidebar.margin
        }

        /// At the default width and wider the thumbnail is full size and extra width goes to the
        /// text. Narrower, the thumbnail shrinks until it would be unreadable, then disappears;
        /// narrower still, only the number and status dot are left.
        static func forWidth(_ width: CGFloat, fullRowHeight: CGFloat, thumbnails: Bool) -> RowMetrics {
            let full = Sidebar.thumbnailSize
            let thumbWidth = min(full.width, (width - (fullWidth - full.width)).rounded(.down))
            if thumbnails, thumbWidth >= minThumbnailWidth {
                let height = (thumbWidth * full.height / full.width).rounded()
                let rowHeight = max(fullRowHeight - (full.height - height), minThumbnailRowHeight)
                return RowMetrics(thumbnail: CGSize(width: thumbWidth, height: height),
                                  rowHeight: rowHeight.rounded(), showsText: true)
            }
            let textWidth = width - leading - Sidebar.margin
            return RowMetrics(thumbnail: nil, rowHeight: compactRowHeight, showsText: textWidth >= minTextWidth)
        }
    }

    struct Layout {
        var metrics: RowMetrics
        var list: CGRect
        var rows: [(id: String, rect: CGRect)]
        var copyTools: CGRect?
        var footer: CGRect
        var contentHeight: CGFloat
    }

    func layout(in rect: CGRect) -> Layout {
        guard let tab else { return Layout(metrics: .init(thumbnail: nil, rowHeight: 40, showsText: true), list: rect, rows: [],
                                           copyTools: nil, footer: .zero, contentHeight: 0) }
        let config = ConfigStore.shared.config
        let metrics = RowMetrics.forWidth(rect.width, fullRowHeight: CGFloat(config.sidebar.rowHeight),
                                          thumbnails: config.sidebar.thumbnailStyle.lowercased() != "none")
        let footer = CGRect(x: rect.minX, y: rect.maxY - Theme.footerHeight, width: rect.width, height: Theme.footerHeight)
        var bottom = footer.minY
        var copyRect: CGRect?
        if config.copy.showTools, metrics.showsText {
            let h = Theme.copyHeaderHeight + 4 * Theme.copyRowHeight + 4
            copyRect = CGRect(x: rect.minX, y: bottom - h, width: rect.width, height: h)
            bottom -= h
        }
        let list = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, bottom - rect.minY))
        let content = CGFloat(tab.registry.count) * metrics.rowHeight
        scroll = min(max(scroll, 0), max(0, content - list.height))
        var rows: [(String, CGRect)] = []
        var y = list.minY - scroll
        for id in tab.registry.order {
            rows.append((id, CGRect(x: list.minX, y: y, width: list.width, height: metrics.rowHeight)))
            y += metrics.rowHeight
        }
        return Layout(metrics: metrics, list: list, rows: rows, copyTools: copyRect, footer: footer, contentHeight: content)
    }

    private func runButtonRect(row: CGRect, metrics: RowMetrics) -> CGRect? {
        guard metrics.showsText else { return nil }
        let textX = row.minX + (metrics.thumbnail == nil ? RowMetrics.leading : RowMetrics.leading + metrics.thumbnail!.width + 8)
        guard row.maxX - Sidebar.margin - textX >= Sidebar.runButtonSize + RowMetrics.minTextWidth else { return nil }
        let titleY = metrics.thumbnail == nil ? row.midY - 15 : row.minY + ((row.height - metrics.thumbnail!.height) / 2).rounded() + 2
        return CGRect(x: row.maxX - Sidebar.margin - Sidebar.runButtonSize, y: titleY - 1,
                      width: Sidebar.runButtonSize, height: Sidebar.runButtonSize)
    }

    // MARK: Hit testing

    func hit(_ p: CGPoint, in rect: CGRect) -> Hit {
        guard let tab, rect.contains(p) else { return .empty }
        let l = layout(in: rect)
        if l.footer.contains(p) {
            let runAll = runAllRect(l.footer)
            if let runAll, runAll.contains(p) { return .runAll }
            return .newTerminal
        }
        if let tools = l.copyTools, tools.contains(p) {
            let row = Int((p.y - tools.minY - Theme.copyHeaderHeight) / Theme.copyRowHeight)
            switch row {
            case 0: return .autoCopy
            case 1: return .copy(.lastCommandOutput)
            case 2: return .copy(.wholeTerminal)
            case 3: return .copy(.lastCommand)
            default: return .empty
            }
        }
        guard l.list.contains(p) else { return .empty }
        for (id, r) in l.rows where r.contains(p) {
            if tab.hasStartupCommands(id), let run = runButtonRect(row: r, metrics: l.metrics),
               run.insetBy(dx: -3, dy: -3).contains(p) {
                return .run(id)
            }
            return .row(id)
        }
        return .empty
    }

    /// Where a dragged row would land, as an index into the list.
    func dropIndex(at y: CGFloat, in rect: CGRect) -> Int {
        let l = layout(in: rect)
        let index = Int(((y - l.list.minY + scroll) / l.metrics.rowHeight).rounded())
        return min(max(index, 0), tab?.registry.count ?? 0)
    }

    func scroll(by delta: CGFloat, in rect: CGRect) {
        scroll += delta
        _ = layout(in: rect)
    }

    private func runAllRect(_ footer: CGRect) -> CGRect? {
        guard let tab, !tab.terminalsWithStartupCommands.isEmpty, footer.width >= 150 else { return nil }
        return CGRect(x: footer.maxX - 78, y: footer.minY + 4, width: 72, height: footer.height - 8)
    }

    // MARK: Caches

    func forget(_ id: String) { thumbnails.removeValue(forKey: id) }
    func dropAllCaches() { thumbnails.removeAll() }

    func confirmCopy(_ target: CopyTarget, copied: Bool) {
        copyFeedback = (target, copied, Clock.now + 1.2)
        MainQueue.shared.after(1.3) { [weak self] in self?.tab?.setNeedsDisplay() }
    }

    /// How many times each terminal's thumbnail has been rebuilt, for the overhead test.
    func renderCount(for id: String) -> Int { thumbnails[id]?.renderCount ?? 0 }

    // MARK: Drawing

    func draw(in rect: CGRect, renderer: Renderer) {
        guard let tab else { return }
        let c = Theme.colors
        renderer.fill(rect, Theme.color(c.sidebarBackground, alpha: App.shared.backdropActive ? nil : 1))
        let l = layout(in: rect)
        renderer.clipped(l.list) {
            for (id, r) in l.rows where r.maxY > l.list.minY && r.minY < l.list.maxY {
                if let drag, drag.id == id { continue }
                drawRow(id, rect: r, metrics: l.metrics, renderer: renderer)
            }
            if let drag {
                let index = dropIndex(at: drag.y, in: rect)
                let y = l.list.minY - scroll + CGFloat(index) * l.metrics.rowHeight
                renderer.fill(CGRect(x: l.list.minX + 4, y: y - 1, width: l.list.width - 8, height: 2), Theme.color(c.activeBorder))
                let r = CGRect(x: l.list.minX, y: drag.y - l.metrics.rowHeight / 2, width: l.list.width, height: l.metrics.rowHeight)
                drawRow(drag.id, rect: r, metrics: l.metrics, renderer: renderer, floating: true)
            }
        }
        if l.contentHeight > l.list.height, l.list.height > 0 {
            let h = max(24, l.list.height * l.list.height / l.contentHeight)
            let y = l.list.minY + (l.list.height - h) * scroll / (l.contentHeight - l.list.height)
            renderer.fillRounded(CGRect(x: l.list.maxX - 4, y: y, width: 3, height: h), radius: 1.5,
                                 TWColor(r: 1, g: 1, b: 1, a: 0.2))
        }
        if let tools = l.copyTools { drawCopyTools(tools, renderer: renderer) }
        drawFooter(l.footer, renderer: renderer)
        _ = tab
    }

    private func drawRow(_ id: String, rect r: CGRect, metrics: RowMetrics, renderer: Renderer, floating: Bool = false) {
        guard let tab, let def = tab.registry.definition(id) else { return }
        let c = Theme.colors
        let pane = tab.registry.pane(for: id)
        let isOpen = pane != nil
        let isActive = pane != nil && pane === tab.activePane
        let dim: Double = isOpen ? 1 : 0.55
        let style = ConfigStore.shared.config.environment(def.environment)
        let tint = style?.tint.flatMap { RGBA(hex: $0) }.map { TWColor($0) }

        if isActive || floating {
            renderer.fill(r, Theme.color(c.sidebarSelection, alpha: floating ? 0.95 : nil))
            renderer.fill(CGRect(x: r.minX, y: r.minY, width: 2, height: r.height), tint ?? Theme.color(c.activeBorder))
        } else if hover == .row(id) || hover == .run(id) {
            renderer.fill(r, TWColor(r: 1, g: 1, b: 1, a: 0.04))
        }

        let x = r.minX + Sidebar.margin
        Draw.indexPill(tab.registry.number(of: id), at: CGPoint(x: x, y: (r.midY - 16).rounded()), active: isActive,
                       renderer: renderer, dim: dim)
        Draw.statusDot(in: CGRect(x: x + 4, y: r.midY + 4, width: 7, height: 7), isOpen: isOpen,
                       isBusy: pane?.hasRunningJob ?? false, renderer: renderer)

        var textX = r.minX + RowMetrics.leading
        var titleY = r.midY - 15
        var thumbRect: CGRect?
        if let size = metrics.thumbnail {
            let t = CGRect(x: r.minX + RowMetrics.leading, y: r.minY + ((r.height - size.height) / 2).rounded(),
                           width: size.width, height: size.height)
            thumbRect = t
            drawThumbnail(id, def: def, pane: pane, rect: t, active: isActive, tint: tint, dim: dim, renderer: renderer)
            textX = t.maxX + 8
            titleY = t.minY + 2
        }
        guard metrics.showsText else { return }

        let run = tab.hasStartupCommands(id) ? runButtonRect(row: r, metrics: metrics) : nil
        let textRight = (run?.minX).map { $0 - 4 } ?? r.maxX - Sidebar.margin
        let title = pane?.displayTitle ?? def.displayName
        renderer.text(title, in: CGRect(x: textX, y: titleY, width: max(0, textRight - textX), height: 15),
                      font: Theme.ui(11, bold: isActive),
                      color: Theme.color(isActive ? c.headerActiveText : c.headerText, alpha: dim))
        let subtitle = pane?.displayDirectory ?? def.cwd.map { HomePath.abbreviate(HomePath.expand($0)) } ?? ""
        if !subtitle.isEmpty {
            renderer.text(subtitle, in: CGRect(x: textX, y: titleY + 15, width: max(0, r.maxX - Sidebar.margin - textX), height: 14),
                          font: Theme.mono(9.5), color: Theme.color(c.headerText, alpha: dim * 0.85))
        }
        if let run {
            let hovered = hover == .run(id)
            if hovered { renderer.fillRounded(run, radius: 4, Theme.color(c.headerActiveText, alpha: 0.14)) }
            let pending = pane?.hasPendingCommands ?? false
            let color = pending ? Theme.color(c.activeBorder)
                : hovered ? Theme.color(c.headerActiveText) : Theme.color(c.headerText, alpha: 0.75 * dim)
            Draw.play(in: run, color: color, renderer: renderer)
        }
        guard let thumb = thumbRect else { return }
        var right = r.maxX - Sidebar.margin
        let badgeY = max(thumb.maxY - 8, titleY + 34)
        if let pane, pane.badge != .none {
            right = Draw.badge(pane.badge, rightEdge: right, midY: badgeY, renderer: renderer)
        }
        if let style, let tint, right - textX > 40 {
            _ = Draw.label(style.label.uppercased(), rightEdge: right, midY: badgeY, color: tint.withAlpha(Float(dim)),
                           filled: true, renderer: renderer)
        }
    }

    private func drawThumbnail(_ id: String, def: TerminalDefinition, pane: Pane?, rect t: CGRect, active: Bool,
                               tint: TWColor?, dim: Double, renderer: Renderer) {
        let c = Theme.colors
        let config = ConfigStore.shared.config
        let background = config.backgroundRGBA(for: def.environment)
        renderer.fill(t, TWColor(background, alpha: 1))
        if let pane {
            let thumb = thumbnails[id] ?? Thumbnail()
            thumbnails[id] = thumb
            if pane.thumbnailDirty || thumb.isEmpty {
                thumb.refresh(pane: pane, background: background)
                pane.thumbnailDirty = false
            }
            thumb.draw(in: t, renderer: renderer)
        } else {
            // Never opened (or closed): show what it will be, its folder and its commands.
            var lines: [String] = []
            if let cwd = def.cwd, !cwd.isEmpty { lines.append(HomePath.abbreviate(HomePath.expand(cwd))) }
            lines.append(contentsOf: def.startupCommands.prefix(3))
            var y = t.minY + 3
            for line in lines.prefix(4) {
                renderer.text(line, in: CGRect(x: t.minX + 4, y: y, width: t.width - 8, height: 9),
                              font: Theme.mono(6.5), color: Theme.color(c.headerText, alpha: 0.9))
                y += 9
            }
        }
        let stroke = tint ?? Theme.color(active ? c.activeBorder : c.inactiveBorder)
        renderer.strokeRounded(t.insetBy(dx: 0.5, dy: 0.5), radius: 3, width: 1, stroke.withAlpha(Float(dim * 0.9)))
    }

    private func drawCopyTools(_ rect: CGRect, renderer: Renderer) {
        guard let tab else { return }
        let c = Theme.colors
        renderer.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1), Theme.color(c.divider))
        renderer.text("COPY", in: CGRect(x: rect.minX + 10, y: rect.minY + 2, width: rect.width - 20, height: Theme.copyHeaderHeight),
                      font: Theme.ui(9, bold: true), color: Theme.color(c.headerText, alpha: 0.8))
        let rows: [Hit] = [.autoCopy, .copy(.lastCommandOutput), .copy(.wholeTerminal), .copy(.lastCommand)]
        let autoCopy = ConfigStore.shared.config.copy.autoCopyOnSelect
        for (i, item) in rows.enumerated() {
            let r = CGRect(x: rect.minX + 4, y: rect.minY + Theme.copyHeaderHeight + CGFloat(i) * Theme.copyRowHeight,
                           width: rect.width - 8, height: Theme.copyRowHeight - 2)
            let hovered = hover == item
            var enabled = true
            var title = ""
            switch item {
            case .autoCopy:
                title = "Copy on select"
            case .copy(let target):
                title = target.shortTitle
                enabled = tab.activePane?.canCopy(target) ?? false
                if let feedback = copyFeedback, feedback.target == target, Clock.now < feedback.until {
                    title = feedback.copied ? "Copied" : "Nothing to copy"
                }
            default: break
            }
            if hovered && enabled { renderer.fillRounded(r, radius: 4, TWColor(r: 1, g: 1, b: 1, a: 0.06)) }
            let iconRect = CGRect(x: r.minX + 6, y: r.midY - 6, width: 12, height: 12)
            let color = Theme.color(c.headerText, alpha: enabled ? 1 : 0.4)
            if item == .autoCopy {
                renderer.strokeRounded(iconRect.insetBy(dx: 0.5, dy: 0.5), radius: 2, width: 1, color)
                if autoCopy { renderer.fillRounded(iconRect.insetBy(dx: 3, dy: 3), radius: 1, Theme.color(c.activeBorder)) }
            } else {
                renderer.strokeRounded(CGRect(x: iconRect.minX + 2, y: iconRect.minY, width: 8, height: 10), radius: 1.5, width: 1, color)
                renderer.strokeRounded(CGRect(x: iconRect.minX, y: iconRect.minY + 2, width: 8, height: 10), radius: 1.5, width: 1, color)
            }
            renderer.text(title, in: CGRect(x: iconRect.maxX + 8, y: r.minY, width: r.maxX - iconRect.maxX - 12, height: r.height),
                          font: Theme.ui(10.5), color: color)
        }
    }

    private func drawFooter(_ rect: CGRect, renderer: Renderer) {
        let c = Theme.colors
        renderer.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1), Theme.color(c.divider))
        let runAll = runAllRect(rect)
        let newRect = CGRect(x: rect.minX + 6, y: rect.minY + 4, width: (runAll?.minX ?? rect.maxX - 6) - rect.minX - 10,
                             height: rect.height - 8)
        if hover == .newTerminal { renderer.fillRounded(newRect, radius: 5, TWColor(r: 1, g: 1, b: 1, a: 0.07)) }
        let plus = CGRect(x: newRect.minX + 4, y: newRect.midY - 7, width: 14, height: 14)
        Draw.plus(in: plus, color: Theme.color(c.headerActiveText), renderer: renderer)
        if newRect.width > 60 {
            renderer.text("New Terminal", in: CGRect(x: plus.maxX + 6, y: newRect.minY, width: newRect.maxX - plus.maxX - 8,
                                                     height: newRect.height),
                          font: Theme.ui(11), color: Theme.color(c.headerActiveText))
        }
        if let runAll {
            if hover == .runAll { renderer.fillRounded(runAll, radius: 5, TWColor(r: 1, g: 1, b: 1, a: 0.07)) }
            let icon = CGRect(x: runAll.minX + 4, y: runAll.midY - 7, width: 14, height: 14)
            Draw.play(in: icon, color: Theme.color(c.headerText), renderer: renderer)
            renderer.text("Run All", in: CGRect(x: icon.maxX + 4, y: runAll.minY, width: runAll.maxX - icon.maxX - 6,
                                                height: runAll.height),
                          font: Theme.ui(11), color: Theme.color(c.headerText))
        }
    }

    /// A one-line description of a row, for headless assertions.
    func describeRow(_ id: String, width: CGFloat) -> String {
        guard let tab, let def = tab.registry.definition(id) else { return "missing" }
        let metrics = RowMetrics.forWidth(width, fullRowHeight: CGFloat(ConfigStore.shared.config.sidebar.rowHeight),
                                          thumbnails: true)
        let pane = tab.registry.pane(for: id)
        return "title=\(pane?.displayTitle ?? def.displayName) open=\(pane != nil) thumbnail=\(metrics.thumbnail.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none")"
            + " text=\(metrics.showsText) run=\(tab.hasStartupCommands(id))"
    }
}

/// One terminal's miniature, as coloured runs in unit space, rebuilt only when what is on screen
/// changed: the fingerprint is each visible row's generation counter plus the scroll position,
/// size and cursor.
final class Thumbnail {
    private var background = TWColor.black
    private var backgroundRuns: [(TWColor, [CGRect])] = []
    private var inkRuns: [(TWColor, [CGRect])] = []
    private var cursor: CGRect?
    private var cursorColor = TWColor.white
    private var generations: [UInt64] = []
    private var lastTop = -1
    private var lastSize = (0, 0)
    private var lastCursor = (x: -1, y: -1)
    private var lastColumns = -1
    private(set) var renderCount = 0
    var isEmpty: Bool { renderCount == 0 }

    private func fingerprintChanged(_ pane: Pane) -> Bool {
        let terminal = pane.session.terminal!
        let rows = terminal.rows
        var changed = false
        let top = pane.session.viewTopLine
        let cursor = terminal.getCursorLocation()
        if rows != lastSize.1 || terminal.cols != lastSize.0 || top != lastTop || cursor.x != lastCursor.x
            || cursor.y != lastCursor.y || pane.firstColumn != lastColumns {
            changed = true
        }
        if generations.count != rows {
            generations = Array(repeating: 0, count: rows)
            changed = true
        }
        for r in 0..<rows {
            let g = pane.session.visibleLine(r)?.generation ?? 0
            if generations[r] != g {
                generations[r] = g
                changed = true
            }
        }
        lastSize = (terminal.cols, rows)
        lastTop = top
        lastCursor = cursor
        lastColumns = pane.firstColumn
        return changed
    }

    func refresh(pane: Pane, background bg: RGBA) {
        guard fingerprintChanged(pane) || renderCount == 0 else { return }
        renderCount += 1
        let terminal = pane.session.terminal!
        let palette = TerminalPalette(config: ConfigStore.shared.config, background: bg)
        background = TWColor(bg, alpha: 1)
        let gridCols = max(terminal.cols, 1)
        let first = pane.wrapsLines ? 0 : min(pane.firstColumn, gridCols - 1)
        let cols = pane.wrapsLines ? gridCols : min(pane.visibleColumns, gridCols - first)
        let rows = max(terminal.rows, 1)
        let sx = 1 / CGFloat(max(cols, 1))
        let sy = 1 / CGFloat(rows)
        var bgRuns: [RGBA: [CGRect]] = [:]
        var ink: [RGBA: [CGRect]] = [:]

        for r in 0..<rows {
            guard let line = pane.session.visibleLine(r) else { continue }
            let y = CGFloat(r) * sy
            let limit = min(line.count, first + cols)
            var runStart = first
            var runColor: RGBA?
            var inkStart = -1
            var inkColor: RGBA?
            func flushBG(_ end: Int) {
                if let c = runColor, end > runStart, c != bg {
                    bgRuns[c, default: []].append(CGRect(x: CGFloat(runStart - first) * sx, y: y,
                                                         width: CGFloat(end - runStart) * sx, height: sy))
                }
            }
            func flushInk(_ end: Int) {
                if let c = inkColor, inkStart >= 0, end > inkStart {
                    ink[c, default: []].append(CGRect(x: CGFloat(inkStart - first) * sx, y: y + sy * 0.25,
                                                      width: CGFloat(end - inkStart) * sx, height: sy * 0.5))
                }
            }
            if limit > first {
                for c in first..<limit {
                    let cd = line[c]
                    let attr = cd.attribute
                    let style = attr.style
                    var fg = palette.color(attr.fg, foreground: true, bold: style.contains(.bold))
                    var bgc = palette.color(attr.bg, foreground: false)
                    if style.contains(.inverse) { swap(&fg, &bgc) }
                    if style.contains(.dim) { fg = fg.blended(withFraction: 0.45, of: bg) }
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
            }
            flushBG(limit)
            flushInk(limit)
        }
        backgroundRuns = bgRuns.map { (TWColor($0.key, alpha: 1), $0.value) }
        inkRuns = ink.map { (TWColor($0.key), $0.value) }
        let loc = terminal.getCursorLocation()
        cursorColor = TWColor(palette.cursor)
        if pane.session.cursorVisible, !pane.session.isScrolledBack, loc.y >= 0, loc.y < rows, loc.x >= first, loc.x < first + cols {
            cursor = CGRect(x: CGFloat(loc.x - first) * sx, y: CGFloat(loc.y) * sy, width: sx * 1.5, height: sy)
        } else {
            cursor = nil
        }
    }

    func draw(in rect: CGRect, renderer: Renderer) {
        func scaled(_ r: CGRect) -> CGRect {
            CGRect(x: rect.minX + r.minX * rect.width, y: rect.minY + r.minY * rect.height,
                   width: max(r.width * rect.width, 0.5), height: max(r.height * rect.height, 0.5))
        }
        renderer.clipped(rect) {
            for (color, rects) in backgroundRuns { for r in rects { renderer.fill(scaled(r), color) } }
            for (color, rects) in inkRuns { for r in rects { renderer.fill(scaled(r), color) } }
            if let cursor { renderer.fill(scaled(cursor), cursorColor) }
        }
    }
}
