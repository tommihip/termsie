import Foundation
import CTermsieHost
import TermsieCore

/// One Termsie window: a top bar with the menu button and tabs, the terminal list, and the
/// canvas of floating terminals. Everything is drawn in one pass and every mouse and key event
/// is routed here, which is what lets overlapping terminals resolve the pointer by what is
/// actually in front.
///
/// The native window underneath is the `host`, which turns the platform's events into the
/// calls below and takes the few things only a platform can do (showing, full screen, where the
/// input method composes). Nothing here names a platform.
final class MainWindow {
    private(set) var tabs: [TabController] = []
    private(set) var selectedIndex = 0
    var selectedTab: TabController? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }
    private(set) var sidebarVisible: Bool
    private(set) var sidebarWidth: CGFloat
    private(set) var host: HostWindow!
    private var renderer: Renderer?
    private var redrawScheduled = false
    private var lastFrame: Double = 0
    private(set) var caretOn = true
    private var blinkTimer: RepeatingTimer?
    private var pollTimer: RepeatingTimer?
    private var thumbnailTimer: RepeatingTimer?
    private var closing = false
    private(set) var lastMouse = CGPoint(x: -1, y: -1)
    private var hover: HoverTarget = .none
    private var lastClick: (time: Double, point: CGPoint, count: Int) = (0, .zero, 0)
    private var drag: DragState = .none

    var onClosed: ((MainWindow) -> Void)?
    var onStateChanged: ((MainWindow) -> Void)?

    private enum HoverTarget: Equatable {
        case none, menuButton, newTab, tab(Int), tabClose(Int)
    }

    private enum DragState {
        case none
        case divider(startX: CGFloat, startWidth: CGFloat)
        case pane(Pane, ChromeZone, start: CGPoint, startFrame: CGRect, quantize: Bool)
        case select(Pane)
        case report(Pane)
        case sidebarRow(String, start: CGPoint, moved: Bool, clickCount: Int)
        case sidebarButton(Sidebar.Hit)
    }

    // MARK: Creating

    init(sidebarVisible: Bool?, sidebarWidth: Double?) {
        let config = ConfigStore.shared.config
        self.sidebarVisible = sidebarVisible ?? config.sidebar.visible
        self.sidebarWidth = CGFloat(min(max(sidebarWidth ?? config.sidebar.width, Double(Theme.sidebarMinWidth)),
                                        Double(Theme.sidebarMaxWidth)))
    }

    /// Creates the native window. `frame` is the saved window rect in screen pixels.
    func open(frame: [Double]?) -> Bool {
        host = makeHostWindow(for: self)
        guard host.open(frame: frame) else { return false }
        host.title = AppInfo.name
        applyChrome()
        renderer = Renderer(host: host)
        renderer?.syncSize()
        startTimers()
        return true
    }

    /// Dark chrome, the blurred backdrop when translucency is on, and the icon.
    func applyChrome() {
        App.shared.backdropActive = host.applyChrome()
    }

    func show(activate: Bool = true) {
        host.show(activate: activate)
        setNeedsDisplay()
    }

    var ref: WindowRef? { host?.ref }
    var dpi: Float { host?.dpi ?? 96 }
    var scale: Double { host?.scale ?? 1 }
    var isVisible: Bool { host?.isVisible ?? false }
    var title: String {
        get { host?.title ?? "" }
        set { host?.title = newValue }
    }

    private func startTimers() {
        let config = ConfigStore.shared.config
        blinkTimer = RepeatingTimer(interval: 0.53) { [weak self] in
            guard let self, let pane = self.selectedTab?.activePane else { return }
            let style = pane.session.cursorStyle
            let blinking = style == .blinkBlock || style == .blinkBar || style == .blinkUnderline || pane.findHasFocus
            guard blinking else { if !self.caretOn { self.caretOn = true; self.setNeedsDisplay() }; return }
            self.caretOn.toggle()
            self.setNeedsDisplay()
        }
        blinkTimer?.start()
        pollTimer = RepeatingTimer(interval: 1.5) { [weak self] in
            guard let self, self.isVisible else { return }
            self.selectedTab?.pollProcesses()
        }
        pollTimer?.start()
        thumbnailTimer = RepeatingTimer(interval: max(0.1, Double(config.sidebar.thumbnailRefreshMs) / 1000)) { [weak self] in
            guard let self, self.sidebarVisible, let tab = self.selectedTab else { return }
            if tab.registry.livePanes.contains(where: \.thumbnailDirty) { self.setNeedsDisplay() }
        }
        thumbnailTimer?.start()
    }

    // MARK: Tabs

    @discardableResult
    func addTab(layout: TabLayout?, workspaceName: String? = nil, runStartupCommands: Bool = true,
                holdShells: Bool = false, select: Bool = true) -> TabController {
        let tab = TabController(layout: layout, workspaceName: workspaceName, runStartupCommands: runStartupCommands,
                                holdShells: holdShells, window: self, canvasSize: canvasRect.size)
        tab.onStateChanged = { [weak self] _ in
            guard let self else { return }
            self.onStateChanged?(self)
        }
        tabs.append(tab)
        if select { selectTab(tabs.count - 1) }
        onStateChanged?(self)
        return tab
    }

    /// Takes an existing tab from another window.
    func adopt(_ tab: TabController) {
        tab.window = self
        tab.onStateChanged = { [weak self] _ in
            guard let self else { return }
            self.onStateChanged?(self)
        }
        tabs.append(tab)
        tab.setCanvasSize(canvasRect.size)
        tab.dpiChanged(dpi)
        selectTab(tabs.count - 1)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        selectedTab?.setCanvasSize(canvasRect.size)
        selectedTab?.updateWindowTitle()
        onStateChanged?(self)
        setNeedsDisplay()
    }

    /// Removes a tab without ending its terminals, for moving it to another window.
    func detachTab(_ tab: TabController) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        if tabs.isEmpty {
            closing = true
            host.destroy()
            return
        }
        selectTab(min(i, tabs.count - 1))
    }

    func closeTab(_ tab: TabController, force: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        if !force {
            guard tab.confirmTerminatingRunningJobs(closing: "tab") else { return }
        }
        if tabs.count == 1 {
            // The last tab takes its window with it; closing the last window quits.
            requestClose(force: force)
            return
        }
        tab.terminateAll()
        tabs.remove(at: i)
        selectTab(min(i, tabs.count - 1))
        onStateChanged?(self)
    }

    func tabTitleChanged(_ tab: TabController) {
        if tab === selectedTab { title = tab.windowTitle }
        setNeedsDisplay()
    }

    // MARK: Sidebar

    func setSidebarVisible(_ visible: Bool) {
        sidebarVisible = visible
        layoutChanged()
        onStateChanged?(self)
    }

    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(max(width, Theme.sidebarMinWidth), Theme.sidebarMaxWidth)
        layoutChanged()
        onStateChanged?(self)
    }

    // MARK: Layout

    /// Client area in DIPs.
    var bounds: CGRect {
        let px = host.clientPixelSize
        return CGRect(x: 0, y: 0, width: CGFloat(px.width) / CGFloat(scale), height: CGFloat(px.height) / CGFloat(scale))
    }

    var topBarRect: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: Theme.topBarHeight) }

    var sidebarRect: CGRect {
        guard sidebarVisible else { return .zero }
        return CGRect(x: 0, y: Theme.topBarHeight, width: sidebarWidth, height: max(0, bounds.height - Theme.topBarHeight))
    }

    var dividerRect: CGRect {
        guard sidebarVisible else { return .zero }
        return CGRect(x: sidebarWidth - Theme.dividerGrab / 2, y: Theme.topBarHeight,
                      width: Theme.dividerGrab + Theme.dividerWidth, height: sidebarRect.height)
    }

    var canvasRect: CGRect {
        let x = sidebarVisible ? sidebarWidth + Theme.dividerWidth : 0
        return CGRect(x: x, y: Theme.topBarHeight, width: max(0, bounds.width - x),
                      height: max(0, bounds.height - Theme.topBarHeight))
    }

    /// The window changed size: lay the tabs out again.
    func layoutChanged() {
        renderer?.syncSize()
        for tab in tabs { tab.setCanvasSize(canvasRect.size) }
        setNeedsDisplay()
    }

    /// The window was resized by the user; the host paints right away so the frame keeps up.
    func windowResized() {
        layoutChanged()
        paint()
        onStateChanged?(self)
    }

    func windowMoved() {
        onStateChanged?(self)
    }

    func dpiChanged() {
        for tab in tabs { tab.dpiChanged(dpi) }
        layoutChanged()
    }

    func focusChanged() {
        caretOn = true
        setNeedsDisplay()
    }

    // MARK: Drawing

    func setNeedsDisplay() {
        guard !redrawScheduled, host != nil else { return }
        redrawScheduled = true
        // At most one frame per display refresh, however fast output arrives.
        let wait = max(0, 1.0 / 120 - (Clock.now - lastFrame))
        MainQueue.shared.after(wait) { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.host.requestPaint()
        }
    }

    /// Draws a frame. The host calls this when the platform is ready to show one.
    func paint() {
        guard let renderer, isVisible || DebugDriver.isActive else { return }
        renderer.syncSize()
        lastFrame = Clock.now
        if !renderer.draw({ drawFrame(renderer) }) {
            Log.write("render device lost; rebuilding")
            self.renderer = Renderer(host: host)
            setNeedsDisplay()
        }
    }

    /// Draws the window into a PNG, for the headless tests.
    func snapshot(to path: String) -> Bool {
        guard let renderer else { return false }
        renderer.syncSize()
        let px = host.clientPixelSize
        return renderer.snapshot(to: path, width: px.width, height: px.height) { drawFrame(renderer, opaque: true) }
    }

    private func drawFrame(_ renderer: Renderer, opaque: Bool = false) {
        let config = ConfigStore.shared.config
        let c = config.colors
        let translucent = App.shared.backdropActive && !opaque
        if translucent {
            renderer.clear(.clear)
            // Only a wash over the canvas: the blurred backdrop has to show through.
            renderer.fill(canvasRect, Theme.color(c.background, alpha: 0.25))
        } else {
            renderer.clear(Theme.color(c.background, alpha: 1))
        }

        if let tab = selectedTab {
            let canvas = canvasRect
            renderer.clipped(canvas) {
                let focused = host.isFocused || DebugDriver.isActive
                for pane in tab.stackedPanes {
                    pane.draw(renderer: renderer, origin: canvas.origin, focused: focused, caretOn: caretOn)
                }
                if tab.panes.isEmpty, let message = tab.emptyMessage {
                    renderer.text(message, in: canvas, font: Theme.ui(13), color: Theme.color(c.headerText), align: .center)
                }
            }
            if sidebarVisible {
                tab.sidebar.draw(in: sidebarRect, renderer: renderer)
                renderer.fill(CGRect(x: sidebarWidth, y: Theme.topBarHeight, width: Theme.dividerWidth, height: sidebarRect.height),
                              Theme.color(c.divider))
            }
        }
        drawTopBar(renderer)
        positionIME()
    }

    // MARK: Top bar

    private var menuButtonRect: CGRect { CGRect(x: 4, y: 3, width: 34, height: Theme.topBarHeight - 6) }

    private var tabRects: [CGRect] {
        guard !tabs.isEmpty else { return [] }
        let start = menuButtonRect.maxX + 6
        let available = bounds.width - start - 44
        let width = min(220, max(80, available / CGFloat(tabs.count)))
        return tabs.indices.map { CGRect(x: start + CGFloat($0) * width, y: 4, width: width - 4, height: Theme.topBarHeight - 4) }
    }

    private var newTabRect: CGRect {
        let x = (tabRects.last?.maxX ?? menuButtonRect.maxX) + 6
        return CGRect(x: x, y: 6, width: 26, height: Theme.topBarHeight - 12)
    }

    private func closeRect(_ tab: CGRect) -> CGRect {
        CGRect(x: tab.maxX - 22, y: tab.midY - 8, width: 16, height: 16)
    }

    private func drawTopBar(_ renderer: Renderer) {
        let c = Theme.colors
        let bar = topBarRect
        renderer.fill(bar, Theme.color(c.headerBackground, alpha: App.shared.backdropActive ? 0.9 : 1))
        renderer.fill(CGRect(x: 0, y: bar.maxY - 1, width: bar.width, height: 1), Theme.color(c.divider))

        let menu = menuButtonRect
        if hover == .menuButton { renderer.fillRounded(menu, radius: 5, TWColor(r: 1, g: 1, b: 1, a: 0.08)) }
        Draw.menuGlyph(in: menu, color: Theme.color(c.headerActiveText), renderer: renderer)

        for (i, r) in tabRects.enumerated() {
            let tab = tabs[i]
            let selected = i == selectedIndex
            if selected {
                renderer.fillRounded(r, radius: 6, Theme.color(c.headerActiveBackground))
                renderer.fill(CGRect(x: r.minX + 8, y: r.maxY - 2, width: r.width - 16, height: 2), Theme.color(c.activeBorder))
            } else if hover == .tab(i) || hover == .tabClose(i) {
                renderer.fillRounded(r, radius: 6, TWColor(r: 1, g: 1, b: 1, a: 0.05))
            }
            var label = tab.title
            if let ws = tab.workspaceName { label = ws + " — " + label }
            if tab.isWorkspaceModified { label = "• " + label }
            let showClose = tabs.count > 1 && (selected || hover == .tab(i) || hover == .tabClose(i))
            let textRect = CGRect(x: r.minX + 10, y: r.minY, width: r.width - 20 - (showClose ? 18 : 0), height: r.height)
            renderer.text(label, in: textRect, font: Theme.ui(11, bold: selected),
                          color: Theme.color(selected ? c.headerActiveText : c.headerText))
            if showClose {
                let x = closeRect(r)
                if hover == .tabClose(i) { renderer.fillRounded(x, radius: 3, TWColor(r: 1, g: 1, b: 1, a: 0.12)) }
                Draw.cross(in: x, color: Theme.color(c.headerText), renderer: renderer)
            }
        }
        let plus = newTabRect
        if hover == .newTab { renderer.fillRounded(plus, radius: 5, TWColor(r: 1, g: 1, b: 1, a: 0.08)) }
        Draw.plus(in: plus, color: Theme.color(c.headerText), renderer: renderer)
    }

    private func topBarHover(_ p: CGPoint) -> HoverTarget {
        guard topBarRect.contains(p) else { return .none }
        if menuButtonRect.contains(p) { return .menuButton }
        if newTabRect.contains(p) { return .newTab }
        for (i, r) in tabRects.enumerated() where r.contains(p) {
            return tabs.count > 1 && closeRect(r).contains(p) ? .tabClose(i) : .tab(i)
        }
        return .none
    }

    // MARK: Menu

    func showMenu(at p: CGPoint) {
        guard selectedTab != nil else { return }
        let items = MenuBuilder.structure(workspaces: WorkspaceStore.list(),
                                          environments: ConfigStore.shared.config.environments, tabCount: tabs.count)
        let (menu, table) = MenuBuilder.build(items, enabled: { self.canPerform($0) }, checked: { self.isChecked($0) })
        let chosen = menu.track(in: ref, x: Int((p.x * CGFloat(scale)).rounded()), y: Int((p.y * CGFloat(scale)).rounded()))
        if chosen != 0, let command = table[chosen] { perform(command) }
    }

    func canPerform(_ command: Command) -> Bool {
        switch command {
        case .closeTab, .nextTab, .previousTab, .moveTabToNewWindow: return tabs.count > 1
        case .mergeAllWindows: return App.shared.windows.count > 1
        default: return selectedTab?.canPerform(command) ?? true
        }
    }

    func isChecked(_ command: Command) -> Bool {
        switch command {
        case .fullScreen: return host.isFullScreen
        case .toggleSidebar: return sidebarVisible
        default: return selectedTab?.isChecked(command) ?? false
        }
    }

    func perform(_ command: Command) {
        switch command {
        case .newTab:
            addTab(layout: TabLayout.single(cwd: selectedTab?.activePane?.currentDirectory.map { HomePath.abbreviate($0) }))
        case .closeTab: if let tab = selectedTab { closeTab(tab) }
        case .nextTab: if !tabs.isEmpty { selectTab((selectedIndex + 1) % tabs.count) }
        case .previousTab: if !tabs.isEmpty { selectTab((selectedIndex - 1 + tabs.count) % tabs.count) }
        case .moveTabToNewWindow:
            guard tabs.count > 1, let tab = selectedTab else { return }
            App.shared.moveTabToNewWindow(tab, from: self)
        case .mergeAllWindows: App.shared.mergeAllWindows(into: self)
        case .toggleSidebar: setSidebarVisible(!sidebarVisible)
        case .fullScreen: host.toggleFullScreen()
        default:
            if selectedTab?.perform(command) != true {
                App.shared.perform(command, from: self)
            }
        }
        setNeedsDisplay()
    }

    // MARK: Closing

    /// Asks about running processes across every tab, then closes. Closing the last window is
    /// quitting, so the session is saved with this window still in it.
    func requestClose(force: Bool = false) {
        guard !closing else { return }
        if !force {
            let running = tabs.flatMap { $0.registry.livePanes }.filter(\.hasRunningJob)
            if ConfigStore.shared.config.confirmClosingRunningProcess, !running.isEmpty, !DebugDriver.isActive {
                let q = running.count == 1
                    ? "Close the window while “\(running[0].foregroundJob ?? "a process")” is running?"
                    : "Close the window with \(running.count) running processes?"
                guard Alert.confirm(q, "Running processes will be ended.", owner: ref, warning: true) else { return }
            }
        }
        closing = true
        App.shared.windowWillClose(self)
        for tab in tabs { tab.terminateAll() }
        host.destroy()
    }

    /// The native window is gone.
    func windowDestroyed() {
        blinkTimer?.stop()
        pollTimer?.stop()
        thumbnailTimer?.stop()
        onClosed?(self)
    }

    /// The saved form of this window.
    var sessionSnapshot: SessionSnapshot.WindowSnapshot {
        SessionSnapshot.WindowSnapshot(frame: host.frame, tabs: tabs.map { $0.snapshot() }, selectedTab: selectedIndex,
                                       sidebarVisible: sidebarVisible, sidebarWidth: Double(sidebarWidth))
    }

    // MARK: Input: geometry helpers

    private func canvasPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - canvasRect.minX, y: p.y - canvasRect.minY)
    }

    private func clickCount(at p: CGPoint, isDouble: Bool) -> Int {
        let now = Clock.now
        var count = 1
        if now - lastClick.time < Host.doubleClickInterval, abs(p.x - lastClick.point.x) < 5, abs(p.y - lastClick.point.y) < 5 {
            count = lastClick.count + 1
        } else if isDouble {
            count = 2
        }
        lastClick = (now, p, count)
        return count
    }

    /// Whether a drag is reporting mouse events to a program, which wants every button's release.
    var isReportingMouse: Bool {
        if case .report = drag { return true }
        return false
    }

    // MARK: Input: mouse

    /// A button went down at `p` (DIPs). `isDouble` is the platform's own double-click
    /// detection, where it has one; the count is kept here either way.
    func mouseDown(_ p: CGPoint, button: Int, isDouble: Bool, modifiers m: Modifiers) {
        let count = button == 0 ? clickCount(at: p, isDouble: isDouble) : 1
        if topBarRect.contains(p) {
            guard button == 0 else { return }
            switch topBarHover(p) {
            case .menuButton: showMenu(at: CGPoint(x: menuButtonRect.minX, y: menuButtonRect.maxY))
            case .newTab: perform(.newTab)
            case .tab(let i): if count == 2 { selectTab(i); perform(.renameTerminal) } else { selectTab(i) }
            case .tabClose(let i): closeTab(tabs[i])
            case .none: if count == 2 { perform(.newTab) }
            }
            return
        }
        guard let tab = selectedTab else { return }
        if sidebarVisible, dividerRect.contains(p), button == 0 {
            drag = .divider(startX: p.x, startWidth: sidebarWidth)
            host.setCapture()
            return
        }
        if sidebarVisible, sidebarRect.contains(p) {
            let hit = tab.sidebar.hit(p, in: sidebarRect)
            if button == 2 {
                if case .row(let id) = hit { showRowMenu(id, at: p) }
                return
            }
            guard button == 0 else { return }
            switch hit {
            case .row(let id):
                drag = .sidebarRow(id, start: p, moved: false, clickCount: count)
                host.setCapture()
            case .empty:
                break
            default:
                drag = .sidebarButton(hit)
                host.setCapture()
            }
            return
        }
        guard canvasRect.contains(p) else { return }
        let cp = canvasPoint(p)
        guard let pane = tab.topmostPane(at: cp), let hit = pane.hit(cp) else { return }
        if button == 2 {
            tab.setActivePane(pane)
            if hit == .terminal, pane.reportsMouse(m) {
                pane.mouseDown(at: cp, button: 2, clickCount: 1, modifiers: m)
                drag = .report(pane)
                host.setCapture()
                return
            }
            if hit == .header { showHeaderMenu(pane, at: p) } else { showTerminalMenu(pane, at: p) }
            return
        }
        tab.setActivePane(pane)
        switch hit {
        case .close: tab.closePane(pane)
        case .collapse: pane.toggleCollapsed()
        case .zoom: pane.toggleZoom(); tab.canvasGeometryChanged(pane)
        case .header:
            if count == 2 { pane.toggleZoom(); tab.canvasGeometryChanged(pane); return }
            beginPaneDrag(pane, zone: .move, at: cp)
        case .chrome(let zone):
            beginPaneDrag(pane, zone: zone, at: cp)
        case .findBar:
            tab.focusFind(pane)
        case .terminal:
            pane.findHasFocus = false
            // Ctrl+Alt+drag anywhere in a terminal moves it, so hidden headers never strand one.
            if button == 0, m.contains(.control), m.contains(.alt) {
                beginPaneDrag(pane, zone: .move, at: cp)
                return
            }
            if button == 1, pane.session.terminal.mouseMode == .off {
                // Middle click pastes the selection, as on X11 and in Windows Terminal.
                if let text = Clipboard.getSelection() { pane.session.paste(text) }
                return
            }
            pane.mouseDown(at: cp, button: button, clickCount: count, modifiers: m)
            drag = pane.reportsMouse(m) ? .report(pane) : .select(pane)
            host.setCapture()
        }
        setNeedsDisplay()
    }

    private func beginPaneDrag(_ pane: Pane, zone: ChromeZone, at cp: CGPoint) {
        guard let tab = selectedTab else { return }
        tab.raise(pane)
        tab.beginInteraction()
        pane.clearZoom()
        if zone != .move { pane.isUserResizing = true }
        let quantize = ConfigStore.shared.config.snapToCells && zone != .move
        drag = .pane(pane, zone, start: cp, startFrame: pane.frame, quantize: quantize)
        host.setCapture()
    }

    func mouseMoved(_ p: CGPoint, modifiers m: Modifiers) {
        lastMouse = p
        guard let tab = selectedTab else { return }
        switch drag {
        case .none:
            var nextHover = topBarHover(p)
            if nextHover == .none, hover != .none { nextHover = .none }
            if nextHover != hover { hover = nextHover; setNeedsDisplay() }
            let sidebarHover: Sidebar.Hit? = sidebarVisible && sidebarRect.contains(p) ? tab.sidebar.hit(p, in: sidebarRect) : nil
            if sidebarHover != tab.sidebar.hover { tab.sidebar.hover = sidebarHover; setNeedsDisplay() }
            if canvasRect.contains(p) {
                let cp = canvasPoint(p)
                tab.topmostPane(at: cp)?.mouseMoved(to: cp, modifiers: m)
            }
        case .divider(let startX, let startWidth):
            setSidebarWidth(startWidth + p.x - startX)
        case .pane(let pane, let zone, let start, let startFrame, let quantize):
            let cp = canvasPoint(p)
            let delta = CGPoint(x: cp.x - start.x, y: cp.y - start.y)
            var proposed = PaneChrome.propose(startFrame, zone: zone, delta: delta)
            if quantize { proposed = pane.quantizeToCells(proposed, zone: zone) }
            // Holding Ctrl suspends snapping, as Command does on macOS.
            let snapping = !m.contains(.control) || zone == .move && m.contains(.alt)
            let resolved = tab.resolve(proposed, for: pane, zone: zone, snapping: snapping)
            if resolved != pane.frame { pane.frame = resolved }
            setNeedsDisplay()
        case .select(let pane), .report(let pane):
            pane.mouseDragged(to: canvasPoint(p), modifiers: m)
        case .sidebarRow(let id, let start, let moved, let count):
            if !moved, abs(p.y - start.y) > 4 {
                drag = .sidebarRow(id, start: start, moved: true, clickCount: count)
            }
            if case .sidebarRow(_, _, true, _) = drag {
                tab.sidebar.drag = (id, p.y)
                setNeedsDisplay()
            }
        case .sidebarButton:
            break
        }
    }

    func mouseLeft() {
        hover = .none
        selectedTab?.sidebar.hover = nil
        setNeedsDisplay()
    }

    /// The platform took the pointer away mid-drag: end it where it was.
    func captureLost() {
        if case .none = drag { return }
        mouseUp(lastMouse, button: 0, modifiers: [])
    }

    func mouseUp(_ p: CGPoint, button: Int, modifiers m: Modifiers) {
        // Only the left button starts a drag, except for a program reading mouse events, which
        // wants every button's release.
        if button != 0, !isReportingMouse { return }
        let state = drag
        drag = .none
        host.releaseCapture()
        guard let tab = selectedTab else { return }
        switch state {
        case .none:
            break
        case .divider:
            break
        case .pane(let pane, let zone, _, _, _):
            if zone != .move {
                pane.isUserResizing = false
                pane.transientNote = nil
            }
            tab.commitFraction(for: pane)
            tab.endInteraction()
        case .select(let pane), .report(let pane):
            pane.mouseUp(at: canvasPoint(p), modifiers: m)
        case .sidebarRow(let id, _, let moved, let count):
            if moved {
                let index = tab.sidebar.dropIndex(at: p.y, in: sidebarRect)
                tab.sidebar.drag = nil
                tab.sidebarDidReorder(id, to: index)
            } else if count == 2 {
                tab.sidebarDidRequestSettings(id)
            } else {
                tab.sidebarDidActivate(id)
            }
        case .sidebarButton(let hit):
            guard tab.sidebar.hit(p, in: sidebarRect) == hit else { break }
            switch hit {
            case .run(let id): tab.runStartupCommands(for: id, askIfBusy: true)
            case .newTerminal: tab.newTerminal()
            case .runAll: tab.runAllStartupCommands()
            case .copy(let target): tab.performCopy(target)
            case .autoCopy: tab.toggleAutoCopy()
            default: break
            }
        }
        setNeedsDisplay()
    }

    /// The wheel turned by `steps` notches, positive away from the user (towards the top of
    /// the content) or to the left.
    func wheel(_ p: CGPoint, steps: Double, horizontal: Bool, modifiers m: Modifiers) {
        guard let tab = selectedTab, steps != 0 else { return }
        if sidebarVisible, sidebarRect.contains(p), !horizontal {
            tab.sidebar.scroll(by: -CGFloat(steps) * 48, in: sidebarRect)
            setNeedsDisplay()
            return
        }
        guard canvasRect.contains(p) else { return }
        let cp = canvasPoint(p)
        guard let pane = tab.topmostPane(at: cp) else { return }
        if horizontal {
            pane.horizontalWheel(columns: Int((steps * 3).rounded(.towardZero)))
            return
        }
        if m.contains(.control) {
            tab.setActivePane(pane)
            perform(steps > 0 ? .biggerText : .smallerText)
            return
        }
        let lines = -Int((steps * Double(Host.wheelScrollLines)).rounded(.awayFromZero))
        pane.wheel(lines: lines, at: cp, modifiers: m)
        setNeedsDisplay()
    }

    func cursorShape(at p: CGPoint, modifiers m: Modifiers) -> CursorShape {
        if case .divider = drag { return .sizeWE }
        if case .pane(_, let zone, _, _, _) = drag { return zone.cursorShape }
        if topBarRect.contains(p) { return .arrow }
        if sidebarVisible, dividerRect.contains(p) { return .sizeWE }
        if sidebarVisible, sidebarRect.contains(p) {
            switch selectedTab?.sidebar.hit(p, in: sidebarRect) {
            case .run, .newTerminal, .runAll, .copy, .autoCopy: return .hand
            default: return .arrow
            }
        }
        guard canvasRect.contains(p), let tab = selectedTab else { return .arrow }
        let cp = canvasPoint(p)
        return tab.topmostPane(at: cp)?.cursor(at: cp, modifiers: m) ?? .arrow
    }

    // MARK: Context menus

    private func popup(_ items: [(String, Bool, Bool, () -> Void)], at p: CGPoint) {
        let menu = NativeMenu()
        for (i, item) in items.enumerated() {
            if item.0 == "-" { menu.appendSeparator(); continue }
            menu.append(id: Int32(i + 1), title: item.0, enabled: item.1, checked: item.2)
        }
        let chosen = Int(menu.track(in: ref, x: Int((p.x * CGFloat(scale)).rounded()), y: Int((p.y * CGFloat(scale)).rounded())))
        if chosen > 0, chosen <= items.count { items[chosen - 1].3() }
        setNeedsDisplay()
    }

    private func environmentItems(for id: String) -> [(String, Bool, Bool, () -> Void)] {
        guard let tab = selectedTab else { return [] }
        let current = tab.registry.definition(id)?.environment ?? ""
        var items: [(String, Bool, Bool, () -> Void)] = [("Environment: None", true, current.isEmpty, { tab.setEnvironment(nil, for: id) })]
        for style in ConfigStore.shared.config.environments {
            items.append(("Environment: \(style.label)", true, current == style.id, { tab.setEnvironment(style.id, for: id) }))
        }
        return items
    }

    private func showRowMenu(_ id: String, at p: CGPoint) {
        guard let tab = selectedTab else { return }
        let open = tab.registry.isOpen(id)
        var items: [(String, Bool, Bool, () -> Void)] = [
            (open ? "Close Terminal" : "Open Terminal", true, false, {
                if open { tab.sidebarDidRequestClose(id) } else { tab.sidebarDidActivate(id) }
            }),
            ("Run Startup Commands", tab.hasStartupCommands(id), false, { tab.runStartupCommands(for: id, askIfBusy: true) }),
            ("-", true, false, {}),
            ("Terminal Settings…", true, false, { tab.sidebarDidRequestSettings(id) }),
            ("Set Terminal Name…", open, false, { tab.renamePane(tab.registry.pane(for: id)) }),
            ("Workspace Settings…", true, false, { tab.showWorkspaceSettings(selecting: id) }),
            ("-", true, false, {}),
        ]
        items += environmentItems(for: id)
        items += [
            ("-", true, false, {}),
            ("Duplicate", true, false, { tab.sidebarDidRequestDuplicate(id) }),
            ("Delete…", true, false, {
                if Alert.yesNo("Delete this terminal?", "Its saved settings and kept output are deleted too.", owner: self.ref,
                               defaultNo: true) {
                    tab.sidebarDidRequestDelete(id)
                }
            }),
        ]
        popup(items, at: p)
    }

    private func showHeaderMenu(_ pane: Pane, at p: CGPoint) {
        guard let tab = selectedTab else { return }
        var items: [(String, Bool, Bool, () -> Void)] = [
            (pane.isZoomed ? "Restore" : "Maximize", true, false, { pane.toggleZoom(); tab.canvasGeometryChanged(pane) }),
            (pane.isCollapsed ? "Expand" : "Collapse", true, false, { pane.toggleCollapsed() }),
            ("Rename…", true, false, { tab.renamePane(pane) }),
            ("Terminal Settings…", true, false, { tab.sidebarDidRequestSettings(pane.definitionID) }),
            ("-", true, false, {}),
        ]
        items += environmentItems(for: pane.definitionID)
        items += [
            ("-", true, false, {}),
            ("Bring to Front", true, false, { tab.raise(pane); tab.canvasGeometryChanged(pane) }),
            ("Send to Back", true, false, { tab.sendToBack(pane); tab.canvasGeometryChanged(pane) }),
            ("-", true, false, {}),
            ("Close Terminal", true, false, { tab.closePane(pane) }),
        ]
        popup(items, at: p)
    }

    private func showTerminalMenu(_ pane: Pane, at p: CGPoint) {
        guard let tab = selectedTab else { return }
        let items: [(String, Bool, Bool, () -> Void)] = [
            ("Copy", pane.canCopy(.selection), false, { tab.performCopy(.selection) }),
            ("Paste", true, false, { if let t = Clipboard.get() { pane.session.paste(t) } }),
            ("Select All", true, false, { pane.session.selection.selectAll(); self.setNeedsDisplay() }),
            ("-", true, false, {}),
            (CopyTarget.lastCommandOutput.title, pane.canCopy(.lastCommandOutput), false, { tab.performCopy(.lastCommandOutput) }),
            (CopyTarget.lastCommand.title, pane.canCopy(.lastCommand), false, { tab.performCopy(.lastCommand) }),
            (CopyTarget.wholeTerminal.title, true, false, { tab.performCopy(.wholeTerminal) }),
            ("-", true, false, {}),
            ("Find…", true, false, { pane.showFindBar() }),
            ("Clear Scrollback", true, false, { pane.clearScrollback() }),
            ("-", true, false, {}),
            ("Terminal Settings…", true, false, { tab.sidebarDidRequestSettings(pane.definitionID) }),
        ]
        popup(items, at: p)
    }

    // MARK: Input: keyboard

    /// A key went down, before the platform turns it into text. Returns true when the key was
    /// used up: a shortcut, a find-field edit, or keys sent straight to the shell.
    func keyDown(_ key: Key, modifiers m: Modifiers) -> Bool {
        let ctrl = m.contains(.control), shift = m.contains(.shift), alt = m.contains(.alt)
        guard let tab = selectedTab else { return false }
        let pane = tab.activePane

        // Ctrl+C copies when there is a selection and is ^C otherwise, as in Windows Terminal.
        if ctrl && !shift && !alt && key == .char("C"), let pane, pane.canCopy(.selection), !pane.findHasFocus {
            tab.performCopy(.selection)
            pane.session.selection.selectNone()
            setNeedsDisplay()
            return true
        }

        if let pane, pane.findHasFocus, let field = pane.findField {
            if let command = Keymap.command(for: Shortcut(key: key, ctrl: ctrl, shift: shift, alt: alt)),
               command == .findNext || command == .findPrevious || command == .find {
                perform(command)
                return true
            }
            if field.keyDown(key, ctrl: ctrl, shift: shift) {
                setNeedsDisplay()
                return true
            }
            return false
        }

        if let command = Keymap.command(for: Shortcut(key: key, ctrl: ctrl, shift: shift, alt: alt)) {
            if case .terminal = command, !canPerform(command) { return false }
            perform(command)
            return true
        }

        guard let pane else { return false }
        if key == .escape, pane.findField != nil, !ctrl, !alt {
            pane.hideFindBar()
            return true
        }
        // Shift with the paging keys moves through the scrollback rather than reaching the shell.
        if shift && !ctrl && !alt {
            let rows = pane.session.terminal.rows
            switch key {
            case .pageUp: pane.session.scroll(by: -max(1, rows - 1)); setNeedsDisplay(); return true
            case .pageDown: pane.session.scroll(by: max(1, rows - 1)); setNeedsDisplay(); return true
            case .home where !pane.session.terminal.isCurrentBufferAlternate:
                pane.session.scroll(toLine: 0); setNeedsDisplay(); return true
            case .end where !pane.session.terminal.isCurrentBufferAlternate:
                pane.session.scrollToBottom(); setNeedsDisplay(); return true
            default: break
            }
        }
        if let bytes = KeyEncoder.keyDown(key: key, modifiers: m, applicationCursor: pane.session.terminal.applicationCursor) {
            sendToTerminal(pane, bytes)
            return true
        }
        return false
    }

    private func sendToTerminal(_ pane: Pane, _ bytes: [UInt8]) {
        pane.session.selection.selectNone()
        pane.session.send(user: bytes)
        pane.revealCursorColumn()
        caretOn = true
        setNeedsDisplay()
    }

    /// Text the platform produced for a key or an input method. `meta` is Alt held: the xterm
    /// convention, ESC then the text.
    func insertText(_ text: String, meta: Bool) {
        guard let pane = selectedTab?.activePane, !text.isEmpty else { return }
        if pane.findHasFocus, let field = pane.findField {
            field.insert(text)
            setNeedsDisplay()
            return
        }
        // Backspace and DEL are sent from the key itself, with the right meaning.
        if text == "\u{8}" || text == "\u{7f}" { return }
        var bytes = Array(text.utf8)
        if meta { bytes.insert(0x1b, at: 0) }
        sendToTerminal(pane, bytes)
    }

    private func positionIME() {
        guard let tab = selectedTab, let pane = tab.activePane, !pane.findHasFocus else { return }
        let loc = pane.session.terminal.getCursorLocation()
        let m = pane.fonts.metrics
        let t = pane.textRect.offsetBy(dx: canvasRect.minX, dy: canvasRect.minY)
        let x = (t.minX + CGFloat(loc.x - pane.firstColumn) * m.cellWidth) * CGFloat(scale)
        let y = (t.minY + CGFloat(loc.y) * m.cellHeight) * CGFloat(scale)
        host.setIMEPosition(x: Int(x), y: Int(y), lineHeight: Int(m.cellHeight * CGFloat(scale)))
    }
}
