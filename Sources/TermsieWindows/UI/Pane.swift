import Foundation
import WinSDK
import CTermsieWin
import SwiftTerm
import TermsieCore

/// The four things the copy tools put on the clipboard.
enum CopyTarget: String, CaseIterable {
    case selection
    case lastCommandOutput
    case wholeTerminal
    case lastCommand

    var title: String {
        switch self {
        case .selection: return "Copy Selection"
        case .lastCommandOutput: return "Copy Last Command Output"
        case .wholeTerminal: return "Copy Whole Terminal"
        case .lastCommand: return "Copy Last Command"
        }
    }

    var shortTitle: String {
        switch self {
        case .selection: return "Selection"
        case .lastCommandOutput: return "Last output"
        case .wholeTerminal: return "Everything"
        case .lastCommand: return "Last command"
        }
    }

    var detail: String {
        switch self {
        case .selection: return "Copies the highlighted text."
        case .lastCommandOutput:
            return "Copies the last command with its prompt and everything it printed, whether it has finished or is still running."
        case .wholeTerminal: return "Copies everything the terminal is holding, back to the last clear."
        case .lastCommand: return "Copies just the command line, without the prompt in front of it."
        }
    }
}

/// Where a point inside a floating terminal landed.
enum PaneHit: Equatable {
    case chrome(ChromeZone)
    case close, collapse, zoom
    case header
    case findBar
    case terminal
}

/// One floating terminal: its chrome, its header and its shell. The Windows counterpart of the
/// macOS `TerminalPane`; geometry is in canvas coordinates with y growing downward.
final class Pane {
    let definitionID: String
    let session: TerminalSession
    weak var tab: TabController?

    // MARK: Geometry

    var frame: CGRect = .zero {
        didSet { if frame.size != oldValue.size { layoutGrid() } }
    }
    var layoutFraction = CGRect(x: 0, y: 0, width: 1, height: 1)
    var zIndex = 0
    private(set) var preZoomFraction: CGRect?
    var isZoomed: Bool { preZoomFraction != nil }
    private(set) var isCollapsed = false
    var collapsedHeight: CGFloat { Theme.headerHeight + 2 * PaneChrome.border }
    var isUserResizing = false

