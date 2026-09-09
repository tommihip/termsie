import AppKit

/// One window (or tab): a sidebar of saved terminals beside a canvas of floating ones.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
                                      TerminalRegistryDelegate, TerminalSidebarDelegate {
    enum Direction { case left, right, up, down }

    let registry = TerminalRegistry()
    private let canvas = PaneCanvasView(frame: .zero)
    private var container: SidebarContainerView!
    private var sidebar: TerminalSidebarView!

    private(set) weak var activePane: TerminalPane?
    private(set) var broadcastEnabled = false
    private var headersVisible: Bool
    private var configObserver: NSObjectProtocol?
    private var isClosing = false
    private var settingsPopover: TerminalSettingsPopover?

    /// True while a drag or resize is running its own event loop. A shell exiting mid-drag would
    /// otherwise deallocate the very view being dragged.
    private var isInteracting = false
    private var deferredWork: [() -> Void] = []

    var onClose: ((TerminalWindowController) -> Void)?
    var onStateChanged: ((TerminalWindowController) -> Void)?

    // MARK: Init

    init(layout: TabLayout?, frame: NSRect?, sidebarVisible: Bool? = nil, sidebarWidth: Double? = nil) {
        let config = ConfigStore.shared.config
        headersVisible = config.showPaneHeaders

        let window = NSWindow(contentRect: frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "TermsieWindow"
        window.minSize = NSSize(width: 520, height: 300)
        window.appearance = NSAppearance(named: .darkAqua)
        // Both are required for SwiftTerm's translucent background and the blurred backdrop to
        // composite at all; an opaque window silently paints over them.
        window.isOpaque = !config.blurBackground
        window.backgroundColor = config.blurBackground ? .clear : NSColor.hex(config.colors.background)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)

        sidebar = TerminalSidebarView(registry: registry)
        sidebar.delegate = self
        container = SidebarContainerView(sidebar: sidebar, canvasHost: canvas)
        container.frame = window.contentRect(forFrameRect: window.frame)
        container.autoresizingMask = [.width, .height]
        container.sidebarWidth = CGFloat(sidebarWidth ?? config.sidebar.width)
        container.sidebarVisible = sidebarVisible ?? config.sidebar.visible
        container.onGeometryChanged = { [weak self] in self?.stateChanged() }
        window.contentView = container

        canvas.controller = self
        canvas.autoresizingMask = [.width, .height]
        registry.delegate = self
        window.delegate = self
        if frame == nil { window.center() }

        let initial = layout ?? TabLayout.single()
        registry.load(initial)
        build(initial)

        configObserver = NotificationCenter.default.addObserver(forName: .termsieConfigChanged,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyConfig()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Building

    private func build(_ layout: TabLayout) {
        container.layoutSubtreeIfNeeded()
        for def in layout.terminals where def.openOnRestore {
            openTerminal(def.id, isReopen: false, focus: false)
        }
        renumber()
        updateEmptyState()
        sidebar.reloadAll()
        if let selected = layout.selected, let pane = registry.pane(for: selected) {
            setActivePane(pane)
        } else {
            setActivePane(registry.livePanes.first)
        }
    }

    var panes: [TerminalPane] { registry.livePanes }

    private func renumber() {
        for (i, id) in registry.order.enumerated() {
            registry.pane(for: id)?.index = i + 1
        }
    }

    private func makePane(_ def: TerminalDefinition, isReopen: Bool) -> TerminalPane {
        let pane = TerminalPane(config: ConfigStore.shared.config, definition: def, isReopen: isReopen)
        pane.controller = self
        pane.showsHeader = headersVisible
        pane.isBroadcasting = broadcastEnabled
        return pane
    }

    // MARK: Terminal lifecycle

    @discardableResult
    func openTerminal(_ id: String, isReopen: Bool, focus: Bool = true) -> TerminalPane? {
        guard let def = registry.definition(id), !registry.isOpen(id) else { return registry.pane(for: id) }
        let pane = makePane(def, isReopen: isReopen)
        let fraction = def.fractionalFrame ?? canvas.fraction(for: Arrange.nextSlot(in: canvas.bounds,
                                                                                    existing: canvas.occupiedFrames))
        canvas.add(pane, fraction: fraction)
        registry.attach(pane, to: id)
        pane.applyEnvironment()
        pane.start()
        renumber()
        updateEmptyState()
        sidebar.reloadAll()
        if focus { setActivePane(pane) }
        stateChanged()
        return pane
    }

    /// Adds a brand new terminal, placed in the next free cascade slot.
    @discardableResult
    func newTerminal(cwd: String? = nil, tileAfter: Bool = false) -> TerminalPane? {
        let frame = Arrange.nextSlot(in: canvas.bounds, existing: canvas.occupiedFrames)
        var def = TerminalDefinition(cwd: cwd ?? activePane?.currentDirectory.map(ProcessInspector.abbreviateHome),
                                     frame: canvas.fraction(for: frame))
        def.z = registry.maxZ + 1
        def.environment = activePane?.environmentID
        let id = registry.insert(def)
        let pane = openTerminal(id, isReopen: false)
        if tileAfter { canvas.tileGrid() }
        return pane
    }

    func closePane(_ pane: TerminalPane, force: Bool = false) {
        guard !isClosing else { return }
        if isInteracting {
            deferredWork.append { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.closePane(pane, force: force)
            }
            return
        }
        if !force, ConfigStore.shared.config.confirmClosingRunningProcess, pane.hasRunningJob, let window {
            let alert = NSAlert()
            alert.messageText = "Close terminal running “\(pane.foregroundJob ?? "process")”?"
            alert.informativeText = "The process will be terminated. Its saved settings are kept."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.detach(pane) }
            }
            return
        }
        detach(pane)
    }

    /// Closing a terminal keeps its definition. The window survives with a populated sidebar —
    /// a window full of saved-but-closed terminals is a normal state now.
    private func detach(_ pane: TerminalPane) {
        let id = pane.definitionID
        canvas.commitFraction(for: pane)
        canvas.remove(pane)
        registry.detach(id)
        renumber()
        updateEmptyState()
        sidebar.reloadAll()
        if activePane === pane { setActivePane(registry.livePanes.first) }
        if registry.openCount == 0 && !container.sidebarVisible { setSidebarVisible(true) }
        stateChanged()
    }

    func paneProcessExited(_ pane: TerminalPane, exitCode: Int32?) {
        guard !isClosing else { return }
        if isInteracting {
            deferredWork.append { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.paneProcessExited(pane, exitCode: exitCode)
            }
            return
        }
        sidebar.reloadRow(pane.definitionID)
        switch ConfigStore.shared.config.closePaneOnExit.lowercased() {
        case "always":
            detach(pane)
        case "never":
            pane.showExitMessage()
        default:
            if exitCode == 0 { detach(pane) } else { pane.showExitMessage() }
        }
    }

    private func updateEmptyState() {
        canvas.emptyMessage = registry.isEmpty
            ? "No terminals. Press ⌘D to add one."
            : "Click a terminal in the list to open it."
        canvas.needsDisplay = true
    }

    // MARK: Interaction guard

    func beginInteraction() { isInteracting = true }

    func endInteraction() {
        isInteracting = false
        let work = deferredWork
        deferredWork = []
        for item in work { item() }
    }

    func canvasGeometryChanged(_ pane: TerminalPane?) {
        if let pane {
            registry.mutate(pane.definitionID) { def in
                def.fractionalFrame = pane.layoutFraction
                def.z = pane.zIndex
            }
        } else {
            for p in registry.livePanes {
                registry.mutate(p.definitionID) { def in
                    def.fractionalFrame = p.layoutFraction
                    def.z = p.zIndex
                }
            }
        }
        stateChanged()
    }

    func paneProducedOutput(_ pane: TerminalPane) {
        sidebar.kickTimer()
    }

    private func stateChanged() {
        onStateChanged?(self)
    }

    // MARK: Focus

    func setActivePane(_ pane: TerminalPane?) {
        guard let pane else {
            activePane?.isActive = false
            activePane = nil
            sidebar.activeID = nil
            sidebar.reloadAll()
            updateWindowTitle()
            return
        }
        if activePane !== pane {
            activePane?.isActive = false
            activePane = pane
            pane.isActive = true
        }
        canvas.raise(pane)
        pane.focusTerminal()
        sidebar.activeID = pane.definitionID
        sidebar.reloadAll()
        updateWindowTitle()
    }

    func paneGainedFocus(_ pane: TerminalPane) {
        guard activePane !== pane else { return }
        activePane?.isActive = false
        activePane = pane
        pane.isActive = true
        canvas.raise(pane)
        sidebar.activeID = pane.definitionID
        sidebar.reloadAll()
        updateWindowTitle()
    }

    func paneInfoChanged(_ pane: TerminalPane) {
        sidebar.reloadRow(pane.definitionID)
        if pane === activePane { updateWindowTitle() }
    }

    private func updateWindowTitle() {
        guard let window else { return }
        var title = AppInfo.name
        if let pane = activePane {
            title = pane.displayTitle
            if !pane.displayDirectory.isEmpty { title += " — " + pane.displayDirectory }
        }
        if broadcastEnabled { title = "⇶ " + title }
        window.title = title
    }

    /// Direction cone plus distance. The old edge test required strict non-overlap and would
    /// silently do nothing once terminals could overlap.
    private func focusNeighbor(_ dir: Direction) {
        guard let active = activePane else { return }
        let a = active.frame
        let ac = NSPoint(x: a.midX, y: a.midY)

        func overlapX(_ r: NSRect) -> CGFloat { min(a.maxX, r.maxX) - max(a.minX, r.minX) }
        func overlapY(_ r: NSRect) -> CGFloat { min(a.maxY, r.maxY) - max(a.minY, r.minY) }

        func pick(slope: CGFloat) -> TerminalPane? {
            var best: (TerminalPane, CGFloat)?
            for pane in registry.livePanes where pane !== active {
                let r = pane.frame
                let c = NSPoint(x: r.midX, y: r.midY)
                let dx = c.x - ac.x, dy = c.y - ac.y
                let along: CGFloat, across: CGFloat, overlap: CGFloat
                switch dir {
                case .left:  along = -dx; across = abs(dy); overlap = overlapY(r)
                case .right: along =  dx; across = abs(dy); overlap = overlapY(r)
                // The canvas is flipped, so "up" is toward smaller y.
                case .up:    along = -dy; across = abs(dx); overlap = overlapX(r)
                case .down:  along =  dy; across = abs(dx); overlap = overlapX(r)
                }
                guard along > 1, across <= along * slope else { continue }
                // The overlap term keeps edge-sharing neighbours preferred, so migrated tiled
                // layouts navigate exactly as they did under splits.
                let score = along + across * 0.5 - max(overlap, 0) * 0.25
                if best == nil || score < best!.1 { best = (pane, score) }
            }
            return best?.0
        }
        if let pane = pick(slope: 1.0) ?? pick(slope: 3.0) { setActivePane(pane) }
    }

    private func focusRelative(_ delta: Int) {
        let list = registry.livePanes
        guard let active = activePane, let idx = list.firstIndex(of: active), list.count > 1 else { return }
        setActivePane(list[(idx + delta + list.count) % list.count])
    }

    // MARK: Broadcast

    func broadcastTargets(from pane: TerminalPane) -> [TermsieTerminalView] {
        guard broadcastEnabled, pane === activePane else { return [] }
        return registry.livePanes.filter { $0 !== pane }.map(\.terminalView)
    }

    // MARK: Config / font

    private func applyFont() {
        for pane in registry.livePanes { pane.applyFont() }
    }

    /// Nudges the focused terminal's own size, recording it as an override so it survives a
    /// relaunch. Without a terminal in focus this would have nothing to act on.
    private func adjustFontSize(by delta: Double) {
        guard let id = activePane?.definitionID, let pane = registry.pane(for: id) else { return }
        let next = min(max(pane.effectiveFontSize + delta, TermsieConfig.minFontSize), TermsieConfig.maxFontSize)
        registry.mutate(id) { $0.fontSize = next }
    }

    private func applyConfig() {
        let config = ConfigStore.shared.config
        headersVisible = config.showPaneHeaders
        window?.isOpaque = !config.blurBackground
        window?.backgroundColor = config.blurBackground ? .clear : NSColor.hex(config.colors.background)
        container.applyConfig()
        for pane in registry.livePanes {
            pane.applyConfig(config)
            pane.applyEnvironment()
        }
        applyFont()
        for id in registry.order { sidebar.dropCache(for: id) }
        sidebar.reloadAll()
        sidebar.refreshVisibleThumbnails(force: true)
        canvas.needsDisplay = true
        container.needsDisplay = true
        container.needsLayout = true
    }

    // MARK: Sidebar

    private func setSidebarVisible(_ visible: Bool) {
        container.sidebarVisible = visible
        if visible {
            sidebar.reloadAll()
            sidebar.refreshVisibleThumbnails(force: true)
        }
        stateChanged()
    }

    func thumbnailRenderCount(for id: String) -> Int { sidebar.renderCount(for: id) }

    /// Number of live blur views, so translucency can be asserted headlessly.
    var backdropCount: Int { container.activeBackdropCount }

    /// Drives the same geometry path as a mouse drag, for headless verification of snapping.
    func simulateDrag(_ pane: TerminalPane, zone: ChromeZone, delta: NSPoint, snapping: Bool = true) {
        pane.beginResizeGesture(zone)
        let proposed = PaneChrome.propose(pane.frame, zone: zone, delta: delta)
        let resolved = canvas.resolve(proposed, for: pane, zone: zone, snapping: snapping)
        pane.frame = resolved
        pane.endResizeGesture(zone)
        canvas.commitFraction(for: pane)
    }

    /// The name shown in a terminal's header and in its sidebar row. They must agree.
    func displayedNames(for id: String) -> (header: String?, row: String) {
        let pane = registry.pane(for: id)
        let def = registry.definition(id)
        return (pane?.header.title, pane?.displayTitle ?? def?.displayName ?? "")
    }

    var sidebarVisible: Bool { container.sidebarVisible }
    var sidebarWidth: Double { Double(container.sidebarWidth) }

    func sidebarDidActivate(_ id: String) {
        guard let pane = registry.pane(for: id) else { return }
        setActivePane(pane)
    }

    func sidebarDidRequestOpen(_ id: String) {
        openTerminal(id, isReopen: true)
    }

    func sidebarDidRequestClose(_ id: String) {
        guard let pane = registry.pane(for: id) else { return }
        closePane(pane)
    }

    func sidebarDidRequestSettings(_ id: String) {
        guard let rect = sidebar.rowRect(for: id) else { return }
        let popover = TerminalSettingsPopover(definitionID: id, registry: registry) { [weak self] defID, commands in
            self?.registry.pane(for: defID)?.runCommandsNow(commands)
        }
        popover.onEnvironmentChange = { [weak self] defID, environment in
            self?.setEnvironment(environment, for: defID)
        }
        settingsPopover = popover
        popover.show(relativeTo: rect, of: sidebar)
    }

    func sidebarDidRequestDuplicate(_ id: String) {
        guard let source = registry.definition(id) else { return }
        var copy = source
        copy.id = TerminalDefinition.newID()
        copy.name = (source.name ?? source.displayName) + " copy"
        copy.z = registry.maxZ + 1
        if let f = source.fractionalFrame {
            copy.fractionalFrame = NSRect(x: min(f.minX + 0.03, 0.9), y: min(f.minY + 0.03, 0.9),
                                          width: f.width, height: f.height)
        }
        copy.openOnRestore = false
        let index = registry.index(of: id).map { $0 + 1 }
        registry.insert(copy, at: index)
        renumber()
        sidebar.reloadAll()
        stateChanged()
    }

    func sidebarDidRequestDelete(_ id: String) {
        guard let def = registry.definition(id) else { return }
        let pane = registry.pane(for: id)
        let confirmNeeded = ConfigStore.shared.config.confirmClosingRunningProcess && (pane?.hasRunningJob ?? false)
        let performDelete = { [weak self] in
            guard let self else { return }
            if let pane { self.canvas.remove(pane) }
            self.sidebar.forgetCache(for: id)
            self.registry.remove(id)
            self.renumber()
            self.updateEmptyState()
            self.sidebar.reloadAll()
            if self.activePane === pane { self.setActivePane(self.registry.livePanes.first) }
            self.stateChanged()
        }
        guard confirmNeeded, let window else { performDelete(); return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(def.displayName)”?"
        alert.informativeText = "It is running \(pane?.foregroundJob ?? "a process"). Its saved settings will also be deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { performDelete() }
        }
    }

    func sidebarDidRequestNew() {
        newTerminal()
    }

    func sidebarDidSetEnvironment(_ environment: String?, for id: String) {
        setEnvironment(environment, for: id)
    }

    func sidebarDidReorder() {
        renumber()
        sidebar.reloadAll()
        stateChanged()
    }

    // MARK: TerminalRegistryDelegate

    func registryDidChangeOrder(_ registry: TerminalRegistry) {
        sidebar?.reloadAll()
    }

    func registry(_ registry: TerminalRegistry, didChange id: String) {
        // The definition is the single source of truth for a terminal's name and environment.
        // Mirroring it onto the live pane here is what keeps the header and the sidebar row from
        // drifting apart, whichever place the user edited.
        if let pane = registry.pane(for: id), let def = registry.definition(id) {
            if pane.customTitle != def.name { pane.customTitle = def.name }
            pane.applyEnvironment()
            pane.applyFont()
        }
        sidebar?.reloadRow(id)
    }

    func registry(_ registry: TerminalRegistry, didOpen id: String, pane: TerminalPane) {
        sidebar?.reloadRow(id)
    }

    func registry(_ registry: TerminalRegistry, didClose id: String) {
        sidebar?.reloadRow(id)
    }

    func registryBecameEmpty(_ registry: TerminalRegistry) {
        guard !isClosing else { return }
        isClosing = true
        window?.close()
    }

    // MARK: Tabs

    func addTab(layout: TabLayout) -> TerminalWindowController {
        let controller = AppDelegate.shared.makeWindowController(layout: layout, frame: nil)
        if let mine = window, let theirs = controller.window {
            mine.addTabbedWindow(theirs, ordered: .above)
            theirs.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    override func newWindowForTab(_ sender: Any?) {
        _ = addTab(layout: TabLayout.single(cwd: activePane?.currentDirectory))
    }

    // MARK: Serialization

    func snapshot(includeLiveState: Bool = false) -> TabLayout {
        for pane in registry.livePanes {
            registry.mutate(pane.definitionID) { def in
                def.fractionalFrame = pane.layoutFraction
                def.z = pane.zIndex
            }
        }
        return registry.snapshot(selected: activePane?.definitionID, includeLiveState: includeLiveState)
    }

    // MARK: Menu actions

    @objc func newTerminalAction(_ sender: Any?) { newTerminal() }
    @objc func newTerminalTiled(_ sender: Any?) { newTerminal(tileAfter: true) }
    @objc func closeActivePane(_ sender: Any?) { if let p = activePane { closePane(p) } }
    @objc func toggleZoom(_ sender: Any?) { activePane?.toggleZoom() }
    @objc func toggleCollapse(_ sender: Any?) { activePane?.toggleCollapsed() }
    @objc func setEnvironmentFromMenu(_ sender: NSMenuItem) {
        guard let id = activePane?.definitionID else { return }
        let value = sender.representedObject as? String
        setEnvironment((value?.isEmpty ?? true) ? nil : value, for: id)
    }

    /// Applies an environment to one terminal and repaints everything that shows it.
    func setEnvironment(_ environment: String?, for id: String) {
        registry.mutate(id) { $0.environment = environment }
        sidebar.dropCache(for: id)
        sidebar.reloadRow(id)
        stateChanged()
    }
    @objc func tileGrid(_ sender: Any?) { canvas.tileGrid() }
    @objc func cascade(_ sender: Any?) { canvas.cascade() }
    @objc func tilePaneLeft(_ sender: Any?) { if let p = activePane { canvas.place(p, .left) } }
    @objc func tilePaneRight(_ sender: Any?) { if let p = activePane { canvas.place(p, .right) } }
    @objc func tilePaneTop(_ sender: Any?) { if let p = activePane { canvas.place(p, .top) } }
    @objc func tilePaneBottom(_ sender: Any?) { if let p = activePane { canvas.place(p, .bottom) } }
    @objc func centerPane(_ sender: Any?) { if let p = activePane { canvas.place(p, .center) } }
    @objc func bringPaneToFront(_ sender: Any?) { if let p = activePane { canvas.raise(p); canvasGeometryChanged(p) } }
    @objc func sendPaneToBack(_ sender: Any?) { if let p = activePane { canvas.sendToBack(p); canvasGeometryChanged(p) } }
    @objc func toggleSidebar(_ sender: Any?) { setSidebarVisible(!container.sidebarVisible) }
    @objc func showTerminalSettings(_ sender: Any?) {
        guard let id = activePane?.definitionID ?? registry.order.first else { return }
        if !container.sidebarVisible { setSidebarVisible(true) }
        sidebarDidRequestSettings(id)
    }
    @objc func duplicateTerminal(_ sender: Any?) {
        guard let id = activePane?.definitionID else { return }
        sidebarDidRequestDuplicate(id)
    }
    @objc func deleteTerminal(_ sender: Any?) {
        guard let id = activePane?.definitionID else { return }
        sidebarDidRequestDelete(id)
    }
    @objc func togglePaneHeaders(_ sender: Any?) {
        headersVisible.toggle()
        for pane in registry.livePanes { pane.showsHeader = headersVisible }
    }
    @objc func toggleBroadcast(_ sender: Any?) {
        broadcastEnabled.toggle()
        for pane in registry.livePanes { pane.isBroadcasting = broadcastEnabled }
        updateWindowTitle()
    }
    @objc func focusLeft(_ sender: Any?) { focusNeighbor(.left) }
    @objc func focusRight(_ sender: Any?) { focusNeighbor(.right) }
    @objc func focusUp(_ sender: Any?) { focusNeighbor(.up) }
    @objc func focusDown(_ sender: Any?) { focusNeighbor(.down) }
    @objc func focusNextPane(_ sender: Any?) { focusRelative(1) }
    @objc func focusPreviousPane(_ sender: Any?) { focusRelative(-1) }
    @objc func focusPaneByNumber(_ sender: NSMenuItem) {
        guard let id = registry.id(at: sender.tag - 1) else { return }
        if let pane = registry.pane(for: id) { setActivePane(pane) }
        else { openTerminal(id, isReopen: true) }
    }
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let group = window?.tabGroup else { return }
        let idx = sender.tag - 1
        guard idx >= 0, idx < group.windows.count else { return }
        group.selectedWindow = group.windows[idx]
    }
    @objc func clearScrollback(_ sender: Any?) { activePane?.clearScrollback() }
    @objc func showFind(_ sender: Any?) { activePane?.showFindBar() }
    @objc func findNext(_ sender: Any?) { activePane?.findNext() }
    @objc func findPrevious(_ sender: Any?) { activePane?.findPrevious() }
    @objc func increaseFontSize(_ sender: Any?) { adjustFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { adjustFontSize(by: -1) }
    /// Drops this terminal's overrides so it follows the global font again.
    @objc func resetFontSize(_ sender: Any?) {
        guard let id = activePane?.definitionID else { return }
        registry.mutate(id) { $0.fontFamily = nil; $0.fontSize = nil }
    }
    @objc func renameActivePane(_ sender: Any?) { renamePane(activePane) }

    @objc func saveWorkspace(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Saves this tab's terminals, their folders and their startup commands to ~/.config/termsie/workspaces/."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        field.placeholderString = "workspace name"
        accessory.addSubview(field)
        let check = NSButton(checkboxWithTitle: "Include commands currently running", target: nil, action: nil)
        check.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
        accessory.addSubview(check)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let layout = self.snapshot(includeLiveState: check.state == .on)
            do { try WorkspaceStore.save(Workspace(name: name, layout: layout)) }
            catch { self.presentError(error) }
        }
    }

    func renamePane(_ pane: TerminalPane?) {
        guard let pane, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Terminal Name"
        alert.informativeText = "Leave empty to show the running process again."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = pane.customTitle ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            // Write only to the definition; the registry callback mirrors it onto the pane.
            self?.registry.mutate(pane.definitionID) { $0.name = name.isEmpty ? nil : name }
            pane.focusTerminal()
            self?.stateChanged()
        }
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(focusPaneByNumber(_:)):
            return item.tag <= registry.count
        case #selector(focusLeft(_:)), #selector(focusRight(_:)), #selector(focusUp(_:)),
             #selector(focusDown(_:)), #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)):
            return registry.openCount > 1
        case #selector(tileGrid(_:)), #selector(cascade(_:)),
             #selector(bringPaneToFront(_:)), #selector(sendPaneToBack(_:)):
            return registry.openCount > 1
        case #selector(toggleZoom(_:)):
            item.title = activePane?.isZoomed == true ? "Restore Terminal" : "Maximize Terminal"
            return activePane != nil
        case #selector(toggleCollapse(_:)):
            item.title = activePane?.isCollapsed == true ? "Expand Terminal" : "Collapse Terminal"
            return activePane != nil
        case #selector(setEnvironmentFromMenu(_:)):
            let current = activePane.flatMap { registry.definition($0.definitionID)?.environment } ?? ""
            item.state = current == (item.representedObject as? String ?? "") ? .on : .off
            return activePane != nil
        case #selector(togglePaneHeaders(_:)):
            item.state = headersVisible ? .on : .off
            return true
        case #selector(toggleBroadcast(_:)):
            item.state = broadcastEnabled ? .on : .off
            return registry.openCount > 1
        case #selector(toggleSidebar(_:)):
            item.state = container.sidebarVisible ? .on : .off
            return true
        case #selector(increaseFontSize(_:)), #selector(decreaseFontSize(_:)), #selector(resetFontSize(_:)):
            return activePane != nil
        case #selector(closeActivePane(_:)), #selector(clearScrollback(_:)), #selector(showFind(_:)),
             #selector(renameActivePane(_:)), #selector(tilePaneLeft(_:)), #selector(tilePaneRight(_:)),
             #selector(tilePaneTop(_:)), #selector(tilePaneBottom(_:)), #selector(centerPane(_:)):
            return activePane != nil
        case #selector(duplicateTerminal(_:)), #selector(deleteTerminal(_:)), #selector(showTerminalSettings(_:)):
            return !registry.isEmpty
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = registry.livePanes.filter(\.hasRunningJob)
        guard ConfigStore.shared.config.confirmClosingRunningProcess, !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = running.count == 1
            ? "Close window running “\(running[0].foregroundJob ?? "process")”?"
            : "Close window with \(running.count) running processes?"
        alert.informativeText = "Running processes will be terminated."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { response in
            if response == .alertFirstButtonReturn {
                self.isClosing = true
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        for pane in registry.livePanes { pane.terminate() }
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        activePane?.focusTerminal()
        sidebar.kickTimer()
    }
}
