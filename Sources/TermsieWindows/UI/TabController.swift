import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// One tab: a list of saved terminals beside a canvas of floating ones. The Windows counterpart
/// of the macOS `TerminalWindowController`, with the same rules for what closing, deleting,
/// saving and restoring mean.
final class TabController: TerminalRegistryDelegate {
    enum Direction { case left, right, up, down }

    let registry = TerminalRegistry()
    let sidebar = Sidebar()
    weak var window: MainWindow?

    /// Terminals on the canvas in creation order; stacking is each pane's `zIndex`.
    private(set) var panes: [Pane] = []
    private var nextZ = 1
    private(set) weak var activePane: Pane?
    private(set) var broadcastEnabled = false
    private(set) var headersVisible: Bool
    private var isClosing = false
    private(set) var workspaceName: String?
    private var savedSignature = ""
    private var isInteracting = false
    private var deferredWork: [() -> Void] = []
    private var heldPanes: [Pane] = []
    private(set) var canvasSize: CGSize = .zero
    var emptyMessage: String?
    var workspaceSettings: WorkspaceSettingsWindow?

    var onStateChanged: ((TabController) -> Void)?

    init(layout: TabLayout?, workspaceName: String? = nil, runStartupCommands: Bool = true,
         holdShells: Bool = false, window: MainWindow, canvasSize: CGSize) {
        headersVisible = ConfigStore.shared.config.showPaneHeaders
        self.window = window
        self.canvasSize = canvasSize
        sidebar.tab = self
        registry.delegate = self
        let initial = layout ?? TabLayout.single()
        self.workspaceName = workspaceName ?? initial.workspaceName
        registry.load(initial)
        build(initial, runCommands: runStartupCommands, holdShells: holdShells)
        markSaved()
    }

    // MARK: Building

    private func build(_ layout: TabLayout, runCommands: Bool, holdShells: Bool) {
        for def in layout.terminals where def.openOnRestore {
            openTerminal(def.id, isReopen: false, focus: false, runCommands: runCommands, startShell: !holdShells)
        }
        renumber()
        updateEmptyState()
        if let selected = layout.selected, let pane = registry.pane(for: selected) {
            setActivePane(pane)
        } else {
            setActivePane(registry.livePanes.first)
        }
    }

    private func renumber() {
        for (i, id) in registry.order.enumerated() {
            registry.pane(for: id)?.index = i + 1
        }
    }

    private var dpi: Float { window?.dpi ?? 96 }

    private func makePane(_ def: TerminalDefinition, isReopen: Bool, runCommands: Bool) -> Pane {
        let pane = Pane(definition: registry.effectiveDefinition(def.id) ?? def, isReopen: isReopen,
                        runCommands: runCommands, dpi: dpi)
        pane.tab = self
        pane.showsHeader = headersVisible
        pane.isBroadcasting = broadcastEnabled
        return pane
    }

    // MARK: Terminal lifecycle

    @discardableResult
    func openTerminal(_ id: String, isReopen: Bool, focus: Bool = true, runCommands: Bool = true,
                      startShell: Bool = true) -> Pane? {
        guard let def = registry.definition(id), !registry.isOpen(id) else { return registry.pane(for: id) }
        let pane = makePane(def, isReopen: isReopen, runCommands: runCommands)
        let fraction = def.fractionalFrame ?? geometry.fraction(for: Arrange.nextSlot(in: canvasBounds,
                                                                                      existing: occupiedFrames))
        add(pane, fraction: fraction)
        registry.attach(pane, to: id)
        pane.applyAppearance()
        if startShell {
            pane.start()
        } else {
            pane.restoreOutput()
            heldPanes.append(pane)
        }
        renumber()
        updateEmptyState()
        if focus { setActivePane(pane) }
        stateChanged()
        return pane
    }

    @discardableResult
    func newTerminal(cwd: String? = nil, tileAfter: Bool = false) -> Pane? {
        let frame = Arrange.nextSlot(in: canvasBounds, existing: occupiedFrames)
        var def = TerminalDefinition(cwd: cwd ?? activePane?.currentDirectory.map { HomePath.abbreviate($0) },
                                     frame: geometry.fraction(for: frame))
        def.z = registry.maxZ + 1
        def.environment = activePane?.environmentID
        let id = registry.insert(def)
        let pane = openTerminal(id, isReopen: false)
        if tileAfter { tileGrid() }
        return pane
    }

