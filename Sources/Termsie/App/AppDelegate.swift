import AppKit

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var controllers: [TerminalWindowController] = []
    private let launch = LaunchArguments.parse()
    private var mouseMonitor: Any?

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Materialise the shell shim without launching the UI, so it can be diffed against a
        // native shell in tests before anything else runs.
        if let dir = launch.emitShim {
            emitShim(to: dir)
            exit(0)
        }

        MainMenu.install()
        ConfigStore.shared.startWatching()

        if let name = launch.workspace {
            openWorkspace(named: name, inNewTab: false)
        } else if launch.cwd == nil, ConfigStore.shared.config.restoreSession,
                  let session = WorkspaceStore.loadSession(), !session.windows.isEmpty {
            restore(session)
        }
        if controllers.isEmpty {
            newWindow(cwd: launch.cwd)
        }
        NSApp.activate(ignoringOtherApps: true)
        startCursorTracking()
        pruneStaleTerminalState()
        DebugDriver.startIfRequested()
    }

    /// One monitor for the whole app, rather than a tracking area per window.
    ///
    /// Cursor rects are disabled for terminal windows (they cannot tell which of two overlapping
    /// terminals is in front), so something has to set the pointer as it moves. A `.cursorUpdate`
    /// tracking area is not enough: it fires on entering and leaving an area, not on movement
    /// within one. SwiftTerm hits the same limitation and works around it the same way, noting
    /// that `.mouseMoved` tracking areas are unreliable on macOS 26.
    private func startCursorTracking() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            if let controller = event.window?.windowController as? TerminalWindowController {
                controller.updateCursor(atWindowPoint: event.locationInWindow)
            }
            return event
        }
    }

    private func emitShim(to path: String) {
        let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in ShimScripts.files {
                try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try ShimScripts.version.write(to: dir.appendingPathComponent(".shim-version"),
                                          atomically: true, encoding: .utf8)
            print("wrote shim v\(ShimScripts.version) to \(dir.path)")
        } catch {
            print("failed to write shim: \(error)")
            exit(1)
        }
    }

    /// Removes state directories for terminals that no longer exist in any saved session.
    private func pruneStaleTerminalState() {
        let config = ConfigStore.shared.config
        var live = Set<String>()
        for controller in controllers { live.formUnion(controller.registry.order) }
        if let session = WorkspaceStore.loadSession() {
            for window in session.windows {
                for tab in window.tabs { live.formUnion(tab.terminals.map(\.id)) }
            }
        }
        for name in WorkspaceStore.list() {
            if let ws = try? WorkspaceStore.load(name: name) {
                live.formUnion(ws.layout.terminals.map(\.id))
            }
        }
        let keys = live
        let days = config.history.retentionDays
        DispatchQueue.global(qos: .utility).async {
            PaneStateStore.prune(keeping: keys, retentionDays: days)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = controllers.flatMap(\.panes).filter(\.hasRunningJob)
        if ConfigStore.shared.config.confirmClosingRunningProcess, !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = running.count == 1
                ? "Quit while “\(running[0].foregroundJob ?? "a process")” is running?"
                : "Quit with \(running.count) running processes?"
            alert.informativeText = "Running processes will be terminated."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        saveSession()
        for c in controllers { c.panes.forEach { $0.terminate() } }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(cwd: nil) }
        return true
    }

    // MARK: Windows

    func makeWindowController(layout: TabLayout?, frame: NSRect?,
                              sidebarVisible: Bool? = nil, sidebarWidth: Double? = nil,
                              workspaceName: String? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController(layout: layout, frame: frame,
                                                  sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth,
                                                  workspaceName: workspaceName)
        controller.onClose = { [weak self] c in
            self?.controllers.removeAll { $0 === c }
            self?.scheduleSessionSave()
        }
        controller.onStateChanged = { [weak self] _ in self?.scheduleSessionSave() }
        controllers.append(controller)
        return controller
    }

    @discardableResult
    func newWindow(cwd: String?, layout: TabLayout? = nil) -> TerminalWindowController {
        let controller = makeWindowController(layout: layout ?? TabLayout.single(cwd: cwd), frame: nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private var keyController: TerminalWindowController? {
        NSApp.keyWindow?.windowController as? TerminalWindowController ?? controllers.last
    }

    func openWorkspace(_ workspace: Workspace, inNewTab: Bool) {
        // Fresh ids per open, so opening the same workspace twice does not make two live
        // terminals write into one history file.
        var layout = workspace.layout.regeneratingIDs()
        layout.workspaceName = workspace.name
        if inNewTab, let key = keyController {
            _ = key.addTab(layout: layout)
        } else {
            newWindow(cwd: nil, layout: layout)
        }
    }

    func openWorkspace(named name: String, inNewTab: Bool) {
        do {
            openWorkspace(try WorkspaceStore.load(name: name), inNewTab: inNewTab)
        } catch {
            NSApp.presentError(error)
        }
    }

    // MARK: Session

    func scheduleSessionSave() {
        WorkspaceStore.scheduleSessionSave { [weak self] in
            self?.currentSession() ?? SessionSnapshot(windows: [])
        }
    }

    private func currentSession() -> SessionSnapshot {
        var snapshots: [SessionSnapshot.WindowSnapshot] = []
        var seen = Set<ObjectIdentifier>()
        for controller in controllers {
            guard let window = controller.window, window.isVisible else { continue }
            let tabbed = window.tabGroup?.windows ?? [window]
            let groupKey = ObjectIdentifier(window.tabGroup.map { $0 as AnyObject } ?? window)
            guard !seen.contains(groupKey) else { continue }
            seen.insert(groupKey)
            let tabControllers = tabbed.compactMap { $0.windowController as? TerminalWindowController }
            guard !tabControllers.isEmpty else { continue }
            // Startup commands persist and do run on restore — activating a venv is exactly the
            // point. Only the inferred running command is left out.
            let layouts = tabControllers.map { $0.snapshot() }
            let selected = window.tabGroup?.selectedWindow.flatMap { tabbed.firstIndex(of: $0) } ?? 0
            let f = window.frame
            snapshots.append(.init(frame: [f.origin.x, f.origin.y, f.width, f.height],
                                   tabs: layouts, selectedTab: selected,
                                   sidebarVisible: controller.sidebarVisible,
                                   sidebarWidth: controller.sidebarWidth))
        }
        return SessionSnapshot(windows: snapshots)
    }

    func saveSession() {
        let snapshot = currentSession()
        if snapshot.windows.isEmpty { WorkspaceStore.clearSession() }
        else { WorkspaceStore.saveSession(snapshot) }
    }

    private func restore(_ session: SessionSnapshot) {
        for w in session.windows {
            guard let first = w.tabs.first else { continue }
            var frame: NSRect? = nil
            if w.frame.count == 4 {
                frame = NSRect(x: w.frame[0], y: w.frame[1], width: w.frame[2], height: w.frame[3])
            }
            let controller = makeWindowController(layout: first, frame: frame,
                                                  sidebarVisible: w.sidebarVisible,
                                                  sidebarWidth: w.sidebarWidth)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            var tabs = [controller]
            for layout in w.tabs.dropFirst() { tabs.append(controller.addTab(layout: layout)) }
            if w.selectedTab < tabs.count, let win = tabs[w.selectedTab].window {
                win.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: Menu actions

    @objc func newWindow(_ sender: Any?) {
        newWindow(cwd: keyController?.activePane?.currentDirectory)
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func openEnvironmentSettings(_ sender: Any?) {
        SettingsWindowController.shared.showEnvironments()
    }

    @objc func openConfig(_ sender: Any?) {
        NSWorkspace.shared.open(ConfigStore.shared.configURL)
    }

    @objc func openConfigFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.shared.configURL])
    }

    @objc func openWorkspacesFolder(_ sender: Any?) {
        NSWorkspace.shared.open(ConfigStore.shared.workspacesDir)
    }

    @objc func reloadConfig(_ sender: Any?) {
        ConfigStore.shared.reload()
    }

    @objc func openWorkspaceMenuItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        openWorkspace(named: name, inNewTab: true)
    }

    @objc func openWorkspaceFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = ConfigStore.shared.workspacesDir
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                self?.openWorkspace(try WorkspaceStore.load(fileURL: url), inNewTab: true)
            } catch {
                NSApp.presentError(error)
            }
        }
    }
}
