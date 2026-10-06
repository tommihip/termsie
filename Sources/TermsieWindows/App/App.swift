import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

struct LaunchArguments {
    var workspace: String?
    var cwd: String?
    var emitShim: String?

    static func parse(_ args: [String] = CommandLine.arguments) -> LaunchArguments {
        var result = LaunchArguments()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--workspace", "-w":
                if i + 1 < args.count { result.workspace = args[i + 1]; i += 1 }
            case "--cwd", "-C":
                if i + 1 < args.count { result.cwd = args[i + 1]; i += 1 }
            case "--emit-shim":
                if i + 1 < args.count { result.emitShim = args[i + 1]; i += 1 }
            default:
                break
            }
            i += 1
        }
        return result
    }
}

/// The application: its windows, the session that brings them back, workspaces, and quitting.
/// The Windows counterpart of the macOS `AppDelegate`.
final class App {
    static let shared = App()

    private(set) var windows: [MainWindow] = []
    /// Whether translucent pixels show a blurred backdrop (Windows 11 22H2 and later with
    /// `blurBackground` on). Without one, everything is drawn opaque.
    var backdropActive = false
    let launch = LaunchArguments.parse()
    private var configWatcher: ConfigWatcher?
    private var configObserver: NSObjectProtocol?
    private var quitting = false

    // MARK: Launch

    func run() -> Int32 {
        if let dir = launch.emitShim {
            emitShim(to: dir)
            return 0
        }
        MessageLoop.keyFilter = { msg in
            guard let window = MainWindow.forHandle(msg.hwnd) else { return false }
            return window.filterKey(&msg)
        }
        configObserver = NotificationCenter.default.addObserver(forName: .termsieConfigChanged, object: nil,
                                                                queue: nil) { [weak self] _ in
            self?.configChanged()
        }
        configWatcher = ConfigWatcher(directory: ConfigStore.shared.configDir)
        configWatcher?.start()

        if let name = launch.workspace {
            openWorkspace(named: name, inNewTab: false)
        } else if launch.cwd == nil, ConfigStore.shared.config.restoreSession, !DebugDriver.ignoresSession,
                  let session = WorkspaceStore.loadSession(), !session.windows.isEmpty {
            restore(session)
        }
        if windows.isEmpty {
            newWindow(cwd: launch.cwd)
        }
        pruneStaleTerminalState()
        DebugDriver.startIfRequested()
        Updater.shared.startAutomaticChecks()
        return MessageLoop.run()
    }

    private func emitShim(to path: String) {
        let dir = URL(fileURLWithPath: HomePath.expand(path))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in ShimScripts.files {
                try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try ShimScripts.version.write(to: dir.appendingPathComponent(".shim-version"), atomically: true, encoding: .utf8)
        } catch {
            Log.write("failed to write shim: \(error)")
        }
    }

    /// Removes state folders for terminals no saved session or workspace mentions any more.
    private func pruneStaleTerminalState() {
        let config = ConfigStore.shared.config
        var live = Set<String>()
        for w in windows { for tab in w.tabs { live.formUnion(tab.registry.order) } }
        if let session = WorkspaceStore.loadSession() {
            for w in session.windows { for tab in w.tabs { live.formUnion(tab.terminals.map(\.id)) } }
        }
        for name in WorkspaceStore.list() {
            if let ws = try? WorkspaceStore.load(name: name) { live.formUnion(ws.layout.terminals.map(\.id)) }
        }
        let keys = live
        let days = config.history.retentionDays
        Thread.detachNewThread {
            PaneStateStore.prune(keeping: keys, retentionDays: days)
        }
    }

    // MARK: Windows

    @discardableResult
    func makeWindow(frame: [Double]?, sidebarVisible: Bool? = nil, sidebarWidth: Double? = nil) -> MainWindow? {
        let window = MainWindow(sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth)
        guard window.open(frame: frame) else { return nil }
        window.onClosed = { [weak self] w in self?.windowClosed(w) }
        window.onStateChanged = { [weak self] _ in self?.scheduleSessionSave() }
        windows.append(window)
        return window
    }

    @discardableResult
    func newWindow(cwd: String?, layout: TabLayout? = nil, workspaceName: String? = nil, runStartupCommands: Bool = true,
                   holdShells: Bool = false) -> MainWindow? {
        guard let window = makeWindow(frame: nil) else { return nil }
        window.addTab(layout: layout ?? TabLayout.single(cwd: cwd), workspaceName: workspaceName,
                      runStartupCommands: runStartupCommands, holdShells: holdShells)
        window.show()
        return window
    }

    var keyWindow: MainWindow? {
        let fg = GetForegroundWindow()
        return windows.first { $0.hwnd == fg } ?? windows.last
    }