    func closePane(_ pane: Pane, force: Bool = false) {
        guard !isClosing else { return }
        if isInteracting {
            deferredWork.append { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.closePane(pane, force: force)
            }
            return
        }
        if !force, ConfigStore.shared.config.confirmClosingRunningProcess, pane.hasRunningJob {
            guard Alert.confirm("Close terminal running “\(pane.foregroundJob ?? "process")”?",
                                "The process will be ended. Its saved settings are kept.", owner: window?.hwnd,
                                warning: true) else { return }
        }
        detach(pane)
    }

    /// Closing keeps the definition: the terminal stays in the list, ready to reopen.
    private func detach(_ pane: Pane) {
        let id = pane.definitionID
        commitFraction(for: pane)
        remove(pane)
        registry.detach(id)
        renumber()
        updateEmptyState()
        if activePane === pane { setActivePane(registry.livePanes.first) }
        if registry.openCount == 0, let window, !window.sidebarVisible { window.setSidebarVisible(true) }
        stateChanged()
    }

    func paneProcessExited(_ pane: Pane, exitCode: Int32?) {
        guard !isClosing else { return }
        if isInteracting {
            deferredWork.append { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.paneProcessExited(pane, exitCode: exitCode)
            }
            return
        }
        switch ConfigStore.shared.config.closePaneOnExit.lowercased() {
        case "always":
            detach(pane)
        case "never":
            pane.showExitMessage()
        default:
            if exitCode == 0 { detach(pane) } else { pane.showExitMessage() }
        }
        setNeedsDisplay()
    }

    private func updateEmptyState() {
        emptyMessage = registry.isEmpty
            ? "No terminals. Press Ctrl+Shift+D to add one."
            : "Click a terminal in the list to open it."
        setNeedsDisplay()
    }

    // MARK: Interaction guard

    func beginInteraction() { isInteracting = true }

    func endInteraction() {
        isInteracting = false
        let work = deferredWork
        deferredWork = []
        for item in work { item() }
    }

    func canvasGeometryChanged(_ pane: Pane?) {
        for p in pane.map({ [$0] }) ?? registry.livePanes {
            registry.setGeometry(p.definitionID, fraction: p.layoutFraction, z: p.zIndex)
        }
        stateChanged()
    }

    func paneProducedOutput(_ pane: Pane) {
        if pane === activePane { refreshCopyTools() }
        setNeedsDisplay()
    }

    func stateChanged() {
        updateWindowTitle()
        onStateChanged?(self)
        workspaceSettings?.workspaceDidChange()
        setNeedsDisplay()
    }

    func setNeedsDisplay() {
        guard let window, window.selectedTab === self else { return }
        window.setNeedsDisplay()
    }

    // MARK: Focus

    func setActivePane(_ pane: Pane?) {
        guard let pane else {
            activePane?.isActive = false
            activePane = nil
            refreshCopyTools()
            updateWindowTitle()
            setNeedsDisplay()
            return
        }
        if activePane !== pane {
            activePane?.isActive = false
            activePane = pane
            pane.isActive = true
        }
        raise(pane)
        if pane.findField == nil { pane.findHasFocus = false }
        refreshCopyTools()
        updateWindowTitle()
        setNeedsDisplay()
    }

    func focusFind(_ pane: Pane) {
        setActivePane(pane)
        pane.findHasFocus = true
        setNeedsDisplay()
    }

    func focusTerminal(_ pane: Pane) {
        pane.findHasFocus = false
        setNeedsDisplay()
    }

    func paneInfoChanged(_ pane: Pane) {
        if pane === activePane { updateWindowTitle() }
        setNeedsDisplay()
    }

    var title: String {
        guard let pane = activePane else { return workspaceName ?? AppInfo.name }
        return pane.displayTitle
    }

    func updateWindowTitle() {
        window?.tabTitleChanged(self)
    }

    /// The window title for this tab: terminal, folder, workspace and whether it is edited.
    var windowTitle: String {
        var title = AppInfo.name
        if let pane = activePane {
            title = pane.displayTitle
            if !pane.displayDirectory.isEmpty { title += " — " + pane.displayDirectory }
        }
        if broadcastEnabled { title = "⇶ " + title }
        let ws = workspaceName ?? "Untitled"
        title += " · " + ws + (isWorkspaceModified ? " (edited)" : "")
        return title
    }

