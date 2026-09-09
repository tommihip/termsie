import AppKit
import SwiftTerm

/// One floating terminal: a header strip plus a SwiftTerm view running a local shell.
///
/// The pane owns its own window chrome — a border ring that is real dead space (not an overlay),
/// so its resize cursor rects never contend with SwiftTerm's I-beam.
final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    /// Identity shared with the sidebar row, the saved definition, and the shell history file.
    let definitionID: String
    let terminalView: TermsieTerminalView
    let header = PaneHeaderView()
    /// Holds the header and terminal, rounded and clipped. The shadow has to live on the outer
    /// view instead, because a layer cannot both clip its content and cast a shadow.
    private let content = NSView()
    weak var controller: TerminalWindowController?

    var customTitle: String? { didSet { refreshHeader() } }
    private(set) var oscTitle: String = ""
    private(set) var currentDirectory: String?
    private(set) var foregroundJob: String?
    private var jobObservedAt: CFTimeInterval = 0
    private(set) var exitCode: Int32?
    var initialDirectory: String?
    var startupCommands: [String] = []
    /// Set when the configured folder was missing and we fell back to home.
    private(set) var cwdWarning: String?

    // MARK: Canvas geometry

    /// Position on the canvas in unit space. The canvas derives pixel frames from this.
    var layoutFraction = NSRect(x: 0, y: 0, width: 1, height: 1)
    var zIndex = 0
    /// Set while maximized; holds the fraction to restore.
    private(set) var preZoomFraction: NSRect?
    var isZoomed: Bool { preZoomFraction != nil }
    private var isUserResizing = false

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                hasUnseenActivity = false
                hasUnseenBell = false
            }
            refreshAppearance()
        }
    }
    var showsHeader = true {
        didSet {
            header.isHidden = !showsHeader
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var index: Int = 0 { didSet { header.index = index } }
    var isBroadcasting = false { didSet { header.isBroadcasting = isBroadcasting } }

    var hasExited: Bool { terminalView.hasExited }
    /// Set whenever the visible buffer may have changed; consumed by the sidebar thumbnail.
    var thumbnailDirty = true

    private var hasUnseenActivity = false
    private var hasUnseenBell = false
    private var pollTimer: Timer?
    private var findBar: FindBarView?
    private var startedAt: CFTimeInterval = 0
    /// Redraws provoked by a resize are not news, so the activity badge ignores output until this
    /// time. Set whenever the character grid changes.
    private var ignoreActivityUntil: CFTimeInterval = 0
    private var pendingCommands: [String] = []
    private var pendingCommandWork: DispatchWorkItem?
    private var metalRequested = false
    private var shellName = "shell"
    private var integration = ShellIntegration.Plan.disabled

    // MARK: Init

    init(config: TermsieConfig, definition: TerminalDefinition, isReopen: Bool) {
        definitionID = definition.id
        let options = TerminalOptions(cursorStyle: config.terminalCursorStyle, scrollback: config.scrollback)
        terminalView = TermsieTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            font: config.resolvedFont(family: definition.fontFamily, size: definition.fontSize),
            options: options)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        initialDirectory = definition.cwd
        startupCommands = definition.commands(isReopen: isReopen)
        customTitle = definition.name
        shellName = (config.resolvedShell as NSString).lastPathComponent

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 12
        // The canvas positions panes explicitly; autoresizing would fight it.
        autoresizingMask = []

        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.autoresizingMask = []
        addSubview(content)

        header.pane = self
        content.addSubview(header)
        terminalView.processDelegate = self
        terminalView.autoresizingMask = []
        content.addSubview(terminalView)

        terminalView.onActivity = { [weak self] in self?.noteActivity() }
        terminalView.onBell = { [weak self] in self?.noteBell() }
        terminalView.onMouseDown = { [weak self] in self?.activate() }
        terminalView.onFocusChange = { [weak self] focused in
            guard let self, focused else { return }
            self.controller?.paneGainedFocus(self)
        }
        terminalView.onInputAfterExit = { [weak self] in
            guard let self else { return }
            self.controller?.closePane(self, force: true)
        }
        terminalView.broadcastTargets = { [weak self] in
            guard let self, let controller = self.controller else { return [] }
            return controller.broadcastTargets(from: self)
        }
        // Option-Command drag anywhere in the terminal moves the window, so hiding headers does
        // not strand a pane with no way to move it.
        terminalView.onChromeDrag = { [weak self] event in
            guard let self, event.modifierFlags.contains([.option, .command]) else { return false }
            self.beginTracking(event, zone: .move)
            return true
        }

        applyConfig(config)
        refreshHeader()
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        pollTimer?.invalidate()
        pendingCommandWork?.cancel()
    }

    // MARK: Process

    func start() {
        let config = ConfigStore.shared.config
        var env = ProcessInfo.processInfo.environment
        // A Termsie launched from inside a Termsie terminal would otherwise inherit that terminal's
        // shim variables and write into its history.
        for key in env.keys where key.hasPrefix("TERMSIE_") { env.removeValue(forKey: key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Termsie"
        env["TERM_PROGRAM_VERSION"] = AppInfo.version
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TERMSIE_PANE_ID"] = definitionID

        let wantsIsolation = controller?.registry.definition(definitionID)?.isolatedHistory ?? true
        integration = ShellIntegration.prepare(shell: config.resolvedShell,
                                               shellArgs: config.shellArgs,
                                               paneKey: historyKey,
                                               commands: startupCommands,
                                               isolateHistory: wantsIsolation,
                                               config: config,
                                               inheritedEnv: env)
        env.merge(integration.environment) { _, new in new }
        let envList = env.map { "\($0.key)=\($0.value)" }

        let resolved = Self.resolveDirectory(initialDirectory)
        cwdWarning = resolved.warning
        currentDirectory = resolved.path
        startedAt = CACurrentMediaTime()
        terminalView.startProcess(executable: config.resolvedShell, args: integration.shellArgs,
                                  environment: envList, execName: nil, currentDirectory: resolved.path)

        if let warning = resolved.warning {
            terminalView.feed(text: "\r\n\u{1b}[33m[\(warning)]\u{1b}[0m\r\n")
        }
        // When the shim runs the startup commands there is no timing heuristic at all; the typed
        // path is only the fallback for shells we cannot shim.
        if !integration.runsStartupCommands, !startupCommands.isEmpty {
            pendingCommands = startupCommands
            scheduleCommandFlush(after: 3.0)
        }
        startPolling()
        refreshHeader()
    }

    /// Expands and validates a configured folder. A missing one falls back to home *and says so*,
    /// rather than silently opening wherever the app happened to be launched from.
    static func resolveDirectory(_ dir: String?) -> (path: String?, warning: String?) {
        guard let dir, !dir.isEmpty else { return (nil, nil) }
        let expanded = (dir as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return (expanded, nil)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home, "working folder \(ProcessInspector.abbreviateHome(expanded)) not found — opened in ~")
    }

    /// The key naming this terminal's private history. Falls back to the definition id.
    var historyKey: String { definitionID }

    func terminate() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingCommandWork?.cancel()
        pendingCommandWork = nil
        pendingCommands = []
        if terminalView.process?.running == true {
            terminalView.terminate()
        }
    }

    var shellPid: pid_t { terminalView.process?.shellPid ?? 0 }

    /// True when something other than the shell itself is in the foreground (a server, editor, build…).
    var hasRunningJob: Bool {
        guard !hasExited, let job = foregroundJob else { return false }
        // Shell startup helpers briefly own the foreground; only count jobs that stick around.
        guard CACurrentMediaTime() - jobObservedAt > 1.0 else { return false }
        return job != shellName && job != "-" + shellName
    }

    /// What a live terminal is actually doing, offered to Save Workspace. Never written back
    /// into the definition automatically.
    struct LiveSnapshot {
        var title: String?
        var cwd: String?
        var runningCommand: String?
    }

    var liveSnapshot: LiveSnapshot {
        var command: String?
        if hasRunningJob, let fd = terminalView.process?.childfd,
           let pg = ProcessInspector.foregroundProcessGroup(ptyFd: fd) {
            command = ProcessInspector.commandLine(of: pg)
        }
        return LiveSnapshot(title: customTitle, cwd: currentDirectory, runningCommand: command)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshProcessInfo() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        refreshProcessInfo()
    }

    private func refreshProcessInfo() {
        guard let process = terminalView.process, process.running, window?.isVisible == true else { return }
        var changed = false
        if let cwd = ProcessInspector.currentDirectory(of: process.shellPid), cwd != currentDirectory {
            currentDirectory = cwd
            changed = true
        }
        var job: String? = nil
        if let pg = ProcessInspector.foregroundProcessGroup(ptyFd: process.childfd) {
            job = ProcessInspector.name(of: pg)
        }
        if job != foregroundJob {
            foregroundJob = job
            jobObservedAt = CACurrentMediaTime()
            changed = true
        }
        if changed { refreshHeader() }
    }

    // MARK: Appearance

    func applyConfig(_ config: TermsieConfig) {
        let colors = config.colors
        terminalView.nativeForegroundColor = NSColor.hex(colors.foreground)
        terminalView.caretColor = NSColor.hex(colors.cursor)
        terminalView.selectedTextBackgroundColor = NSColor.hex(colors.selection)
        terminalView.installColors(config.ansiColors)
        terminalView.optionAsMetaKey = config.optionAsMeta
        terminalView.bellStyle = config.terminalBellStyle
        showsHeader = config.showPaneHeaders
        header.showsTrafficLights = config.trafficLights
        applyFont()
        updateBackground()
        layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.backgroundColor = NSColor.clear.cgColor
        findBar?.applyColors()
        refreshAppearance()
        thumbnailDirty = true
        header.needsDisplay = true
    }

    /// The terminal's background before opacity, including any environment tint.
    var environmentBackground: NSColor {
        ConfigStore.shared.config.background(for: environmentID)
    }

    /// The environment this terminal belongs to, read from its saved definition.
    var environmentID: String? {
        controller?.registry.definition(definitionID)?.environment
    }

    /// Pushes the environment's tint into the terminal, its header, and its border.
    func applyEnvironment() {
        let config = ConfigStore.shared.config
        let style = config.environment(environmentID)
        header.environmentLabel = style?.tint == nil ? nil : style?.label
        header.environmentTint = style?.tint.flatMap { NSColor(hex: $0) }
        updateBackground()
        refreshAppearance()
        thumbnailDirty = true
        header.needsDisplay = true
    }

    func setFont(_ font: NSFont) {
        guard terminalView.font != font else { return }
        terminalView.font = font
        thumbnailDirty = true
    }

    /// Re-reads the font from this terminal's definition, so a change to either the global setting
    /// or this terminal's override lands in one place.
    func applyFont() {
        let config = ConfigStore.shared.config
        let def = controller?.registry.definition(definitionID)
        setFont(config.resolvedFont(family: def?.fontFamily, size: def?.fontSize))
    }

    /// The point size actually in use, whether inherited or overridden.
    var effectiveFontSize: Double {
        let def = controller?.registry.definition(definitionID)
        return def?.fontSize ?? ConfigStore.shared.config.font.size
    }

    /// Assigning an alpha-bearing background is how SwiftTerm expresses translucency: only the
    /// default background becomes transparent, so text and coloured cells stay solid.
    private func updateBackground() {
        let config = ConfigStore.shared.config
        let wanted = environmentBackground.withAlphaComponent(config.resolvedOpacity(active: isActive))
        guard terminalView.nativeBackgroundColor != wanted else { return }
        terminalView.nativeBackgroundColor = wanted
        thumbnailDirty = true
    }

    private func refreshAppearance() {
        updateBackground()
        let colors = ConfigStore.shared.config.colors
        // A hairline rather than the old 4pt ring: the active terminal is signalled mostly by its
        // shadow and header, so the border only has to whisper.
        let accent = header.environmentTint ?? NSColor.hex(colors.activeBorder)
        content.layer?.borderColor = isActive
            ? accent.withAlphaComponent(0.55).cgColor
            : NSColor(white: 1, alpha: 0.08).cgColor
        layer?.shadowOpacity = isActive ? 0.5 : 0.28
        header.isActive = isActive
        updateBadge()
    }

    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }
        if !oscTitle.isEmpty { return oscTitle }
        if let job = foregroundJob, !job.isEmpty { return job }
        return shellName
    }

    var displayDirectory: String {
        currentDirectory.map(ProcessInspector.abbreviateHome) ?? ""
    }

    func refreshHeader() {
        header.title = displayTitle
        header.subtitle = displayDirectory
        updateBadge()
        controller?.paneInfoChanged(self)
    }

    private func updateBadge() {
        if hasExited { header.badge = .exited(exitCode) }
        else if hasUnseenBell { header.badge = .bell }
        else if cwdWarning != nil { header.badge = .warning }
        else if hasUnseenActivity { header.badge = .activity }
        else { header.badge = .none }
    }

    // MARK: Startup commands (typed fallback)

    private func scheduleCommandFlush(after seconds: Double) {
        pendingCommandWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPendingCommand() }
        pendingCommandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Sends exactly one command, then re-arms. Sending them as one burst would feed later lines
    /// into the stdin of whatever the earlier one started.
    private func flushPendingCommand() {
        pendingCommandWork?.cancel()
        pendingCommandWork = nil
        guard !pendingCommands.isEmpty, !hasExited else { return }
        // Only type when the shell itself is in the foreground.
        if let fd = terminalView.process?.childfd,
           let pg = ProcessInspector.foregroundProcessGroup(ptyFd: fd),
           let name = ProcessInspector.name(of: pg),
           name != shellName, name != "-" + shellName {
            scheduleCommandFlush(after: 1.0)
            return
        }
        let cmd = pendingCommands.removeFirst()
        terminalView.send(txt: cmd + "\r")
        if !pendingCommands.isEmpty { scheduleCommandFlush(after: 1.0) }
    }

    private func noteActivity() {
        thumbnailDirty = true
        controller?.paneProducedOutput(self)
        if !pendingCommands.isEmpty {
            scheduleCommandFlush(after: Double(max(ConfigStore.shared.config.commandDelayMs, 0)) / 1000)
        }
        let now = CACurrentMediaTime()
        // The initial prompt is not "activity", and neither is a shell redrawing itself because
        // the window changed size.
        guard !isActive, !hasUnseenActivity, now - startedAt > 1.0, now >= ignoreActivityUntil else { return }
        hasUnseenActivity = true
        updateBadge()
    }

    private func noteBell() {
        guard !isActive else { return }
        hasUnseenBell = true
        updateBadge()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let b = PaneChrome.border
        let radius = CGFloat(ConfigStore.shared.config.cornerRadius)
        let contentFrame = bounds.insetBy(dx: b, dy: b)
        if content.frame != contentFrame { content.frame = contentFrame }
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous

        let inner = content.bounds
        let headerH = showsHeader ? PaneHeaderView.height : 0
        header.frame = NSRect(x: 0, y: inner.height - headerH, width: inner.width, height: headerH)
        let termFrame = NSRect(x: 0, y: 0, width: inner.width, height: max(0, inner.height - headerH))
        if terminalView.frame != termFrame { terminalView.frame = termFrame }
        if let bar = findBar {
            let w = min(FindBarView.width, max(60, termFrame.width - 16))
            bar.frame = NSRect(x: termFrame.maxX - w - 8, y: termFrame.maxY - FindBarView.height - 8,
                               width: w, height: FindBarView.height)
        }
        // Without an explicit path, Core Animation derives the shadow from the alpha channel every
        // frame, which over a Metal layer is a per-frame offscreen pass.
        layer?.shadowPath = CGPath(roundedRect: contentFrame, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil)
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !metalRequested, ConfigStore.shared.config.useMetal else { return }
        metalRequested = true
        do {
            try terminalView.setUseMetal(true)
        } catch {
            NSLog("Termsie: Metal renderer unavailable, using CoreGraphics (\(error))")
        }
    }

    // MARK: Chrome interaction

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let b = PaneChrome.border
        guard !isCollapsed, bounds.width > 2 * b, bounds.height > 2 * b else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - b, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - b, width: bounds.width, height: b), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        activate()
        let p = convert(event.locationInWindow, from: nil)
        if var zone = PaneChrome.zone(at: p, in: bounds) {
            if isCollapsed { zone = .move }
            beginTracking(event, zone: zone)
        }
    }

    /// Runs its own event loop so `.flagsChanged` arrives mid-drag (Command suppresses snapping)
    /// and all gesture state stays in local scope.
    func beginTracking(_ event: NSEvent, zone: ChromeZone) {
        guard let canvas = superview as? PaneCanvasView else { return }
        canvas.raise(self)
        let start = canvas.convert(event.locationInWindow, from: nil)
        let startFrame = frame
        var snapping = !event.modifierFlags.contains(.command)
        let cellSize = TerminalMetrics.cellSize(for: terminalView.font)
        let quantize = ConfigStore.shared.config.snapToCells && zone != .move

        beginResizeGesture(zone)
        controller?.beginInteraction()
        clearZoom()

        guard let window else { return }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged],
                           timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
            guard let ev else { stop.pointee = true; return }
            if ev.type == .flagsChanged {
                snapping = !ev.modifierFlags.contains(.command)
                return
            }
            let p = canvas.convert(ev.locationInWindow, from: nil)
            let delta = NSPoint(x: p.x - start.x, y: p.y - start.y)
            var proposed = PaneChrome.propose(startFrame, zone: zone, delta: delta)
            if quantize { proposed = self.quantizeToCells(proposed, zone: zone, cell: cellSize) }
            let resolved = canvas.resolve(proposed, for: self, zone: zone, snapping: snapping)
            if resolved.size == self.frame.size {
                // A pure move never touches setFrameSize, so the emulator does not reflow at all.
                if resolved.origin != self.frame.origin { self.setFrameOrigin(resolved.origin) }
            } else if resolved != self.frame {
                self.frame = resolved
            }
            if ev.type == .leftMouseUp { stop.pointee = true }
        }

        endResizeGesture(zone)
        canvas.commitFraction(for: self)
        controller?.endInteraction()
    }

    func beginResizeGesture(_ zone: ChromeZone) {
        guard zone != .move else { return }
        terminalView.viewWillStartLiveResize()
        isUserResizing = true
    }

    func endResizeGesture(_ zone: ChromeZone) {
        guard zone != .move else { return }
        terminalView.viewDidEndLiveResize()
        isUserResizing = false
        // sizeChanged only fires when the grid actually changes, so the final drag event normally
        // leaves the readout stranded on screen unless it is cleared unconditionally here.
        header.transientNote = nil
    }

    /// True while the cols × rows readout is on screen.
    var showsResizeReadout: Bool { header.transientNote != nil }

    /// Rounds the content box to whole cells so the emulator reflows only when the grid changes.
    private func quantizeToCells(_ r: NSRect, zone: ChromeZone, cell: CGSize) -> NSRect {
        guard cell.width >= 1, cell.height >= 1 else { return r }
        let b = PaneChrome.border
        let chromeW = 2 * b
        let chromeH = b + (showsHeader ? PaneHeaderView.height + b : PaneChrome.headlessGrip)
        let cols = max(1, ((r.width - chromeW) / cell.width).rounded())
        let rows = max(1, ((r.height - chromeH) / cell.height).rounded())
        var out = r
        out.size.width = max(PaneChrome.minSize.width, cols * cell.width + chromeW)
        out.size.height = max(PaneChrome.minSize.height, rows * cell.height + chromeH)
        // Keep the edge the user is not dragging pinned.
        if zone.resizesLeft { out.origin.x = r.maxX - out.width }
        if zone.resizesTop { out.origin.y = r.maxY - out.height }
        return out
    }

    // MARK: Zoom

    func toggleZoom() {
        guard let canvas = superview as? PaneCanvasView else { return }
        if let saved = preZoomFraction {
            preZoomFraction = nil
            canvas.setFraction(saved, for: self)
        } else {
            preZoomFraction = layoutFraction
            canvas.setFraction(NSRect(x: 0, y: 0, width: 1, height: 1), for: self)
        }
        canvas.raise(self)
        header.isZoomed = isZoomed
        header.needsDisplay = true
    }

    /// Rolled up to just its header, the way a classic window shade works.
    private(set) var isCollapsed = false

    var collapsedHeight: CGFloat { PaneHeaderView.height + 2 * PaneChrome.border }

    func toggleCollapsed() {
        guard let canvas = superview as? PaneCanvasView else { return }
        isCollapsed.toggle()
        if isCollapsed { clearZoom() }
        header.isCollapsed = isCollapsed
        // Collapsing never touches the stored fraction, so expanding restores the exact size.
        canvas.applyFractions()
        canvas.raise(self)
        controller?.paneInfoChanged(self)
    }

    func clearZoom() {
        guard preZoomFraction != nil else { return }
        preZoomFraction = nil
        header.isZoomed = false
        header.needsDisplay = true
    }

    // MARK: Focus

    func activate() {
        controller?.setActivePane(self)
    }

    func focusTerminal() {
        window?.makeFirstResponder(terminalView)
    }

    // MARK: Actions

    func clearScrollback() {
        terminalView.getTerminal().clearScrollback()
        if !hasExited { terminalView.send(txt: "\u{0C}") }
        thumbnailDirty = true
    }

    /// Types commands into an already-running shell, for "Apply now" in the settings editor.
    func runCommandsNow(_ commands: [String]) {
        guard !hasExited, !commands.isEmpty else { return }
        pendingCommands.append(contentsOf: commands)
        scheduleCommandFlush(after: 0.05)
    }

    func showFindBar() {
        if findBar == nil {
            let bar = FindBarView(frame: .zero)
            bar.terminalView = terminalView
            bar.onClose = { [weak self] in self?.hideFindBar() }
            content.addSubview(bar, positioned: .above, relativeTo: terminalView)
            findBar = bar
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        findBar?.focus()
    }

    func hideFindBar() {
        findBar?.removeFromSuperview()
        findBar = nil
        focusTerminal()
    }

    func findNext() { if findBar == nil { showFindBar() } else { findBar?.findNext() } }
    func findPrevious() { if findBar == nil { showFindBar() } else { findBar?.findPrevious() } }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        thumbnailDirty = true
        // A grid change sends SIGWINCH, and shells and full-screen programs answer it by
        // repainting. That output is a consequence of the resize, not something the user needs
        // flagged, so suppress the badge briefly. Each further change pushes the window out.
        ignoreActivityUntil = CACurrentMediaTime() + 0.9
        if isUserResizing { header.transientNote = "\(newCols) × \(newRows)" }
        else { header.transientNote = nil }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        oscTitle = title
        refreshHeader()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        var path = directory
        if let url = URL(string: directory), url.scheme == "file" { path = url.path }
        if path != currentDirectory {
            currentDirectory = path
            refreshHeader()
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // SwiftTerm on macOS passes the raw waitpid() status; decode it into a shell-style code.
        self.exitCode = exitCode.map { status in
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : 128 + signal
        }
        terminalView.hasExited = true
        pollTimer?.invalidate()
        pollTimer = nil
        foregroundJob = nil
        thumbnailDirty = true
        refreshHeader()
        controller?.paneProcessExited(self, exitCode: self.exitCode)
    }

    func showExitMessage() {
        let code = exitCode.map(String.init) ?? "?"
        terminalView.feed(text: "\r\n\u{1b}[90m[process exited with code \(code) — press any key to close]\u{1b}[0m\r\n")
    }
}

enum AppInfo {
    static let version = "0.2.0"
    static let name = "Termsie"
}