    func moveTabToNewWindow(_ tab: TabController, from source: MainWindow) {
        guard let window = makeWindow(frame: nil, sidebarVisible: source.sidebarVisible,
                                      sidebarWidth: Double(source.sidebarWidth)) else { return }
        source.detachTab(tab)
        window.adopt(tab)
        window.show()
        scheduleSessionSave()
    }

    func mergeAllWindows(into target: MainWindow) {
        for window in windows where window !== target {
            for tab in window.tabs {
                window.detachTab(tab)
                target.adopt(tab)
            }
        }
        scheduleSessionSave()
    }

    /// A window is about to close. When it is the last, this is quitting: the session is saved
    /// with it still in it, so the next launch brings it back.
    func windowWillClose(_ window: MainWindow) {
        if windows.count == 1 && windows.first === window {
            saveSession()
            quitting = true
        }
    }

    private func windowClosed(_ window: MainWindow) {
        windows.removeAll { $0 === window }
        if windows.isEmpty {
            prepareForExit()
            MessageLoop.quit(0)
        } else {
            scheduleSessionSave()
        }
    }

    /// Runs once on the way out, however the app is leaving.
    func prepareForExit() {
        configWatcher?.stop()
        Updater.shared.installPendingUpdate()
    }

    /// Quits from the menu: one question about running programs for every window, then each
    /// window closes without asking again.
    func quit() {
        let running = windows.flatMap { $0.tabs.flatMap { $0.registry.livePanes } }.filter(\.hasRunningJob)
        if ConfigStore.shared.config.confirmClosingRunningProcess, !running.isEmpty, !DebugDriver.isActive {
            let q = running.count == 1
                ? "Quit while “\(running[0].foregroundJob ?? "a process")” is running?"
                : "Quit with \(running.count) running processes?"
            guard Alert.confirm(q, "Running processes will be ended.", owner: keyWindow?.hwnd, warning: true) else { return }
        }
        saveSession()
        quitting = true
        for window in windows { window.requestClose(force: true) }
    }

    // MARK: Workspaces

    func openWorkspace(_ workspace: Workspace, inNewTab: Bool) {
        let live = Set(windows.flatMap { $0.tabs.flatMap(\.registry.order) })
        var layout = workspace.layout.regeneratingIDs(avoiding: live)
        layout.workspaceName = workspace.name
        let ask = shouldAskBeforeRunningStartupCommands(in: [layout])
        let tab: TabController?
        if inNewTab, let key = keyWindow {
            tab = key.addTab(layout: layout, workspaceName: workspace.name, runStartupCommands: !ask, holdShells: ask)
        } else {
            tab = newWindow(cwd: nil, layout: layout, workspaceName: workspace.name, runStartupCommands: !ask,
                            holdShells: ask)?.selectedTab
        }
        if ask, let tab { offerStartupCommands(for: "“\(workspace.name)”", in: [tab]) }
    }

    func openWorkspace(named name: String, inNewTab: Bool) {
        do {
            openWorkspace(try WorkspaceStore.load(name: name), inNewTab: inNewTab)
        } catch {
            Alert.error("Could not open the workspace “\(name)”", error.localizedDescription, owner: keyWindow?.hwnd)
        }
    }

    /// Reopening a workspace is often just to look at it, and its commands may start servers or
    /// deploys, so running them is offered rather than assumed.
    private func shouldAskBeforeRunningStartupCommands(in layouts: [TabLayout]) -> Bool {
        guard ConfigStore.shared.config.startupCommands.askBeforeRunning else { return false }
        guard !DebugDriver.isActive || CommandLine.arguments.contains("--ask-startup") else { return false }
        return layouts.flatMap(\.terminals).contains { $0.openOnRestore && !$0.commands(isReopen: false).isEmpty }
    }

    /// Asks once whether to run the held-back startup commands, after the windows are on screen,
    /// then starts every held shell with its commands or without.
    func offerStartupCommands(for what: String, in tabs: [TabController]) {
        let count = tabs.reduce(0) { $0 + $1.openTerminalsWithStartupCommands.count }
        let startAll = { (run: Bool) in for t in tabs { t.startHeldTerminals(runningCommands: run) } }
        guard count > 0 else { startAll(false); return }
        MainQueue.shared.after(0.2) { [weak self] in
            if DebugDriver.isActive, let answer = DebugDriver.startupAnswer {
                startAll(answer)
                return
            }
            let message = (count == 1 ? "1 terminal has" : "\(count) terminals have")
                + " startup commands. Skipping leaves the terminals as they are; you can run the commands later with the ▶ button beside a terminal in the list, or Run All below it.\n\nYes runs them, No skips them."
            let run = Alert.yesNo("Run the startup commands for \(what)?", message, owner: self?.keyWindow?.hwnd)
            startAll(run)
        }
    }