    private func focusNeighbor(_ dir: Direction) {
        guard let active = activePane else { return }
        let others = registry.livePanes.filter { $0 !== active }
        let direction: CanvasGeometry.Direction
        switch dir {
        case .left: direction = .left
        case .right: direction = .right
        case .up: direction = .up
        case .down: direction = .down
        }
        if let i = CanvasGeometry.neighbor(of: active.frame, in: others.map(\.frame), direction: direction) {
            setActivePane(others[i])
        }
    }

    private func focusRelative(_ delta: Int) {
        let list = registry.livePanes
        guard let active = activePane, let idx = list.firstIndex(where: { $0 === active }), list.count > 1 else { return }
        setActivePane(list[(idx + delta + list.count) % list.count])
    }

    // MARK: Broadcast

    func broadcastTargets(from pane: Pane) -> [TerminalSession] {
        guard broadcastEnabled, pane === activePane else { return [] }
        return registry.livePanes.filter { $0 !== pane }.map(\.session)
    }

    // MARK: Config and fonts

    private func adjustFontSize(by delta: Double) {
        guard let id = activePane?.definitionID, let pane = registry.pane(for: id) else { return }
        let next = min(max(pane.effectiveFontSize + delta, TermsieConfig.minFontSize), TermsieConfig.maxFontSize)
        registry.mutate(id) { $0.fontSize = next }
    }

    func applyConfig() {
        headersVisible = ConfigStore.shared.config.showPaneHeaders
        for pane in registry.livePanes {
            pane.showsHeader = headersVisible
            pane.applyAppearance()
        }
        sidebar.dropAllCaches()
        refreshCopyTools()
        layoutForCanvasResize()
        setNeedsDisplay()
    }

    func dpiChanged(_ dpi: Float) {
        for pane in registry.livePanes { pane.applyAppearance(dpi: dpi) }
        sidebar.dropAllCaches()
    }

    // MARK: Sidebar requests

    func sidebarDidActivate(_ id: String) {
        if let pane = registry.pane(for: id) { setActivePane(pane) } else { openTerminal(id, isReopen: true) }
    }

    func sidebarDidRequestClose(_ id: String) {
        guard let pane = registry.pane(for: id) else { return }
        closePane(pane)
    }

    func sidebarDidRequestSettings(_ id: String) {
        guard let window else { return }
        TerminalSettingsDialog.show(definitionID: id, tab: self, owner: window.hwnd)
    }

    func sidebarDidRequestDuplicate(_ id: String) {
        guard let source = registry.definition(id) else { return }
        var copy = source
        copy.id = TerminalDefinition.newID()
        copy.name = (source.name ?? source.displayName) + " copy"
        copy.z = registry.maxZ + 1
        if let f = source.fractionalFrame {
            copy.fractionalFrame = CGRect(x: min(f.minX + 0.03, 0.9), y: min(f.minY + 0.03, 0.9),
                                          width: f.width, height: f.height)
        }
        // Duplicating copies the settings, never the secret values' references: a secret deleted
        // from one would otherwise vanish from the other.
        copy.openOnRestore = false
        let index = registry.index(of: id).map { $0 + 1 }
        registry.insert(copy, at: index)
        renumber()
        stateChanged()
    }

    func sidebarDidRequestDelete(_ id: String) {
        guard let def = registry.definition(id) else { return }
        let pane = registry.pane(for: id)
        if ConfigStore.shared.config.confirmClosingRunningProcess, pane?.hasRunningJob ?? false {
            guard Alert.confirm("Delete “\(def.displayName)”?",
                                "It is running \(pane?.foregroundJob ?? "a process"). Its saved settings will also be deleted.",
                                owner: window?.hwnd, warning: true) else { return }
        }
        let refs = def.env.compactMap(\.secretRef)
        if let pane { remove(pane) }
        sidebar.forget(id)
        registry.remove(id)
        renumber()
        updateEmptyState()
        if activePane === pane { setActivePane(registry.livePanes.first) }
        stateChanged()
        SecretStore.discard(refs)
        // Deleted means gone: the output it kept goes with it. Closing keeps it.
        OutputSnapshot.discard(key: id)
    }

