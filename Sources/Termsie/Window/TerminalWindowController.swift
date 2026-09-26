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
    private var workspacePanel: WorkspaceSettingsWindowController?
    /// The workspace this tab represents, and the layout as last saved or loaded. Together they
    /// answer "does this have unsaved changes?".
    private(set) var workspaceName: String?
    private var savedSignature: String = ""

    /// True while a drag or resize is running its own event loop. A shell exiting mid-drag would
    /// otherwise deallocate the very view being dragged.
    private var isInteracting = false
    private var deferredWork: [() -> Void] = []
    /// Terminals on screen whose shells wait for the answer to "run the startup commands?", so
    /// the commands can still run the proper way — from the shell, before its first prompt —
    /// rather than be typed in afterwards.
    private var heldPanes: [TerminalPane] = []

    var onClose: ((TerminalWindowController) -> Void)?
    var onStateChanged: ((TerminalWindowController) -> Void)?

    // MARK: Init

    /// - Parameter holdShells: open the terminals but start no shells until
    ///   `startHeldTerminals(runningCommands:)`, for asking about the startup commands once the
    ///   window is on screen.
    init(layout: TabLayout?, frame: NSRect?, sidebarVisible: Bool? = nil, sidebarWidth: Double? = nil,
         workspaceName: String? = nil, runStartupCommands: Bool = true, holdShells: Bool = false) {
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
        // Cursor rects cannot express "the terminal in front owns this point", which is exactly
        // what overlapping terminals need. SidebarContainerView drives the pointer instead, fed by
        // the app-wide mouse-moved monitor in AppDelegate.
        window.disableCursorRects()
        window.acceptsMouseMovedEvents = true
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
        self.workspaceName = workspaceName ?? initial.workspaceName
        registry.load(initial)
        build(initial, runCommands: runStartupCommands, holdShells: holdShells)
        markSaved()

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

    /// `runCommands` false opens every terminal without its startup commands, leaving the saved
    /// commands themselves untouched.
    private func build(_ layout: TabLayout, runCommands: Bool, holdShells: Bool) {
        container.layoutSubtreeIfNeeded()
        for def in layout.terminals where def.openOnRestore {
            openTerminal(def.id, isReopen: false, focus: false, runCommands: runCommands, startShell: !holdShells)
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

    private func makePane(_ def: TerminalDefinition, isReopen: Bool, runCommands: Bool) -> TerminalPane {
        let pane = TerminalPane(config: ConfigStore.shared.config,
                                definition: registry.effectiveDefinition(def.id) ?? def, isReopen: isReopen,
                                runCommands: runCommands)
        pane.controller = self
        pane.showsHeader = headersVisible
        pane.isBroadcasting = broadcastEnabled
        return pane
    }

    // MARK: Terminal lifecycle

    @discardableResult
    func openTerminal(_ id: String, isReopen: Bool, focus: Bool = true, runCommands: Bool = true,
                      startShell: Bool = true) -> TerminalPane? {
        guard let def = registry.definition(id), !registry.isOpen(id) else { return registry.pane(for: id) }
        let pane = makePane(def, isReopen: isReopen, runCommands: runCommands)
        let fraction = def.fractionalFrame ?? canvas.fraction(for: Arrange.nextSlot(in: canvas.bounds,
                                                                                    existing: canvas.occupiedFrames))
        canvas.add(pane, fraction: fraction)
        registry.attach(pane, to: id)
        pane.applyEnvironment()
        if startShell {
            pane.start()
        } else {
            pane.restoreOutput()
            heldPanes.append(pane)
        }
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
        if pane === activePane { refreshCopyTools() }
    }

    private func stateChanged() {
        updateWindowTitle()
        onStateChanged?(self)
        workspacePanel?.workspaceDidChange()
    }

    // MARK: Focus

    func setActivePane(_ pane: TerminalPane?) {
        guard let pane else {
            activePane?.isActive = false
            activePane = nil
            sidebar.activeID = nil
            sidebar.reloadAll()
            refreshCopyTools()
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
        refreshCopyTools()
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
        refreshCopyTools()
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
        if let workspaceName {
            window.subtitle = isWorkspaceModified ? "\(workspaceName) — Edited" : workspaceName
        } else {
            window.subtitle = isWorkspaceModified ? "Untitled — Edited" : "Untitled"
        }
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
        refreshCopyTools()
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
            refreshCopyTools()
            sidebar.refreshVisibleThumbnails(force: true)
        }
        stateChanged()
    }

    func thumbnailRenderCount(for id: String) -> Int { sidebar.renderCount(for: id) }
    func setSidebarWidthForTesting(_ width: CGFloat) {
        container.sidebarWidth = width
        onStateChanged?(self)
    }
    func describeSidebarRow(_ id: String) -> String { sidebar.describeRow(id) }
    func pressRunButtonForTesting(_ id: String) -> Bool { sidebar.pressRunButton(for: id) }

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

    /// Saves under a name without the sheet, for headless tests.
    func saveWorkspaceForTesting(named name: String) {
        var layout = snapshot()
        layout.workspaceName = name
        try? WorkspaceStore.save(Workspace(name: name, layout: layout))
        workspaceName = name
        markSaved()
        stateChanged()
    }

    /// Clears without the confirmation sheet, for headless tests.
    func newWorkspaceForTesting() {
        resetToEmptyWorkspace()
    }

    /// Sets the pointer for a point in *window* coordinates. Driven by the app's mouse-moved
    /// monitor, because a `.cursorUpdate` tracking area only fires on entering and leaving the
    /// area — it would set the pointer once at the window edge and then leave it stuck.
    func updateCursor(atWindowPoint point: NSPoint) {
        let local = container.convert(point, from: nil)
        // Outside the content view is the title bar and the window's own resize edges, where the
        // system owns the pointer.
        guard container.bounds.contains(local) else { return }
        container.cursor(at: local).set()
    }

    /// What the pointer would become at a point in window content coordinates, and which
    /// terminal owns that point. Used to test occlusion without moving the real cursor.
    func cursorDescription(at point: NSPoint) -> (cursor: String, pane: Int) {
        let cursor = container.cursor(at: point)
        let name: String
        switch cursor {
        case NSCursor.iBeam: name = "iBeam"
        case NSCursor.resizeLeftRight: name = "resizeLeftRight"
        case NSCursor.resizeUpDown: name = "resizeUpDown"
        case NSCursor.arrow: name = "arrow"
        default: name = "other"
        }
        var index = 0
        if let canvas = canvasView, canvasHostFrame.contains(point),
           let pane = canvas.topmostPane(at: canvas.convert(point, from: container)) {
            index = pane.index
        }
        return (name, index)
    }

    private var canvasView: PaneCanvasView? { canvas }
    private var canvasHostFrame: NSRect { canvas.frame }

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
        popover.onShowWorkspaceSettings = { [weak self] defID in
            self?.settingsPopover?.popover.close()
            self?.showWorkspaceSettings(selecting: defID)
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
            let refs = def.env.compactMap(\.secretRef)
            if let pane { self.canvas.remove(pane) }
            self.sidebar.forgetCache(for: id)
            self.registry.remove(id)
            self.renumber()
            self.updateEmptyState()
            self.sidebar.reloadAll()
            if self.activePane === pane { self.setActivePane(self.registry.livePanes.first) }
            self.stateChanged()
            SecretStore.discard(refs)
            // Deleted means gone: the output it kept goes with it. (Closing keeps it.)
            OutputSnapshot.discard(key: id)
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

    func sidebarDidRequestRunCommands(_ id: String) {
        runStartupCommands(for: id, askIfBusy: true)
    }

    func sidebarDidRequestRunAllCommands() {
        runAllStartupCommands()
    }

    // MARK: Startup commands on demand

    /// The commands a terminal runs when it opens. Its "run again on reopen" setting is not
    /// consulted: asking for them is the point.
    private func startupCommands(of id: String) -> [String] {
        registry.definition(id)?.commands(isReopen: false) ?? []
    }

    /// Terminals with startup commands, in list order.
    var terminalsWithStartupCommands: [String] {
        registry.order.filter { !startupCommands(of: $0).isEmpty }
    }

    /// Runs one terminal's startup commands now. A closed terminal is opened and runs them the
    /// way it would on a workspace open; an open one has them typed in at its prompt.
    func runStartupCommands(for id: String, askIfBusy: Bool, activate: Bool = true) {
        let commands = startupCommands(of: id)
        guard !commands.isEmpty else { NSSound.beep(); return }
        guard let pane = registry.pane(for: id) else {
            openTerminal(id, isReopen: false, focus: activate, runCommands: true)
            return
        }
        // Once is enough: a second click while the first run is still queued would type
        // everything twice.
        guard !pane.hasPendingCommands else { NSSound.beep(); return }
        let run = { [weak self, weak pane] in
            guard let self, let pane else { return }
            pane.runCommandsNow(commands)
            if activate { self.setActivePane(pane) }
            self.sidebar.reloadRow(id)
        }
        guard askIfBusy, pane.hasRunningJob, let window, !DebugDriver.isActive else { run(); return }
        let alert = NSAlert()
        alert.messageText = "“\(pane.displayTitle)” is running \(pane.foregroundJob ?? "a program")."
        alert.informativeText = "Its startup commands will run when that finishes."
        alert.addButton(withTitle: "Run When Finished")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { run() }
        }
    }

    /// Runs the startup commands of every terminal in the workspace, opening closed ones, after
    /// asking — they may start servers or deploys, and the button sits right beside New Terminal.
    func runAllStartupCommands() {
        let ids = terminalsWithStartupCommands
        guard !ids.isEmpty else { NSSound.beep(); return }
        let runAll = { [weak self] in
            guard let self else { return }
            for id in ids { self.runStartupCommands(for: id, askIfBusy: false, activate: false) }
        }
        guard let window, !DebugDriver.isActive else { runAll(); return }
        let closed = ids.filter { !registry.isOpen($0) }.count
        let busy = ids.compactMap { registry.pane(for: $0) }.filter(\.hasRunningJob).count
        let alert = NSAlert()
        alert.messageText = ids.count == 1
            ? "Run the startup commands of “\(registry.definition(ids[0])?.displayName ?? "this terminal")”?"
            : "Run the startup commands of all \(ids.count) terminals?"
        var notes: [String] = []
        if closed > 0 { notes.append(closed == 1 ? "1 closed terminal will be opened." : "\(closed) closed terminals will be opened.") }
        if busy > 0 { notes.append(busy == 1 ? "1 terminal is busy and will run them when its program finishes."
                                           : "\(busy) terminals are busy and will run them when their programs finish.") }
        alert.informativeText = notes.joined(separator: " ")
        alert.addButton(withTitle: "Run All")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { runAll() }
        }
    }

    /// Asks whether to run the startup commands held back while a workspace or session opened.
    ///
    /// Asked as a sheet on this window once it is on screen, never before: what is being
    /// opened should be visible — terminals, their restored output — while you decide. The
    /// commands themselves are not listed; the list shows which terminals have them, and each
    /// can still be run later from its row.
    ///
    /// The shells of `controllers` are held until the answer, then started with the commands or
    /// without, so Run Commands runs them from the shell exactly as an unasked open would.
    /// - Parameter controllers: every tab that opened with its commands held back. A restored
    ///   session asks once for all of them.
    func offerStartupCommands(for what: String, in controllers: [TerminalWindowController]) {
        let count = controllers.reduce(0) { $0 + $1.openTerminalsWithStartupCommands.count }
        // Whatever happens, the held shells must start; a question that cannot be asked means
        // nothing runs.
        let startAll = { (run: Bool) in for c in controllers { c.startHeldTerminals(runningCommands: run) } }
        guard count > 0 else { startAll(false); return }
        // A turn of the run loop, so the window is actually showing before a sheet slides out
        // of it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { startAll(false); return }
            let alert = NSAlert()
            alert.messageText = "Run the startup commands for \(what)?"
            alert.informativeText = (count == 1 ? "1 terminal has" : "\(count) terminals have")
                + " startup commands. Skipping leaves the terminals as they are; you can run the commands"
                + " later with the ▶ button beside a terminal in the list, or Run All below it."
            alert.addButton(withTitle: "Run Commands")
            alert.addButton(withTitle: "Skip").keyEquivalent = "\u{1b}"
            NSApp.activate(ignoringOtherApps: true)
            alert.beginSheetModal(for: window) { response in
                startAll(response == .alertFirstButtonReturn)
            }
        }
    }

    /// Open terminals whose startup commands were held back when the workspace opened.
    var openTerminalsWithStartupCommands: [String] {
        terminalsWithStartupCommands.filter { registry.isOpen($0) }
    }

    /// Starts the shells held back while the startup-commands question was open, with their
    /// commands or without.
    func startHeldTerminals(runningCommands run: Bool) {
        let held = heldPanes
        heldPanes = []
        for pane in held where registry.pane(for: pane.definitionID) === pane {
            pane.startupCommands = run ? startupCommands(of: pane.definitionID) : []
            pane.start()
        }
        activePane?.focusTerminal()
    }

    func sidebarDidSetEnvironment(_ environment: String?, for id: String) {
        setEnvironment(environment, for: id)
    }

    func sidebarDidRequestCopy(_ target: TerminalPane.CopyTarget) {
        let copied = performCopy(target)
        sidebar.confirmCopy(target, copied: copied)
        // A copy from the list must not steal focus from the terminal it copied out of.
        activePane?.focusTerminal()
    }

    func sidebarDidToggleAutoCopy() {
        ConfigStore.shared.update { $0.copy.autoCopyOnSelect.toggle() }
        refreshCopyTools()
        activePane?.focusTerminal()
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
            pane.applyTextLayout()
        }
        sidebar?.reloadRow(id)
    }

    func registry(_ registry: TerminalRegistry, didOpen id: String, pane: TerminalPane) {
        sidebar?.reloadRow(id)
    }

    func registry(_ registry: TerminalRegistry, didClose id: String) {
        sidebar?.reloadRow(id)
    }

    func registryDidChangeSettings(_ registry: TerminalRegistry) {
        for pane in registry.livePanes {
            pane.applyFont()
            pane.applyTextLayout()
        }
        sidebar?.reloadAll()
    }

    func registryBecameEmpty(_ registry: TerminalRegistry) {
        guard !isClosing else { return }
        isClosing = true
        window?.close()
    }

    // MARK: Tabs

    func addTab(layout: TabLayout, runStartupCommands: Bool = true, holdShells: Bool = false) -> TerminalWindowController {
        let controller = AppDelegate.shared.makeWindowController(layout: layout, frame: nil,
                                                                 workspaceName: layout.workspaceName,
                                                                 runStartupCommands: runStartupCommands,
                                                                 holdShells: holdShells)
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

    /// Records the current layout as the saved baseline.
    fileprivate func markSaved() {
        savedSignature = snapshot().modificationSignature()
        updateWindowTitle()
    }

    var isWorkspaceModified: Bool {
        snapshot().modificationSignature() != savedSignature
    }

    func snapshot(includeLiveState: Bool = false) -> TabLayout {
        for pane in registry.livePanes {
            registry.mutate(pane.definitionID) { def in
                def.fractionalFrame = pane.layoutFraction
                def.z = pane.zIndex
            }
        }
        var layout = registry.snapshot(selected: activePane?.definitionID, includeLiveState: includeLiveState)
        layout.workspaceName = workspaceName
        return layout
    }

    // MARK: Menu actions

    @objc func newTerminalAction(_ sender: Any?) { newTerminal() }
    @objc func runActiveStartupCommands(_ sender: Any?) {
        guard let id = activePane?.definitionID else { return }
        runStartupCommands(for: id, askIfBusy: true)
    }
    @objc func runAllStartupCommandsAction(_ sender: Any?) { runAllStartupCommands() }
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
    /// Opens this tab's Workspace Settings, on the focused terminal when there is one.
    @objc func showWorkspaceSettings(_ sender: Any?) {
        showWorkspaceSettings(selecting: activePane?.definitionID)
    }

    func showWorkspaceSettings(selecting id: String?) {
        let panel = workspacePanel ?? WorkspaceSettingsWindowController(controller: self)
        workspacePanel = panel
        panel.show(selecting: id)
    }

    /// The panel, for tests that drive it directly.
    var workspaceSettingsPanel: WorkspaceSettingsWindowController {
        let panel = workspacePanel ?? WorkspaceSettingsWindowController(controller: self)
        workspacePanel = panel
        return panel
    }

    /// The document the Workspace Settings panel edits, built from the live tab.
    var workspaceDocument: WorkspaceDocument {
        WorkspaceDocument(settings: registry.settings, definitions: registry.definitions)
    }

    /// Terminals `document` would delete, by display name, so the panel can say so first.
    func terminalsRemoved(by document: WorkspaceDocument) -> [String] {
        let kept = Set(document.terminals.map(\.id))
        return registry.definitions.filter { !kept.contains($0.id) }.map(\.displayName)
    }

    /// Makes the tab match `document`: updates each terminal's settings, adds the new ones and
    /// opens them, deletes the missing ones, and takes the document's order.
    ///
    /// Variables of an already running terminal reach its shell the next time it starts; a
    /// process's environment cannot be changed from outside.
    func apply(_ document: WorkspaceDocument) {
        let before = snapshot().secretRefs
        let existing = Set(registry.order)
        let definitions = document.definitions(merging: registry.definitions)
        let kept = Set(definitions.map(\.id))

        // Updating and adding come before deleting, so the registry is never momentarily empty
        // — that closes the window.
        var added: [String] = []
        for def in definitions {
            if existing.contains(def.id) {
                registry.update(def)
            } else {
                var fresh = def
                fresh.z = registry.maxZ + 1
                added.append(registry.insert(fresh))
            }
        }
        registry.settings = document.settings
        for id in registry.order where !kept.contains(id) {
            if let pane = registry.pane(for: id) { canvas.remove(pane) }
            sidebar.forgetCache(for: id)
            registry.remove(id)
        }
        registry.reorder(definitions.map(\.id))
        for id in added { openTerminal(id, isReopen: false, focus: false) }
        renumber()
        updateEmptyState()
        sidebar.reloadAll()
        if activePane.map({ registry.pane(for: $0.definitionID) == nil }) ?? true {
            setActivePane(registry.livePanes.first)
        }
        stateChanged()
        SecretStore.discard(before)
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
    @objc func clearScrollback(_ sender: Any?) {
        activePane?.clearScrollback()
        refreshCopyTools()
    }

    // MARK: Copy

    /// Runs one copy against the focused terminal. False means it found nothing to copy.
    @discardableResult
    func performCopy(_ target: TerminalPane.CopyTarget) -> Bool {
        guard let pane = activePane else { return false }
        let copied = pane.copy(target)
        refreshCopyTools()
        return copied
    }

    /// Re-reads what the focused terminal can copy right now and repaints the tools.
    func refreshCopyTools() {
        sidebar?.refreshCopyTools(for: activePane)
    }

    private func copyFromMenu(_ target: TerminalPane.CopyTarget) {
        let copied = performCopy(target)
        sidebar.confirmCopy(target, copied: copied)
    }

    @objc func copyLastCommandOutput(_ sender: Any?) { copyFromMenu(.lastCommandOutput) }
    @objc func copyWholeTerminal(_ sender: Any?) { copyFromMenu(.wholeTerminal) }
    @objc func copyLastCommand(_ sender: Any?) { copyFromMenu(.lastCommand) }
    @objc func toggleAutoCopyOnSelect(_ sender: Any?) { sidebarDidToggleAutoCopy() }
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

    /// Clears this tab back to a single empty terminal, offering to save first.
    @objc func newWorkspace(_ sender: Any?) {
        confirmTerminatingRunningJobs(closing: "workspace") { [weak self] in
            self?.confirmDiscardingChanges { [weak self] in self?.resetToEmptyWorkspace() }
        }
    }

    /// Runs `proceed` once the user agrees to terminate this tab's running processes. Runs it
    /// straight away when nothing is running or asking is turned off; Cancel drops it.
    private func confirmTerminatingRunningJobs(closing what: String, _ proceed: @escaping () -> Void) {
        let running = registry.livePanes.filter(\.hasRunningJob)
        guard ConfigStore.shared.config.confirmClosingRunningProcess, !running.isEmpty, let window else {
            proceed()
            return
        }
        let alert = NSAlert()
        alert.messageText = running.count == 1
            ? "Close \(what) running “\(running[0].foregroundJob ?? "process")”?"
            : "Close \(what) with \(running.count) running processes?"
        alert.informativeText = "Running processes will be terminated."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    /// Runs `proceed` once the user has dealt with any unsaved changes.
    private func confirmDiscardingChanges(_ proceed: @escaping () -> Void) {
        guard isWorkspaceModified, let window else { proceed(); return }
        let alert = NSAlert()
        let name = workspaceName ?? "this workspace"
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your terminals, their layout and their settings will be lost otherwise."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // Only continue once the save actually happened, so Cancel in the name sheet
                // does not silently discard the workspace anyway.
                self.performSave { saved in if saved { proceed() } }
            case .alertSecondButtonReturn:
                proceed()
            default:
                break
            }
        }
    }

    private func resetToEmptyWorkspace() {
        for id in registry.order {
            if let pane = registry.pane(for: id) {
                pane.terminate()
                canvas.remove(pane)
            }
            sidebar.forgetCache(for: id)
        }
        activePane = nil
        registry.load(TabLayout())
        workspaceName = nil
        let fresh = TerminalDefinition(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let id = registry.insert(fresh)
        renumber()
        openTerminal(id, isReopen: false)
        markSaved()
        stateChanged()
    }

    /// Saves to the current workspace, asking for a name the first time.
    @objc func saveWorkspace(_ sender: Any?) {
        performSave { _ in }
    }

    private func performSave(_ completion: @escaping (Bool) -> Void) {
        guard let name = workspaceName else {
            saveWorkspaceAs(nil, completion: completion)
            return
        }
        do {
            try WorkspaceStore.save(Workspace(name: name, layout: snapshot()))
            markSaved()
            completion(true)
        } catch {
            presentError(error)
            completion(false)
        }
    }

    @objc func saveWorkspaceAs(_ sender: Any?) {
        saveWorkspaceAs(sender, completion: { _ in })
    }

    private func saveWorkspaceAs(_ sender: Any?, completion: @escaping (Bool) -> Void) {
        guard let window else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Saves this tab's terminals, their folders and their startup commands to ~/.config/termsie/workspaces/."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        field.placeholderString = "workspace name"
        field.stringValue = workspaceName ?? ""
        accessory.addSubview(field)
        let check = NSButton(checkboxWithTitle: "Include commands currently running", target: nil, action: nil)
        check.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
        accessory.addSubview(check)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { completion(false); return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { completion(false); return }
            var layout = self.snapshot(includeLiveState: check.state == .on)
            layout.workspaceName = name
            do {
                try WorkspaceStore.save(Workspace(name: name, layout: layout))
                self.workspaceName = name
                self.markSaved()
                self.stateChanged()
                completion(true)
            } catch {
                self.presentError(error)
                completion(false)
            }
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
        case #selector(runActiveStartupCommands(_:)):
            return activePane.map { !startupCommands(of: $0.definitionID).isEmpty } ?? false
        case #selector(runAllStartupCommandsAction(_:)):
            return !terminalsWithStartupCommands.isEmpty
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
        case #selector(toggleAutoCopyOnSelect(_:)):
            item.state = ConfigStore.shared.config.copy.autoCopyOnSelect ? .on : .off
            return true
        case #selector(copyLastCommandOutput(_:)):
            return activePane?.canCopy(.lastCommandOutput) ?? false
        case #selector(copyLastCommand(_:)):
            return activePane?.canCopy(.lastCommand) ?? false
        case #selector(copyWholeTerminal(_:)):
            return activePane?.canCopy(.wholeTerminal) ?? false
        case #selector(increaseFontSize(_:)), #selector(decreaseFontSize(_:)), #selector(resetFontSize(_:)):
            return activePane != nil
        case #selector(closeActivePane(_:)), #selector(clearScrollback(_:)), #selector(showFind(_:)),
             #selector(renameActivePane(_:)), #selector(tilePaneLeft(_:)), #selector(tilePaneRight(_:)),
             #selector(tilePaneTop(_:)), #selector(tilePaneBottom(_:)), #selector(centerPane(_:)):
            return activePane != nil
        case #selector(duplicateTerminal(_:)), #selector(deleteTerminal(_:)), #selector(showTerminalSettings(_:)):
            return !registry.isEmpty
        case #selector(showWorkspaceSettings(_:)):
            return true
        case #selector(saveWorkspace(_:)):
            item.title = workspaceName.map { "Save Workspace “\($0)”" } ?? "Save Workspace…"
            return !registry.isEmpty
        case #selector(newWorkspace(_:)):
            return true
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard ConfigStore.shared.config.confirmClosingRunningProcess,
              registry.livePanes.contains(where: \.hasRunningJob) else { return true }
        confirmTerminatingRunningJobs(closing: "window") {
            self.isClosing = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        workspacePanel?.discardAndClose()
        for pane in registry.livePanes { pane.terminate() }
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        activePane?.focusTerminal()
        sidebar.kickTimer()
    }
}