    // MARK: Session

    func scheduleSessionSave() {
        guard !quitting else { return }
        WorkspaceStore.scheduleSessionSave { [weak self] in
            self?.currentSession() ?? SessionSnapshot(windows: [])
        }
    }

    func currentSession() -> SessionSnapshot {
        SessionSnapshot(windows: windows.filter { !$0.tabs.isEmpty }.map(\.sessionSnapshot))
    }

    func saveSession() {
        guard !DebugDriver.ignoresSession else { return }
        let snapshot = currentSession()
        if snapshot.windows.isEmpty { WorkspaceStore.clearSession() } else { WorkspaceStore.saveSession(snapshot) }
    }

    private func restore(_ session: SessionSnapshot) {
        let ask = shouldAskBeforeRunningStartupCommands(in: session.windows.flatMap(\.tabs))
        var opened: [TabController] = []
        for w in session.windows where !w.tabs.isEmpty {
            guard let window = makeWindow(frame: w.frame, sidebarVisible: w.sidebarVisible, sidebarWidth: w.sidebarWidth) else { continue }
            for layout in w.tabs {
                opened.append(window.addTab(layout: layout, workspaceName: layout.workspaceName, runStartupCommands: !ask,
                                            holdShells: ask, select: false))
            }
            window.selectTab(min(max(w.selectedTab, 0), window.tabs.count - 1))
            window.show()
        }
        if ask { offerStartupCommands(for: "the last session", in: opened) }
    }

    // MARK: Config

    private func configChanged() {
        for window in windows {
            window.applyChrome()
            for tab in window.tabs { tab.applyConfig() }
            window.setNeedsDisplay()
        }
    }

    // MARK: Commands

    func perform(_ command: Command, from window: MainWindow) {
        switch command {
        case .newWindow:
            newWindow(cwd: window.selectedTab?.activePane?.currentDirectory.map { HomePath.abbreviate($0) })
        case .settings:
            SettingsDialog.show(owner: window.hwnd)
        case .environments:
            SettingsDialog.show(owner: window.hwnd, page: 4)
        case .editConfig:
            Shell.open(ConfigStore.shared.configURL.path)
        case .reloadConfig:
            ConfigStore.shared.reload()
        case .showConfigFolder:
            Shell.reveal(folder: ConfigStore.shared.configDir.path, file: "config.json")
        case .showWorkspacesFolder:
            Shell.open(ConfigStore.shared.workspacesDir.path)
        case .openWorkspace(let name):
            if !name.isEmpty { openWorkspace(named: name, inNewTab: true) }
        case .openWorkspaceFile:
            if let path = FileDialog.open(owner: window.hwnd, title: "Open Workspace",
                                          folder: ConfigStore.shared.workspacesDir.path) {
                do {
                    openWorkspace(try WorkspaceStore.load(fileURL: URL(fileURLWithPath: path)), inNewTab: true)
                } catch {
                    Alert.error("Could not open the workspace", error.localizedDescription, owner: window.hwnd)
                }
            }
        case .checkForUpdates:
            Updater.shared.checkNow(owner: window.hwnd)
        case .about:
            Alert.info("About Termsie", "Termsie \(AppInfo.version)\n\nOne window for everything you're running.\n\nhttps://termsie.com\nApache License 2.0",
                       owner: window.hwnd)
        case .exit:
            quit()
        default:
            break
        }
    }
}

/// Reloads config.json when it changes on disk. A thread waits on the folder's change
/// notification; reloads are debounced, since editors write a file in several steps.
final class ConfigWatcher {
    private let directory: URL
    private var running = false
    private var handle: HANDLE?
    private let debounce = Debouncer()

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        guard !running else { return }
        let path = ShellIntegration.nativePath(directory)
        let h: HANDLE? = withWide(path) {
            FindFirstChangeNotificationW($0, false, DWORD(0x0000_0001 | 0x0000_0010) /* FILE_NAME | LAST_WRITE */)
        }
        guard let h, h != HANDLE(bitPattern: -1) else {
            Log.write("config watcher unavailable for \(path)")
            return
        }
        handle = h
        running = true
        let thread = Thread { [weak self] in
            while let self, self.running, let h = self.handle {
                let r = WaitForSingleObject(h, 1000)
                guard self.running else { break }
                if r == 0 /* WAIT_OBJECT_0 */ {
                    MainQueue.shared.async { [weak self] in
                        self?.debounce.schedule(after: 0.25) { ConfigStore.shared.reload() }
                    }
                    if !FindNextChangeNotification(h) { break }
                }
            }
        }
        thread.name = "Termsie config watcher"
        thread.start()
    }

    func stop() {
        running = false
        if let h = handle { FindCloseChangeNotification(h) }
        handle = nil
    }
}