    func sidebarDidReorder(_ id: String, to index: Int) {
        registry.move(id, to: index)
        renumber()
        stateChanged()
    }

    func setEnvironment(_ environment: String?, for id: String) {
        registry.mutate(id) { $0.environment = environment }
        sidebar.forget(id)
        stateChanged()
    }

    // MARK: Startup commands on demand

    private func startupCommands(of id: String) -> [String] {
        registry.definition(id)?.commands(isReopen: false) ?? []
    }

    var terminalsWithStartupCommands: [String] {
        registry.order.filter { !startupCommands(of: $0).isEmpty }
    }

    func hasStartupCommands(_ id: String) -> Bool { !startupCommands(of: id).isEmpty }

    func runStartupCommands(for id: String, askIfBusy: Bool, activate: Bool = true) {
        let commands = startupCommands(of: id)
        guard !commands.isEmpty else { Shell.beep(); return }
        guard let pane = registry.pane(for: id) else {
            openTerminal(id, isReopen: false, focus: activate, runCommands: true)
            return
        }
        guard !pane.hasPendingCommands else { Shell.beep(); return }
        if askIfBusy, pane.hasRunningJob, !DebugDriver.isActive {
            guard Alert.confirm("“\(pane.displayTitle)” is running \(pane.foregroundJob ?? "a program").",
                                "Its startup commands will run when that finishes.", owner: window?.hwnd) else { return }
        }
        pane.runCommandsNow(commands)
        if activate { setActivePane(pane) }
        setNeedsDisplay()
    }

    func runAllStartupCommands() {
        let ids = terminalsWithStartupCommands
        guard !ids.isEmpty else { Shell.beep(); return }
        if !DebugDriver.isActive {
            let closed = ids.filter { !registry.isOpen($0) }.count
            let busy = ids.compactMap { registry.pane(for: $0) }.filter(\.hasRunningJob).count
            let question = ids.count == 1
                ? "Run the startup commands of “\(registry.definition(ids[0])?.displayName ?? "this terminal")”?"
                : "Run the startup commands of all \(ids.count) terminals?"
            var notes: [String] = []
            if closed > 0 { notes.append(closed == 1 ? "1 closed terminal will be opened." : "\(closed) closed terminals will be opened.") }
            if busy > 0 {
                notes.append(busy == 1 ? "1 terminal is busy and will run them when its program finishes."
                                       : "\(busy) terminals are busy and will run them when their programs finish.")
            }
            guard Alert.confirm(question, notes.isEmpty ? question : notes.joined(separator: " "), owner: window?.hwnd) else { return }
        }
        for id in ids { runStartupCommands(for: id, askIfBusy: false, activate: false) }
    }

    var openTerminalsWithStartupCommands: [String] {
        terminalsWithStartupCommands.filter { registry.isOpen($0) }
    }

    /// Starts the shells held back while "run the startup commands?" was asked.
    func startHeldTerminals(runningCommands run: Bool) {
        let held = heldPanes
        heldPanes = []
        for pane in held where registry.pane(for: pane.definitionID) === pane {
            pane.startupCommands = run ? startupCommands(of: pane.definitionID) : []
            pane.start()
        }
        setNeedsDisplay()
    }

    // MARK: Copy

    @discardableResult
    func performCopy(_ target: CopyTarget) -> Bool {
        guard let pane = activePane else { return false }
        let copied = pane.copy(target, owner: window?.hwnd)
        sidebar.confirmCopy(target, copied: copied)
        if !copied { Shell.beep() }
        refreshCopyTools()
        return copied
    }

    func refreshCopyTools() {
        setNeedsDisplay()
    }

    func selectionWasAutoCopied() {
        sidebar.confirmCopy(.selection, copied: true)
    }

    func toggleAutoCopy() {
        ConfigStore.shared.update { $0.copy.autoCopyOnSelect.toggle() }
        refreshCopyTools()
    }

    // MARK: Registry delegate

    func registryDidChangeOrder(_ registry: TerminalRegistry) {
        setNeedsDisplay()
    }