    // MARK: State

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                hasUnseenActivity = false
                hasUnseenBell = false
            }
        }
    }
    var showsHeader = true { didSet { if showsHeader != oldValue { layoutGrid() } } }
    var index = 0
    var isBroadcasting = false
    var customTitle: String?
    private(set) var oscTitle = ""
    private(set) var currentDirectory: String?
    private(set) var foregroundJob: String?
    private(set) var foregroundPid: DWORD = 0
    private var jobObservedAt: Double = 0
    private(set) var exitCode: Int32?
    var initialDirectory: String?
    var startupCommands: [String] = []
    private(set) var cwdWarning: String?
    private(set) var hasUnseenActivity = false
    private(set) var hasUnseenBell = false
    private var ignoreActivityUntil: Double = 0
    private var pendingCommands: [String] = []
    private let commandFlush = Debouncer()
    private var shellHasSpoken = false
    private var outputSaved = false
    private var outputRestored = false
    private(set) var shellName = "shell"
    private var shellExecutable = ""
    private var integration = ShellIntegration.Plan.disabled
    /// The cols × rows readout shown while resizing.
    var transientNote: String?
    /// Set whenever the visible buffer may have changed; consumed by the list's thumbnail.
    var thumbnailDirty = true
    /// The first grid column shown, for a terminal that does not wrap.
    private(set) var firstColumn = 0

    // MARK: Appearance

    private(set) var fonts: TerminalFonts
    private(set) var palette: TerminalPalette
    private(set) var padding: CGFloat = 0
    private(set) var wrapsLines = true
    private var unwrappedColumns = 200
    private var dpi: Float

    // MARK: Find

    private(set) var findField: TextField?
    private(set) var matches: [TextMatch] = []
    private(set) var currentMatch: Int?
    var findHasFocus = false
    private let findRefresh = Debouncer()

    // MARK: Mouse

    private var selecting = false
    private var reportingButton: Int?
    private var lastMouseCell: (col: Int, row: Int)?

    init(definition: TerminalDefinition, isReopen: Bool, runCommands: Bool, dpi: Float) {
        let config = ConfigStore.shared.config
        definitionID = definition.id
        self.dpi = dpi
        let spec = config.resolvedFontSpec(family: definition.fontFamily, size: definition.fontSize)
        fonts = TerminalFonts(family: spec.family, size: spec.size, dpi: dpi)
        palette = TerminalPalette(config: config, background: config.backgroundRGBA(for: definition.environment))
        session = TerminalSession(cols: 80, rows: 24, config: config)
        initialDirectory = definition.cwd
        startupCommands = runCommands ? definition.commands(isReopen: isReopen) : []
        customTitle = definition.name
        shellExecutable = config.resolvedShell
        shellName = ShellKind.displayName(shellExecutable)
        padding = config.resolvedPadding(definition.padding)
        wrapsLines = config.resolvedLineWrap(definition.lineWrap)
        unwrappedColumns = config.resolvedUnwrappedColumns

        session.onOutput = { [weak self] in self?.outputArrived() }
        session.onActivity = { [weak self] in self?.noteActivity() }
        session.onBell = { [weak self] in self?.noteBell() }
        session.onNeedsDisplay = { [weak self] in self?.setNeedsDisplay() }
        session.onTitle = { [weak self] title in self?.titleChanged(title) }
        session.onDirectory = { [weak self] dir in self?.directoryChanged(dir) }
        session.onExit = { [weak self] code in self?.processTerminated(code) }
        session.onInputAfterExit = { [weak self] in
            guard let self else { return }
            self.tab?.closePane(self, force: true)
        }
        session.foregroundJobRunning = { [weak self] in self?.hasRunningJob ?? false }
        session.broadcastTargets = { [weak self] in
            guard let self, let tab = self.tab else { return [] }
            return tab.broadcastTargets(from: self)
        }
    }

    // MARK: Process

    func start() {
        let config = ConfigStore.shared.config
        var env = ProcessInfo.processInfo.environment
        // A Termsie started from inside a Termsie terminal would otherwise inherit that terminal's
        // shim variables and write into its history.
        for key in env.keys where key.uppercased().hasPrefix("TERMSIE_") { env.removeValue(forKey: key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Termsie"
        env["TERM_PROGRAM_VERSION"] = AppInfo.version
        let variables = tab?.registry.environmentVariables(for: definitionID) ?? (values: [:], missing: [])
        env.merge(variables.values) { _, new in new }
        env["TERMSIE_PANE_ID"] = definitionID

        let shell = config.resolvedShell
        shellExecutable = shell
        shellName = ShellKind.displayName(shell)
        let wantsIsolation = tab?.registry.definition(definitionID)?.isolatedHistory ?? true
        integration = ShellIntegration.prepare(shell: shell, shellArgs: config.shellArgs, paneKey: historyKey,
                                               commands: startupCommands, isolateHistory: wantsIsolation,
                                               config: config, inheritedEnv: env)
        env.merge(integration.environment) { _, new in new }
        if ShellKind.of(shell) == .wsl {
            // Windows variables reach a WSL shell only when WSLENV names them.
            let names = ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "TERMSIE_PANE_ID"] + variables.values.keys.sorted()
            let existing = EnvironmentBlock.value("WSLENV", in: env).map { $0.isEmpty ? [] : [$0] } ?? []
            env["WSLENV"] = (existing + names.map { "\($0)/u" }).joined(separator: ":")
        }

        let resolved = Pane.resolveDirectory(initialDirectory)
        cwdWarning = resolved.warning
        currentDirectory = resolved.path
        restoreOutput()
        do {
            try session.start(executable: shell, arguments: integration.shellArgs, environment: env,
                              directory: resolved.path ?? HomePath.home)
        } catch {
            Log.write("could not start \(shell): \(error)")
            session.feed(text: "\r\n\u{1b}[31m[\(error)]\u{1b}[0m\r\n"
                         + "\u{1b}[90m[set \"shell\" in config.json to the full path of the shell to use]\u{1b}[0m\r\n")
        }
        if let warning = resolved.warning {
            session.feed(text: "\r\n\u{1b}[33m[\(warning)]\u{1b}[0m\r\n")
        }
        if !variables.missing.isEmpty {
            let names = variables.missing.joined(separator: ", ")
            session.feed(text: "\r\n\u{1b}[33m[secret \(names) not found in the Credential Manager — not set]\u{1b}[0m\r\n")
        }
        // When the shell runs the startup commands itself there is no timing heuristic at all;
        // typing them is the fallback for shells that cannot be shimmed (cmd, WSL).
        if !integration.runsStartupCommands, !startupCommands.isEmpty {
            pendingCommands = startupCommands
            scheduleCommandFlush(after: 3.0)
        }
        tab?.paneInfoChanged(self)
    }

    /// Expands and checks a configured folder. A missing one falls back to home and says so.
    static func resolveDirectory(_ dir: String?) -> (path: String?, warning: String?) {
        guard let dir, !dir.isEmpty else { return (nil, nil) }
        let expanded = HomePath.expand(dir)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return (expanded, nil)
        }
        return (HomePath.home, "working folder \(HomePath.abbreviate(expanded)) not found — opened in ~")
    }

    var historyKey: String { definitionID }

    func terminate() {
        saveOutput()
        commandFlush.cancel()
        findRefresh.cancel()
        pendingCommands = []
        session.terminate()
    }

    var hasExited: Bool { session.hasExited }

    /// True when something other than the shell itself is in the foreground.
    var hasRunningJob: Bool {
        guard !hasExited, foregroundJob != nil else { return false }
        // Shell helpers briefly run below it (a prompt asking git for a branch); only count jobs
        // that stick around.
        return Clock.now - jobObservedAt > 1.0
    }

    struct LiveSnapshot {
        var title: String?
        var cwd: String?
        var runningCommand: String?
    }

    var liveSnapshot: LiveSnapshot {
        var command: String?
        if hasRunningJob, foregroundPid != 0 {
            command = ProcessInfoReader.commandLine(of: foregroundPid)
        }
        return LiveSnapshot(title: customTitle, cwd: currentDirectory, runningCommand: command)
    }

    /// Called by the tab's poll with one process list for all of its terminals.
    func refreshProcessInfo(_ snapshot: ProcessSnapshot) {
        guard session.isRunning else { return }
        let fg = snapshot.foreground(below: session.pid)
        var job = fg?.name
        if let j = job, j.lowercased().hasSuffix(".exe") { job = String(j.dropLast(4)) }
        if job != foregroundJob {
            foregroundJob = job
            foregroundPid = fg?.pid ?? 0
            jobObservedAt = Clock.now
            refreshHeader()
        }
    }

    private func titleChanged(_ title: String) {
        // Windows' console host announces the executable's path as the first title; that says
        // nothing the shell name does not.
        let lower = title.lowercased()
        if lower.hasSuffix(".exe") || lower == shellExecutable.lowercased() {
            oscTitle = ""
        } else {
            oscTitle = title
        }
        refreshHeader()
    }

    private func directoryChanged(_ dir: String) {
        guard dir != currentDirectory else { return }
        currentDirectory = dir
        refreshHeader()
    }

    private func processTerminated(_ code: Int32) {
        exitCode = code
        foregroundJob = nil
        foregroundPid = 0
        thumbnailDirty = true
        refreshHeader()
        tab?.paneProcessExited(self, exitCode: code)
    }

    func showExitMessage() {
        let code = exitCode.map(String.init) ?? "?"
        session.feed(text: "\r\n\u{1b}[90m[process exited with code \(code) — press any key to close]\u{1b}[0m\r\n")
    }

    // MARK: Output, activity, bell

    private func outputArrived() {
        thumbnailDirty = true
        shellHasSpoken = true
        if findField != nil { findRefresh.schedule(after: 0.3) { [weak self] in self?.recomputeMatches(keepCurrent: true) } }
        setNeedsDisplay()
    }

    private func noteActivity() {
        tab?.paneProducedOutput(self)
        if !pendingCommands.isEmpty {
            scheduleCommandFlush(after: Double(max(ConfigStore.shared.config.commandDelayMs, 0)) / 1000)
        }
        let now = Clock.now
        // The first prompt is not activity, and neither is a program redrawing after a resize.
        guard !isActive, !hasUnseenActivity, now - session.startedAt > 1.0, now >= ignoreActivityUntil else { return }
        hasUnseenActivity = true
        refreshHeader()
    }

    private func noteBell() {
        let style = ConfigStore.shared.config.bell.lowercased()
        if style == "sound" || style == "both" || style == "soundandvisual" { Shell.beep() }
        guard !isActive else { return }
        hasUnseenBell = true
        refreshHeader()
    }

    var badge: Badge {
        if hasExited { return .exited(exitCode) }
        if hasUnseenBell { return .bell }
        if cwdWarning != nil { return .warning }
        if hasUnseenActivity { return .activity }
        return .none
    }

    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }
        if !oscTitle.isEmpty { return oscTitle }
        if let job = foregroundJob, !job.isEmpty { return job }
        return shellName
    }

    var displayDirectory: String {
        currentDirectory.map { HomePath.abbreviate($0) } ?? ""
    }

    func refreshHeader() {
        tab?.paneInfoChanged(self)
        setNeedsDisplay()
    }

    func setNeedsDisplay() {
        tab?.setNeedsDisplay()
    }

    // MARK: Startup commands (typed fallback and on demand)

    private func scheduleCommandFlush(after seconds: Double) {
        commandFlush.schedule(after: seconds) { [weak self] in self?.flushPendingCommand() }
    }

    /// Types one command, then re-arms: typing them all at once would feed later lines into the
    /// input of whatever the first one started.
    private func flushPendingCommand() {
        guard !pendingCommands.isEmpty, !hasExited else { return }
        if foregroundJob != nil {
            scheduleCommandFlush(after: 1.0)
            return
        }
        let cmd = pendingCommands.removeFirst()
        session.send(user: Array((cmd + "\r").utf8))
        if !pendingCommands.isEmpty { scheduleCommandFlush(after: 1.0) }
    }

    func runCommandsNow(_ commands: [String]) {
        guard !hasExited, !commands.isEmpty else { return }
        pendingCommands.append(contentsOf: commands)
        scheduleCommandFlush(after: shellHasSpoken ? 0.05 : 3.0)
    }

    var hasPendingCommands: Bool { !pendingCommands.isEmpty }

    // MARK: Kept output

    private var keptOutputLines: Int {
        (tab?.registry.settings ?? WorkspaceSettings()).resolvedOutputLines(ConfigStore.shared.config)
    }

    func restoreOutput() {
        guard !outputRestored else { return }
        outputRestored = true
        guard keptOutputLines > 0, let replay = OutputSnapshot.replay(key: historyKey) else { return }
        session.feed(text: replay)
    }

    func saveOutput() {
        guard !outputSaved else { return }
        outputSaved = true
        let atPrompt = !hasExited && !session.markState.newestPromptOwnsACommand(liveJob: hasRunningJob)
        OutputSnapshot.save(session.terminal, key: historyKey, lines: keptOutputLines, atPrompt: atPrompt)
    }

    // MARK: Appearance

    var environmentID: String? {
        tab?.registry.definition(definitionID)?.environment
    }

    /// Re-reads font, padding, wrapping and colours from the effective definition and config.
    func applyAppearance(dpi newDpi: Float? = nil) {
        let config = ConfigStore.shared.config
        if let newDpi { dpi = newDpi }
        let def = tab?.registry.effectiveDefinition(definitionID)
        let spec = config.resolvedFontSpec(family: def?.fontFamily, size: def?.fontSize)
        if spec.family != fonts.regular.family || spec.size != fonts.regular.size || newDpi != nil {
            fonts = TerminalFonts(family: spec.family, size: spec.size, dpi: dpi)
        }
        palette = TerminalPalette(config: config, background: config.backgroundRGBA(for: def?.environment))
        session.terminal.installPalette(colors: config.ansiColors)
        padding = config.resolvedPadding(def?.padding)
        wrapsLines = config.resolvedLineWrap(def?.lineWrap)
        unwrappedColumns = config.resolvedUnwrappedColumns
        thumbnailDirty = true
        layoutGrid()
        setNeedsDisplay()
    }

    var effectiveFontSize: Double {
        tab?.registry.effectiveDefinition(definitionID)?.fontSize ?? ConfigStore.shared.config.font.size
    }

    var environmentStyle: TermsieConfig.EnvironmentStyle? {
        ConfigStore.shared.config.environment(environmentID)
    }

    var environmentTint: TWColor? {
        environmentStyle?.tint.flatMap { RGBA(hex: $0) }.map { TWColor($0) }
    }

    // MARK: Layout

    var contentRect: CGRect { frame.insetBy(dx: PaneChrome.border, dy: PaneChrome.border) }

    var headerRect: CGRect {
        let c = contentRect
        return CGRect(x: c.minX, y: c.minY, width: c.width, height: showsHeader ? Theme.headerHeight : PaneChrome.headlessGrip)
    }

    var terminalRect: CGRect {
        let c = contentRect
        let top = headerRect.maxY
        return CGRect(x: c.minX, y: top, width: c.width, height: max(0, c.maxY - top))
    }

    var textRect: CGRect {
        terminalRect.insetBy(dx: padding + 2, dy: padding + 1)
    }

    /// How many columns fit on screen; the grid is wider when the terminal does not wrap.
    var visibleColumns: Int {
        max(1, Int(textRect.width / fonts.metrics.cellWidth))
    }

    func layoutGrid() {
        guard frame.width > 0, frame.height > 0, !isCollapsed else { return }
        let m = fonts.metrics
        let rows = max(1, Int(textRect.height / m.cellHeight))
        let cols = wrapsLines ? max(2, Int(textRect.width / m.cellWidth)) : unwrappedColumns
        let before = (session.terminal.cols, session.terminal.rows)
        session.resize(cols: cols, rows: rows)
        if before != (session.terminal.cols, session.terminal.rows) {
            thumbnailDirty = true
            // A program answers a resize by redrawing, which is not news worth a badge.
            ignoreActivityUntil = Clock.now + 0.9
            transientNote = isUserResizing ? "\(session.terminal.cols) × \(session.terminal.rows)" : nil
        }
        clampColumns()
    }

    private func clampColumns() {
        if wrapsLines { firstColumn = 0; return }
        firstColumn = min(max(firstColumn, 0), max(0, session.terminal.cols - visibleColumns))
    }

    /// Slides an unwrapped terminal sideways so the cursor's column is on screen.
    func revealCursorColumn() {
        guard !wrapsLines else { return }
        let x = session.terminal.getCursorLocation().x
        if x < firstColumn { firstColumn = x }
        else if x >= firstColumn + visibleColumns { firstColumn = x - visibleColumns + 1 }
        clampColumns()
    }

    /// Rounds a proposed frame so the text area holds whole cells.
    func quantizeToCells(_ r: CGRect, zone: ChromeZone) -> CGRect {
        let cell = fonts.metrics
        guard cell.cellWidth >= 1, cell.cellHeight >= 1 else { return r }
        let b = PaneChrome.border
        let pad = padding
        let chromeW = 2 * b + 2 * (pad + 2)
        let chromeH = 2 * b + 2 * (pad + 1) + (showsHeader ? Theme.headerHeight : PaneChrome.headlessGrip)
        var out = r
        if wrapsLines {
            let cols = max(1, ((r.width - chromeW) / cell.cellWidth).rounded())
            out.size.width = max(PaneChrome.minSize.width, cols * cell.cellWidth + chromeW)
        }
        let rows = max(1, ((r.height - chromeH) / cell.cellHeight).rounded())
        out.size.height = max(PaneChrome.minSize.height, rows * cell.cellHeight + chromeH)
        if zone.resizesLeft { out.origin.x = r.maxX - out.width }
        if zone.resizesTop { out.origin.y = r.maxY - out.height }
        return out
    }

    // MARK: Zoom and collapse

    func toggleZoom() {
        guard let tab else { return }
        if let saved = preZoomFraction {
            preZoomFraction = nil
            tab.setFraction(saved, for: self)
        } else {
            preZoomFraction = layoutFraction
            tab.setFraction(CGRect(x: 0, y: 0, width: 1, height: 1), for: self)
        }
        tab.raise(self)
    }

    func clearZoom() {
        preZoomFraction = nil
    }

    func toggleCollapsed() {
        guard let tab else { return }
        isCollapsed.toggle()
        if isCollapsed { clearZoom() }
        tab.applyFractions()
        tab.raise(self)
        if !isCollapsed { layoutGrid() }
        tab.paneInfoChanged(self)
    }

    // MARK: Hit testing

    var trafficRects: (close: CGRect, collapse: CGRect, zoom: CGRect) {
        let h = headerRect
        let d = Theme.trafficDiameter
        let y = h.midY - d / 2
        let x0 = h.minX + 10
        return (CGRect(x: x0, y: y, width: d, height: d),
                CGRect(x: x0 + d + Theme.trafficSpacing, y: y, width: d, height: d),
                CGRect(x: x0 + 2 * (d + Theme.trafficSpacing), y: y, width: d, height: d))
    }

    var findBarRect: CGRect? {
        guard findField != nil else { return nil }
        let t = terminalRect
        let w = min(Theme.findBarWidth, max(60, t.width - 16))
        return CGRect(x: t.maxX - w - 8, y: t.minY + 8, width: w, height: Theme.findBarHeight)
    }

    func hit(_ p: CGPoint) -> PaneHit? {
        guard frame.contains(p) else { return nil }
        if var zone = PaneChrome.zone(at: p, in: frame, flipped: true) {
            if isCollapsed { zone = .move }
            return .chrome(zone)
        }
        let h = headerRect
        if h.contains(p) {
            if showsHeader, ConfigStore.shared.config.trafficLights {
                let t = trafficRects
                if t.close.insetBy(dx: -3, dy: -4).contains(p) { return .close }
                if t.collapse.insetBy(dx: -3, dy: -4).contains(p) { return .collapse }
                if t.zoom.insetBy(dx: -3, dy: -4).contains(p) { return .zoom }
            }
            return showsHeader ? .header : .chrome(.move)
        }
        if isCollapsed { return .chrome(.move) }
        if let bar = findBarRect, bar.contains(p) { return .findBar }
        return .terminal
    }

    func cursor(at p: CGPoint) -> CursorShape {
        switch hit(p) {
        case .chrome(let zone): return zone.cursorShape
        case .terminal:
            if session.terminal.mouseMode != .off && !Keys.shift { return .arrow }
            return .ibeam
        case .findBar: return .ibeam
        case .close, .collapse, .zoom: return .hand
        case .header, .none: return .arrow
        }
    }

    /// The grid cell under a canvas point, clamped to the screen.
    func cell(at p: CGPoint) -> (col: Int, row: Int) {
        let t = textRect
        let m = fonts.metrics
        let col = Int(((p.x - t.minX) / m.cellWidth).rounded(.down)) + firstColumn
        let row = Int(((p.y - t.minY) / m.cellHeight).rounded(.down))
        return (min(max(col, 0), session.terminal.cols), min(max(row, 0), session.terminal.rows - 1))
    }

    // MARK: Terminal mouse

    private var reportsMouse: Bool {
        session.terminal.mouseMode != .off && !Keys.shift
    }

    private func buttonFlags(_ button: Int, release: Bool) -> Int {
        session.terminal.encodeButton(button: button, release: release, shift: Keys.shift, meta: Keys.alt,
                                      control: Keys.control)
    }

    func mouseDown(at p: CGPoint, button: Int, clickCount: Int) {
        let c = cell(at: p)
        if reportsMouse {
            let mode = session.terminal.mouseMode
            if mode != .x10 || button == 0 {
                session.terminal.sendEvent(buttonFlags: buttonFlags(button, release: false), x: c.col, y: c.row)
            }
            reportingButton = button
            lastMouseCell = c
            return
        }
        guard button == 0 else { return }
        let position = session.bufferPosition(col: c.col, row: c.row)
        let sel = session.selection!
        switch clickCount {
        case 2:
            sel.selectWordOrExpression(at: position, in: session.terminal.buffer)
        case 3...:
            sel.select(row: position.row)
        default:
            if Keys.shift && sel.active {
                sel.shiftExtend(bufferPosition: position)
            } else {
                sel.selectNone()
                sel.setSoftStart(bufferPosition: position)
            }
        }
        selecting = true
        setNeedsDisplay()
    }

    func mouseDragged(to p: CGPoint) {
        let c = cell(at: p)
        if let button = reportingButton {
            let mode = session.terminal.mouseMode
            if mode == .buttonEventTracking || mode == .anyEvent, lastMouseCell.map({ $0 != c }) ?? true {
                session.terminal.sendMotion(buttonFlags: buttonFlags(button, release: false), x: c.col, y: c.row,
                                            pixelX: c.col, pixelY: c.row)
            }
            lastMouseCell = c
            return
        }
        guard selecting else { return }
        // Dragging past the top or bottom scrolls the selection along.
        let t = textRect
        if p.y < t.minY { session.scroll(by: -1) }
        else if p.y > t.maxY { session.scroll(by: 1) }
        session.selection.dragExtend(bufferPosition: session.bufferPosition(col: c.col, row: c.row))
        setNeedsDisplay()
    }

    func mouseUp(at p: CGPoint, owner: HWND?) {
        if let button = reportingButton {
            let c = cell(at: p)
            if session.terminal.mouseMode != .x10 {
                session.terminal.sendEvent(buttonFlags: buttonFlags(button, release: true), x: c.col, y: c.row)
            }
            reportingButton = nil
            return
        }
        guard selecting else { return }
        selecting = false
        if session.autoCopySelection(owner: owner) { tab?.selectionWasAutoCopied() }
        tab?.refreshCopyTools()
    }

    func mouseMoved(to p: CGPoint) {
        guard session.terminal.mouseMode == .anyEvent, !Keys.shift, frame.contains(p), hit(p) == .terminal else { return }
        let c = cell(at: p)
        guard lastMouseCell.map({ $0 != c }) ?? true else { return }
        lastMouseCell = c
        session.terminal.sendMotion(buttonFlags: 3, x: c.col, y: c.row, pixelX: c.col, pixelY: c.row)
    }

    /// Scrolls the scrollback, reports the wheel to a program that asked for mouse events, or
    /// turns it into arrow keys on the alternate screen, as xterm does.
    func wheel(lines: Int, at p: CGPoint) {
        guard lines != 0 else { return }
        let terminal = session.terminal!
        if reportsMouse {
            let c = cell(at: p)
            let button = lines < 0 ? 4 : 5
            for _ in 0..<min(abs(lines), 5) {
                terminal.sendEvent(buttonFlags: buttonFlags(button, release: false), x: c.col, y: c.row)
            }
            return
        }
        if terminal.isCurrentBufferAlternate {
            if terminal.alternateScrollMode {
                let key: [UInt8] = lines < 0 ? [0x1b, terminal.applicationCursor ? 0x4f : 0x5b, 0x41]
                                             : [0x1b, terminal.applicationCursor ? 0x4f : 0x5b, 0x42]
                for _ in 0..<abs(lines) { session.send(user: key) }
            }
            return
        }
        session.scroll(by: lines)
    }

    func horizontalWheel(columns: Int) {
        guard !wrapsLines else { return }
        firstColumn += columns
        clampColumns()
        thumbnailDirty = true
        setNeedsDisplay()
    }

    // MARK: Find

    func showFindBar() {
        if findField == nil {
            let field = TextField()
            field.placeholder = "Find"
            field.onChange = { [weak self] _ in self?.recomputeMatches(keepCurrent: false) }
            field.onSubmit = { [weak self] backwards in self?.stepMatch(backwards ? -1 : 1) }
            field.onCancel = { [weak self] in self?.hideFindBar() }
            findField = field
        }
        findField?.selectAll()
        findHasFocus = true
        tab?.focusFind(self)
        setNeedsDisplay()
    }

    func hideFindBar() {
        findField = nil
        matches = []
        currentMatch = nil
        findHasFocus = false
        tab?.focusTerminal(self)
        setNeedsDisplay()
    }

    func findNext() { if findField == nil { showFindBar() } else { stepMatch(1) } }
    func findPrevious() { if findField == nil { showFindBar() } else { stepMatch(-1) } }

    private func recomputeMatches(keepCurrent: Bool) {
        let query = findField?.text ?? ""
        let previous = currentMatch.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        matches = []
        currentMatch = nil
        guard !query.isEmpty else { setNeedsDisplay(); return }
        let terminal = session.terminal!
        let capture = TerminalTextCapture(terminal)
        let needle = query.lowercased()
        let count = capture.rowCount
        for row in 0..<count {
            guard let line = capture.line(at: row) else { continue }
            let text = line.translateToString(trimRight: true).lowercased()
            guard text.contains(needle) else { continue }
            // Columns, not string offsets: count characters up to each hit.
            var searchStart = text.startIndex
            while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = start + query.count
                matches.append(TextMatch(line: row, start: start, end: end))
                searchStart = range.upperBound
            }
        }
        if keepCurrent, let previous, let i = matches.firstIndex(of: previous) {
            currentMatch = i
        } else if !matches.isEmpty {
            // The newest match: the bottom of the terminal is where people look.
            currentMatch = matches.count - 1
            revealMatch()
        }
        setNeedsDisplay()
    }

    private func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else { Shell.beep(); return }
        let i = currentMatch ?? (delta > 0 ? -1 : matches.count)
        currentMatch = ((i + delta) % matches.count + matches.count) % matches.count
        revealMatch()
        setNeedsDisplay()
    }

    private func revealMatch() {
        guard let i = currentMatch, matches.indices.contains(i) else { return }
        let line = matches[i].line
        let top = session.viewTopLine
        let rows = session.terminal.rows
        if line < top || line >= top + rows {
            session.scroll(toLine: max(0, line - rows / 2))
        }
    }

    var findStatus: String {
        guard let field = findField, !field.text.isEmpty else { return "" }
        if matches.isEmpty { return "no matches" }
        return "\((currentMatch ?? 0) + 1) of \(matches.count)"
    }

    // MARK: Copy

    func canCopy(_ target: CopyTarget) -> Bool {
        let a = session.copyAvailability
        switch target {
        case .selection: return a.selection
        case .lastCommandOutput: return a.lastCommandOutput
        case .wholeTerminal: return a.everything
        case .lastCommand: return a.lastCommand
        }
    }

    @discardableResult
    func copy(_ target: CopyTarget, owner: HWND?) -> Bool {
        let text: String?
        switch target {
        case .selection: text = session.selectedText
        case .lastCommandOutput: text = session.lastCommandBlockText()
        case .wholeTerminal: text = session.wholeTerminalText()
        case .lastCommand: text = session.lastCommandText()
        }
        guard let text, !text.isEmpty else { return false }
        Clipboard.set(text, owner: owner)
        return true
    }

    func clearScrollback() {
        session.clearScrollback()
        thumbnailDirty = true
    }

    // MARK: Drawing

    func draw(renderer: Renderer, origin: CGPoint, focused: Bool, caretOn: Bool) {
        let config = ConfigStore.shared.config
        let c = config.colors
        let f = frame.offsetBy(dx: origin.x, dy: origin.y)
        let content = f.insetBy(dx: PaneChrome.border, dy: PaneChrome.border)
        let radius = CGFloat(config.cornerRadius)

        renderer.shadow(content, radius: radius, spread: isActive ? 12 : 8, opacity: isActive ? 0.5 : 0.28)

        renderer.clippedRounded(content, radius: radius) {
            // Background: the environment-tinted colour at the window's opacity. With no backdrop
            // to show through, it is drawn opaque.
            let opacity = App.shared.backdropActive ? Double(config.resolvedOpacity(active: isActive)) : 1
            renderer.fill(content, TWColor(palette.background, alpha: opacity))
            drawHeader(renderer: renderer, rect: headerRect.offsetBy(dx: origin.x, dy: origin.y))
            guard !isCollapsed else { return }
            let text = textRect.offsetBy(dx: origin.x, dy: origin.y)
            let options = TerminalPainter.Options(
                focused: focused && isActive && !findHasFocus, cursorPhaseOn: caretOn, firstColumn: firstColumn,
                matches: matches, currentMatch: currentMatch.flatMap { matches.indices.contains($0) ? matches[$0] : nil })
            TerminalPainter.draw(session, in: text, renderer: renderer, fonts: fonts, palette: palette, options: options)
            drawScrollIndicator(renderer: renderer, terminal: terminalRect.offsetBy(dx: origin.x, dy: origin.y))
            if let bar = findBarRect, let field = findField {
                drawFindBar(renderer: renderer, rect: bar.offsetBy(dx: origin.x, dy: origin.y), field: field,
                            caretOn: caretOn, focused: focused)
            }
        }

        // A hairline rather than a heavy ring: the active terminal shows mostly through its shadow
        // and header, so the border only has to whisper.
        let accent = environmentTint ?? Theme.color(c.activeBorder)
        renderer.strokeRounded(content.insetBy(dx: 0.5, dy: 0.5), radius: radius, width: 1,
                               isActive ? accent.withAlpha(0.55) : TWColor(r: 1, g: 1, b: 1, a: 0.08))
    }

    private func drawHeader(renderer: Renderer, rect h: CGRect) {
        guard showsHeader else { return }
        let c = Theme.colors
        var background = RGBA.hex(isActive ? c.headerActiveBackground : c.headerBackground)
        if let tint = environmentStyle?.tint.flatMap({ RGBA(hex: $0) }) {
            background = background.blended(withFraction: isActive ? 0.34 : 0.22, of: tint)
        }
        renderer.fill(h, TWColor(background, alpha: isActive ? 0.96 : 0.88))
        renderer.fill(CGRect(x: h.minX, y: h.maxY - 1, width: h.width, height: 1), TWColor(r: 1, g: 1, b: 1, a: 0.07))

        let midY = h.midY
        var x = h.minX + 10
        if ConfigStore.shared.config.trafficLights {
            let t = trafficRects
            let dx = h.minX - headerRect.minX, dy = h.minY - headerRect.minY
            let colors: [(CGRect, String)] = [(t.close, "#ff5f57"), (t.collapse, "#febc2e"), (t.zoom, "#28c840")]
            for (r, hex) in colors {
                let rr = r.offsetBy(dx: dx, dy: dy)
                let color = isActive ? Theme.color(hex) : TWColor(r: 1, g: 1, b: 1, a: 0.18)
                renderer.fillCircle(center: CGPoint(x: rr.midX, y: rr.midY), radius: rr.width / 2, color)
            }
            x = t.zoom.offsetBy(dx: dx, dy: dy).maxX + 12
        }
        let pill = Draw.indexPill(index, at: CGPoint(x: x, y: (midY - Theme.pillHeight / 2).rounded()),
                                  active: isActive, renderer: renderer)
        x = pill.maxX + 8

        var right = h.maxX - 8
        if let note = transientNote {
            right = Draw.label(note, rightEdge: right, midY: midY, color: Theme.color(c.activeBorder), filled: true,
                               renderer: renderer).minX - 6
        }
        right = Draw.badge(badge, rightEdge: right, midY: midY, renderer: renderer)
        if isBroadcasting {
            right = Draw.label("BROADCAST", rightEdge: right, midY: midY, color: Theme.color(c.activity), filled: false,
                               renderer: renderer).minX - 6
        }
        if let style = environmentStyle, let tint = environmentTint {
            right = Draw.label(style.label.uppercased(), rightEdge: right, midY: midY, color: tint, filled: true,
                               renderer: renderer).minX - 6
        }
        let titleFont = Theme.ui(11, bold: isActive)
        let title = displayTitle
        let titleWidth = min(titleFont.width(of: title) + 2, max(0, right - x))
        renderer.text(title, in: CGRect(x: x, y: h.minY, width: titleWidth, height: h.height), font: titleFont,
                      color: Theme.color(isActive ? c.headerActiveText : c.headerText))
        x += titleWidth + 10
        let subtitle = displayDirectory
        if !subtitle.isEmpty, right - x > 30 {
            renderer.text(subtitle, in: CGRect(x: x, y: h.minY, width: right - x, height: h.height),
                          font: Theme.mono(10.5), color: Theme.color(c.headerText))
        }
    }

    private func drawScrollIndicator(renderer: Renderer, terminal t: CGRect) {
        let pos = session.scrollPosition
        guard pos.maxTop > 0, session.isScrolledBack else { return }
        let total = CGFloat(pos.maxTop + pos.rows)
        let height = max(20, t.height * CGFloat(pos.rows) / total)
        let y = t.minY + (t.height - height) * CGFloat(pos.top) / CGFloat(pos.maxTop)
        renderer.fillRounded(CGRect(x: t.maxX - Theme.scrollBarWidth - 2, y: y, width: Theme.scrollBarWidth, height: height),
                             radius: 2, TWColor(r: 1, g: 1, b: 1, a: 0.35))
    }

    private func drawFindBar(renderer: Renderer, rect: CGRect, field: TextField, caretOn: Bool, focused: Bool) {
        let c = Theme.colors
        renderer.fillRounded(rect, radius: 6, Theme.color(c.headerActiveBackground, alpha: 0.97))
        renderer.strokeRounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: 6, width: 1, Theme.color(c.inactiveBorder))
        let status = findStatus
        let statusWidth: CGFloat = status.isEmpty ? 0 : Theme.ui(10).width(of: status) + 10
        let fieldRect = CGRect(x: rect.minX + 6, y: rect.minY + 4, width: rect.width - 12 - statusWidth, height: rect.height - 8)
        field.draw(in: fieldRect, renderer: renderer, focused: findHasFocus && focused, caretOn: caretOn)
        if !status.isEmpty {
            renderer.text(status, in: CGRect(x: fieldRect.maxX + 4, y: rect.minY, width: statusWidth, height: rect.height),
                          font: Theme.ui(10), color: Theme.color(c.headerText))
        }
    }
}