    func registry(_ registry: TerminalRegistry, didChange id: String) {
        // The definition is the one source of truth for a terminal's name and look; mirroring it
        // onto the live pane keeps the header and the list from disagreeing.
        if let pane = registry.pane(for: id), let def = registry.definition(id) {
            if pane.customTitle != def.name { pane.customTitle = def.name }
            pane.applyAppearance()
        }
        sidebar.forget(id)
        setNeedsDisplay()
    }

    func registry(_ registry: TerminalRegistry, didOpen id: String, pane: Pane) { setNeedsDisplay() }
    func registry(_ registry: TerminalRegistry, didClose id: String) { setNeedsDisplay() }

    func registryDidChangeSettings(_ registry: TerminalRegistry) {
        for pane in registry.livePanes { pane.applyAppearance() }
        setNeedsDisplay()
    }

    func registryBecameEmpty(_ registry: TerminalRegistry) {
        guard !isClosing else { return }
        isClosing = true
        MainQueue.shared.async { [weak self] in
            guard let self else { return }
            self.window?.closeTab(self, force: true)
        }
    }

    // MARK: Serialization

    func markSaved() {
        savedSignature = snapshot().modificationSignature()
        updateWindowTitle()
    }

    var isWorkspaceModified: Bool {
        snapshot().modificationSignature() != savedSignature
    }

    func snapshot(includeLiveState: Bool = false) -> TabLayout {
        for pane in registry.livePanes {
            registry.setGeometry(pane.definitionID, fraction: pane.layoutFraction, z: pane.zIndex)
        }
        var layout = registry.snapshot(selected: activePane?.definitionID, includeLiveState: includeLiveState)
        layout.workspaceName = workspaceName
        return layout
    }

    // MARK: Workspace

    var workspaceDocument: WorkspaceDocument {
        WorkspaceDocument(settings: registry.settings, definitions: registry.definitions)
    }

    func terminalsRemoved(by document: WorkspaceDocument) -> [String] {
        let kept = Set(document.terminals.map(\.id))
        return registry.definitions.filter { !kept.contains($0.id) }.map(\.displayName)
    }

    /// Makes the tab match `document`: updates, adds and opens, deletes, and reorders.
    func apply(_ document: WorkspaceDocument) {
        let before = snapshot().secretRefs
        let existing = Set(registry.order)
        let definitions = document.definitions(merging: registry.definitions)
        let kept = Set(definitions.map(\.id))
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
            if let pane = registry.pane(for: id) { remove(pane) }
            sidebar.forget(id)
            registry.remove(id)
        }
        registry.reorder(definitions.map(\.id))
        for id in added { openTerminal(id, isReopen: false, focus: false) }
        renumber()
        updateEmptyState()
        if activePane.map({ registry.pane(for: $0.definitionID) == nil }) ?? true {
            setActivePane(registry.livePanes.first)
        }
        stateChanged()
        SecretStore.discard(before)
    }

    func showWorkspaceSettings(selecting id: String?) {
        guard let window else { return }
        let panel = workspaceSettings ?? WorkspaceSettingsWindow(tab: self, owner: window)
        workspaceSettings = panel
        panel.show(selecting: id)
    }

    /// Asks before ending running processes. True means go ahead.
    func confirmTerminatingRunningJobs(closing what: String) -> Bool {
        let running = registry.livePanes.filter(\.hasRunningJob)
        guard ConfigStore.shared.config.confirmClosingRunningProcess, !running.isEmpty, !DebugDriver.isActive else { return true }
        let question = running.count == 1
            ? "Close \(what) running “\(running[0].foregroundJob ?? "process")”?"
            : "Close \(what) with \(running.count) running processes?"
        return Alert.confirm(question, "Running processes will be ended.", owner: window?.hwnd, warning: true)
    }

    /// Asks about unsaved changes. True means carry on (saved or discarded).
    func confirmDiscardingChanges() -> Bool {
        guard isWorkspaceModified, !DebugDriver.isActive else { return true }
        let name = workspaceName ?? "this workspace"
        switch Alert.yesNoCancel("Save changes to \(name)?",
                                 "Your terminals, their layout and their settings will be lost otherwise.\n\nYes saves, No discards.",
                                 owner: window?.hwnd) {
        case .first: return performSave()
        case .second: return true
        case .third: return false
        }
    }

    func newWorkspace() {
        guard confirmTerminatingRunningJobs(closing: "workspace"), confirmDiscardingChanges() else { return }
        resetToEmptyWorkspace()
    }

    func resetToEmptyWorkspace() {
        for id in registry.order {
            if let pane = registry.pane(for: id) {
                pane.terminate()
                remove(pane)
            }
            sidebar.forget(id)
        }
        activePane = nil
        registry.load(TabLayout())
        workspaceName = nil
        let id = registry.insert(TerminalDefinition(frame: CGRect(x: 0, y: 0, width: 1, height: 1)))
        renumber()
        openTerminal(id, isReopen: false)
        markSaved()
        stateChanged()
    }

    @discardableResult
    func performSave() -> Bool {
        guard let name = workspaceName else { return saveWorkspaceAs() }
        do {
            try WorkspaceStore.save(Workspace(name: name, layout: snapshot()))
            markSaved()
            return true
        } catch {
            Alert.error("Could not save the workspace", "\(error.localizedDescription)", owner: window?.hwnd)
            return false
        }
    }

    @discardableResult
    func saveWorkspaceAs() -> Bool {
        guard let window,
              let answer = SaveWorkspaceDialog.run(owner: window.hwnd, name: workspaceName ?? "") else { return false }
        return saveWorkspace(named: answer.name, includeLiveState: answer.includeRunning)
    }

    @discardableResult
    func saveWorkspace(named name: String, includeLiveState: Bool = false) -> Bool {
        var layout = snapshot(includeLiveState: includeLiveState)
        layout.workspaceName = name
        do {
            try WorkspaceStore.save(Workspace(name: name, layout: layout))
            workspaceName = WorkspaceStore.fileSafeName(name)
            markSaved()
            stateChanged()
            return true
        } catch {
            Alert.error("Could not save the workspace", "\(error.localizedDescription)", owner: window?.hwnd)
            return false
        }
    }

    func renamePane(_ pane: Pane?) {
        guard let pane, let window else { return }
        guard let name = PromptDialog.run(owner: window.hwnd, title: "Terminal Name",
                                          message: "Leave empty to show the running program again.",
                                          initial: pane.customTitle ?? "") else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        registry.mutate(pane.definitionID) { $0.name = trimmed.isEmpty ? nil : trimmed }
        stateChanged()
    }

    // MARK: Canvas

    var canvasBounds: CGRect { CGRect(origin: .zero, size: canvasSize) }
    var geometry: CanvasGeometry { CanvasGeometry(bounds: canvasBounds) }
    var occupiedFrames: [CGRect] { panes.map(\.frame) }

    /// Panes back to front.
    var stackedPanes: [Pane] { panes.sorted { $0.zIndex < $1.zIndex } }

    func setCanvasSize(_ size: CGSize) {
        guard size != canvasSize else { return }
        canvasSize = size
        layoutForCanvasResize()
    }

    private func add(_ pane: Pane, fraction: CGRect) {
        pane.layoutFraction = CanvasGeometry.clampFraction(fraction)
        pane.zIndex = nextZ
        nextZ += 1
        panes.append(pane)
        applyFractions()
        setNeedsDisplay()
    }

    private func remove(_ pane: Pane) {
        panes.removeAll { $0 === pane }
        setNeedsDisplay()
    }

    func raise(_ pane: Pane) {
        guard stackedPanes.last !== pane else { return }
        pane.zIndex = nextZ
        nextZ += 1
        setNeedsDisplay()
    }

    func sendToBack(_ pane: Pane) {
        let lowest = panes.map(\.zIndex).min() ?? 0
        pane.zIndex = lowest - 1
        setNeedsDisplay()
    }

    /// Re-derives every frame from its fraction. Deliberately ignores the old size.
    func applyFractions() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let g = geometry
        for pane in panes {
            var r = g.rect(for: pane.layoutFraction)
            if pane.isCollapsed { r.size.height = pane.collapsedHeight }
            if pane.frame != r { pane.frame = r }
        }
        setNeedsDisplay()
    }

    func commitFraction(for pane: Pane) {
        var f = CanvasGeometry.clampFraction(geometry.fraction(for: pane.frame))
        if pane.isCollapsed { f.size.height = pane.layoutFraction.height }
        pane.layoutFraction = f
        canvasGeometryChanged(pane)
    }

    func setFraction(_ f: CGRect, for pane: Pane, commit: Bool = true) {
        pane.layoutFraction = CanvasGeometry.clampFraction(f)
        let r = geometry.rect(for: pane.layoutFraction)
        if pane.frame != r { pane.frame = r }
        if commit { canvasGeometryChanged(pane) }
        setNeedsDisplay()
    }

    private func layoutForCanvasResize() {
        if ConfigStore.shared.config.resizeTerminalsWithWindow {
            applyFractions()
        } else {
            guard canvasSize.width > 0, canvasSize.height > 0 else { return }
            let g = geometry
            for pane in panes {
                var r = g.keepingReachable(pane.frame)
                if pane.isCollapsed { r.size.height = pane.collapsedHeight }
                if pane.frame != r { pane.frame = r }
                var f = g.fraction(for: pane.frame)
                if pane.isCollapsed { f.size.height = pane.layoutFraction.height }
                pane.layoutFraction = CanvasGeometry.clampFraction(f)
            }
        }
    }

    func resolve(_ proposed: CGRect, for pane: Pane, zone: ChromeZone, snapping: Bool) -> CGRect {
        geometry.resolve(proposed, others: panes.filter { $0 !== pane }.map(\.frame), zone: zone, snapping: snapping)
    }

    func tileGrid() {
        let frames = Arrange.tileGrid(in: canvasBounds, count: panes.count)
        for (pane, frame) in zip(panes, frames) {
            pane.clearZoom()
            setFraction(geometry.fraction(for: frame), for: pane, commit: false)
        }
        canvasGeometryChanged(nil)
    }

    func cascade() {
        let frames = Arrange.cascade(in: canvasBounds, count: panes.count)
        for (pane, frame) in zip(panes, frames) {
            pane.clearZoom()
            setFraction(geometry.fraction(for: frame), for: pane, commit: false)
        }
        for pane in panes { raise(pane) }
        canvasGeometryChanged(nil)
    }

    func place(_ pane: Pane, _ half: Arrange.Half) {
        pane.clearZoom()
        setFraction(geometry.fraction(for: Arrange.half(half, in: canvasBounds)), for: pane)
        raise(pane)
    }

    /// The pane visible at a canvas point.
    func topmostPane(at p: CGPoint) -> Pane? {
        stackedPanes.reversed().first { $0.frame.contains(p) }
    }

    // MARK: Process polling

    func pollProcesses() {
        let open = registry.livePanes
        guard !open.isEmpty else { return }
        let snapshot = ProcessSnapshot()
        for pane in open { pane.refreshProcessInfo(snapshot) }
    }

    // MARK: Commands

    func canPerform(_ command: Command) -> Bool {
        switch command {
        case .runStartupCommands: return activePane.map { hasStartupCommands($0.definitionID) } ?? false
        case .runAllStartupCommands: return !terminalsWithStartupCommands.isEmpty
        case .focusLeft, .focusRight, .focusUp, .focusDown, .nextTerminal, .previousTerminal,
             .tileGrid, .cascade, .bringToFront, .sendToBack, .broadcast:
            return registry.openCount > 1
        case .copyLastCommandOutput: return activePane?.canCopy(.lastCommandOutput) ?? false
        case .copyLastCommand: return activePane?.canCopy(.lastCommand) ?? false
        case .copyWholeTerminal: return activePane?.canCopy(.wholeTerminal) ?? false
        case .copy: return activePane?.canCopy(.selection) ?? false
        case .closeTerminal, .clearScrollback, .find, .findNext, .findPrevious, .renameTerminal, .leftHalf,
             .rightHalf, .topHalf, .bottomHalf, .center, .maximize, .collapse, .biggerText, .smallerText,
             .defaultTextSize, .paste, .selectAll:
            return activePane != nil
        case .duplicateTerminal, .deleteTerminal, .terminalSettings, .saveWorkspace:
            return !registry.isEmpty
        case .terminal(let n): return n <= registry.count
        default: return true
        }
    }

    func isChecked(_ command: Command) -> Bool {
        switch command {
        case .toggleHeaders: return headersVisible
        case .broadcast: return broadcastEnabled
        case .toggleSidebar: return window?.sidebarVisible ?? true
        case .autoCopy: return ConfigStore.shared.config.copy.autoCopyOnSelect
        case .maximize: return activePane?.isZoomed ?? false
        case .collapse: return activePane?.isCollapsed ?? false
        case .environment(let id): return (activePane.flatMap { registry.definition($0.definitionID)?.environment } ?? "") == id
        default: return false
        }
    }

    /// Runs a command aimed at this tab. Returns false for commands the window handles.
    @discardableResult
    func perform(_ command: Command) -> Bool {
        let pane = activePane
        switch command {
        case .newTerminal: newTerminal()
        case .newTerminalTiled: newTerminal(tileAfter: true)
        case .duplicateTerminal: if let id = pane?.definitionID { sidebarDidRequestDuplicate(id) }
        case .terminalSettings:
            if let id = pane?.definitionID ?? registry.order.first { sidebarDidRequestSettings(id) }
        case .renameTerminal: renamePane(pane)
        case .clearScrollback: pane?.clearScrollback(); refreshCopyTools()
        case .runStartupCommands: if let id = pane?.definitionID { runStartupCommands(for: id, askIfBusy: true) }
        case .runAllStartupCommands: runAllStartupCommands()
        case .closeTerminal: if let pane { closePane(pane) }
        case .deleteTerminal: if let id = pane?.definitionID { sidebarDidRequestDelete(id) }
        case .copy: performCopy(.selection)
        case .paste: if let pane, let text = Clipboard.get(owner: window?.hwnd) { pane.session.paste(text) }
        case .selectAll: pane?.session.selection.selectAll(); setNeedsDisplay()
        case .copyLastCommandOutput: performCopy(.lastCommandOutput)
        case .copyLastCommand: performCopy(.lastCommand)
        case .copyWholeTerminal: performCopy(.wholeTerminal)
        case .autoCopy: toggleAutoCopy()
        case .find: pane?.showFindBar()
        case .findNext: pane?.findNext()
        case .findPrevious: pane?.findPrevious()
        case .maximize: pane?.toggleZoom(); canvasGeometryChanged(pane)
        case .collapse: pane?.toggleCollapsed()
        case .tileGrid: tileGrid()
        case .cascade: cascade()
        case .leftHalf: if let pane { place(pane, .left) }
        case .rightHalf: if let pane { place(pane, .right) }
        case .topHalf: if let pane { place(pane, .top) }
        case .bottomHalf: if let pane { place(pane, .bottom) }
        case .center: if let pane { place(pane, .center) }
        case .bringToFront: if let pane { raise(pane); canvasGeometryChanged(pane) }
        case .sendToBack: if let pane { sendToBack(pane); canvasGeometryChanged(pane) }
        case .toggleHeaders:
            headersVisible.toggle()
            for p in registry.livePanes { p.showsHeader = headersVisible }
            setNeedsDisplay()
        case .broadcast:
            broadcastEnabled.toggle()
            for p in registry.livePanes { p.isBroadcasting = broadcastEnabled }
            updateWindowTitle()
            setNeedsDisplay()
        case .focusLeft: focusNeighbor(.left)
        case .focusRight: focusNeighbor(.right)
        case .focusUp: focusNeighbor(.up)
        case .focusDown: focusNeighbor(.down)
        case .nextTerminal: focusRelative(1)
        case .previousTerminal: focusRelative(-1)
        case .terminal(let n):
            if let id = registry.id(at: n - 1) {
                if let p = registry.pane(for: id) { setActivePane(p) } else { openTerminal(id, isReopen: true) }
            }
        case .biggerText: adjustFontSize(by: 1)
        case .smallerText: adjustFontSize(by: -1)
        case .defaultTextSize:
            if let id = pane?.definitionID { registry.mutate(id) { $0.fontFamily = nil; $0.fontSize = nil } }
        case .newWorkspace: newWorkspace()
        case .workspaceSettings: showWorkspaceSettings(selecting: pane?.definitionID)
        case .saveWorkspace: performSave()
        case .saveWorkspaceAs: saveWorkspaceAs()
        case .environment(let id):
            if let pane { setEnvironment(id.isEmpty ? nil : id, for: pane.definitionID) }
        default:
            return false
        }
        return true
    }

    // MARK: Closing

    func terminateAll() {
        isClosing = true
        workspaceSettings?.discardAndClose()
        for pane in registry.livePanes { pane.terminate() }
    }
}
