import Foundation
import WinSDK
import CTermsieWin
import SwiftTerm
import TermsieCore

/// Drives the app from the command line, which is how the Windows tests work:
///
///     Termsie.exe --snapshot out.png --actions newTerminal,type:dir\n,wait,tileGrid --log out.log --quit
///
/// Actions run one per `--step` seconds (0.7 by default) after a short lead. Each `dump…` action
/// writes a line to the log; `--snapshot` writes a PNG of the front window at the end, drawn
/// opaque so it can be compared. Nothing here touches the user's real config, session or
/// credentials: tests point XDG_CONFIG_HOME at a fixture and secrets at TERMSIE_SECRETS_FILE.
enum DebugDriver {
    static var isActive: Bool {
        let args = CommandLine.arguments
        return args.contains("--snapshot") || args.contains("--actions") || args.contains("--script")
    }

    /// Scripted runs neither restore nor save the session unless asked to.
    static var ignoresSession: Bool {
        isActive && !CommandLine.arguments.contains("--use-session")
    }

    /// How a scripted run answers "run the startup commands?": `--answer-startup run|skip`.
    static var startupAnswer: Bool? {
        value(of: "--answer-startup").map { $0 == "run" }
    }

    static func value(of flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func startIfRequested() {
        if let log = value(of: "--log") { DebugOutput.open(path: log) }
        guard isActive else { return }
        var actions: [String] = []
        if let spec = value(of: "--actions") {
            actions = splitActions(spec)
        }
        if let file = value(of: "--script"), let text = try? String(contentsOfFile: file, encoding: .utf8) {
            actions += text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let step = Double(value(of: "--step") ?? "0.7") ?? 0.7
        let tail = Double(value(of: "--tail") ?? "1.5") ?? 1.5
        var t = Double(value(of: "--lead") ?? "2.5") ?? 2.5
        for action in actions {
            MainQueue.shared.after(t) { perform(action) }
            t += action == "wait" ? step : (action.hasPrefix("sleep:") ? (Double(action.dropFirst(6)) ?? 1) : step)
        }
        MainQueue.shared.after(t + tail) {
            if let path = value(of: "--snapshot"), let window = App.shared.keyWindow {
                let ok = window.snapshot(to: path)
                DebugOutput.print("snapshot=\(ok ? "ok" : "failed") path=\(path)")
            }
            if CommandLine.arguments.contains("--quit") {
                DebugOutput.print("done")
                for window in App.shared.windows { window.requestClose(force: true) }
            }
        }
    }

    /// Commas separate actions, except inside `type:` text where `\,` stands for a comma.
    private static func splitActions(_ spec: String) -> [String] {
        var out: [String] = []
        var current = ""
        var escape = false
        for ch in spec {
            if escape { current.append(ch); escape = false; continue }
            if ch == "\\" { escape = true; current.append(ch); continue }
            if ch == "," { out.append(current); current = ""; continue }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out.map { $0.replacingOccurrences(of: "\\,", with: ",") }
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\r").replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\e", with: "\u{1b}")
    }

    private static var window: MainWindow? { App.shared.keyWindow }
    private static var tab: TabController? { window?.selectedTab }

    private static func paneNumber(_ s: Substring) -> Pane? {
        guard let n = Int(s), let tab, let id = tab.registry.id(at: n - 1) else { return nil }
        return tab.registry.pane(for: id)
    }

    private static func idNumber(_ s: Substring) -> String? {
        guard let n = Int(s), let tab else { return nil }
        return tab.registry.id(at: n - 1)
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\u{1b}", with: "\\e")
    }

    static let commandNames: [String: Command] = [
        "newTerminal": .newTerminal, "newTerminalAction": .newTerminal, "newTerminalTiled": .newTerminalTiled,
        "duplicateTerminal": .duplicateTerminal, "clearScrollback": .clearScrollback, "closeTerminal": .closeTerminal,
        "tileGrid": .tileGrid, "cascade": .cascade, "maximize": .maximize, "toggleZoom": .maximize, "collapse": .collapse,
        "leftHalf": .leftHalf, "rightHalf": .rightHalf, "topHalf": .topHalf, "bottomHalf": .bottomHalf, "center": .center,
        "bringToFront": .bringToFront, "sendToBack": .sendToBack, "toggleHeaders": .toggleHeaders, "togglePaneHeaders": .toggleHeaders,
        "broadcast": .broadcast, "toggleBroadcast": .broadcast, "toggleSidebar": .toggleSidebar,
        "focusLeft": .focusLeft, "focusRight": .focusRight, "focusUp": .focusUp, "focusDown": .focusDown,
        "nextTerminal": .nextTerminal, "previousTerminal": .previousTerminal, "biggerText": .biggerText,
        "smallerText": .smallerText, "defaultTextSize": .defaultTextSize, "find": .find, "findNext": .findNext,
        "findPrevious": .findPrevious, "newTab": .newTab, "nextTab": .nextTab, "previousTab": .previousTab,
        "closeTab": .closeTab, "runStartupCommands": .runStartupCommands, "runAllStartupCommands": .runAllStartupCommands,
        "selectAll": .selectAll, "saveWorkspace": .saveWorkspace, "autoCopy": .autoCopy, "fullScreen": .fullScreen,
        "moveTabToNewWindow": .moveTabToNewWindow, "mergeAllWindows": .mergeAllWindows, "newWindow": .newWindow,
    ]

    static func perform(_ action: String) {
        guard let window, let tab else {
            DebugOutput.print("no window for \(action)")
            return
        }
        let pane = tab.activePane
        if let command = commandNames[action] {
            window.perform(command)
            return
        }
        if action == "wait" || action.hasPrefix("sleep:") { return }
        if action.hasPrefix("type:") {
            pane?.session.send(text: unescape(String(action.dropFirst(5))))
        } else if action.hasPrefix("key:") {
            let names: [String: Int32] = ["up": Win.VK_UP, "down": Win.VK_DOWN, "left": Win.VK_LEFT, "right": Win.VK_RIGHT,
                                          "home": Win.VK_HOME, "end": Win.VK_END, "pgup": Win.VK_PRIOR, "pgdn": Win.VK_NEXT,
                                          "delete": Win.VK_DELETE, "backspace": Win.VK_BACK, "f5": Win.VK_F1 + 4]
            if let vk = names[String(action.dropFirst(4))], let pane,
               let bytes = KeyEncoder.keyDown(vk: vk, modifiers: [], applicationCursor: pane.session.terminal.applicationCursor) {
                pane.session.send(user: bytes)
            }
        } else if action.hasPrefix("findText:") {
            pane?.showFindBar()
            if let field = pane?.findField {
                field.setText(String(action.dropFirst(9)))
                field.onChange?(field.text)
            }
        } else if action == "dumpFind" {
            DebugOutput.print("find matches=\(pane?.matches.count ?? 0) status=\(pane?.findStatus ?? "")")
        } else if action.hasPrefix("copy:"), let target = CopyTarget(rawValue: String(action.dropFirst(5))) {
            let copied = tab.performCopy(target)
            DebugOutput.print("copy \(target.rawValue) copied=\(copied)")
        } else if action == "dumpClipboard" {
            DebugOutput.print("clipboard=\(escaped(Clipboard.get(owner: window.hwnd) ?? ""))")
        } else if action == "dumpCopyState", let pane {
            DebugOutput.print("copyState \(pane.session.copyStateDescription)")
        } else if action.hasPrefix("select:"), let pane {
            let n = action.dropFirst(7).split(separator: ",").compactMap { Int($0) }
            if n.count == 4 {
                pane.session.selection.setSelection(start: pane.session.bufferPosition(col: n[1], row: n[0]),
                                                    end: pane.session.bufferPosition(col: n[3], row: n[2]))
                window.setNeedsDisplay()
            }
        } else if action == "dumpSelection" {
            DebugOutput.print("selection=\(escaped(pane?.session.selectedText ?? ""))")
        } else if action == "autoCopyNow", let pane {
            DebugOutput.print("autoCopy copied=\(pane.session.autoCopySelection(owner: window.hwnd))")
        } else if action == "dumpTerminals" || action == "dumpLayout" {
            for (i, id) in tab.registry.order.enumerated() {
                let def = tab.registry.definition(id)
                let p = tab.registry.pane(for: id)
                let f = p?.layoutFraction ?? def?.fractionalFrame ?? .zero
                DebugOutput.print("terminal \(i + 1) id=\(id) open=\(p != nil) active=\(p != nil && p === tab.activePane)"
                    + " name=\(p?.displayTitle ?? def?.displayName ?? "") z=\(p?.zIndex ?? def?.z ?? 0)"
                    + String(format: " frame=%.3f,%.3f,%.3f,%.3f", f.minX, f.minY, f.width, f.height)
                    + " px=\(p.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" } ?? "-")"
                    + " grid=\(p.map { "\($0.session.terminal.cols)x\($0.session.terminal.rows)" } ?? "-")"
                    + " env=\(def?.environment ?? "") cwd=\(p?.displayDirectory ?? def?.cwd ?? "")")
            }
        } else if action.hasPrefix("move:") || action.hasPrefix("resize:"), let pane {
            let isMove = action.hasPrefix("move:")
            let n = action.drop { $0 != ":" }.dropFirst().split(separator: ",").compactMap { Double($0) }
            guard n.count == 2 else { return }
            let zone: ChromeZone = isMove ? .move : .bottomRight
            pane.isUserResizing = !isMove
            let proposed = PaneChrome.propose(pane.frame, zone: zone, delta: CGPoint(x: n[0], y: n[1]))
            pane.frame = tab.resolve(proposed, for: pane, zone: zone, snapping: true)
            pane.isUserResizing = false
            pane.transientNote = nil
            tab.commitFraction(for: pane)
        } else if action == "dumpWorkspace" {
            DebugOutput.print("workspace=\(json(tab.snapshot()))")
        } else if action.hasPrefix("saveWorkspaceNamed:") {
            let ok = tab.saveWorkspace(named: String(action.dropFirst(19)))
            DebugOutput.print("saved=\(ok) name=\(tab.workspaceName ?? "")")
        } else if action == "newWorkspaceDiscarding" {
            tab.resetToEmptyWorkspace()
        } else if action.hasPrefix("openWorkspace:") {
            App.shared.openWorkspace(named: String(action.dropFirst(14)), inNewTab: true)
        } else if action == "dumpBadges" {
            for p in tab.registry.livePanes { DebugOutput.print("badge \(p.index) \(p.badge)") }
        } else if action == "dumpFonts" {
            for p in tab.registry.livePanes {
                let m = p.fonts.metrics
                DebugOutput.print("font \(p.index) family=\(p.fonts.regular.family) size=\(p.fonts.regular.size)"
                    + String(format: " cell=%.2fx%.2f", m.cellWidth, m.cellHeight))
            }
        } else if action.hasPrefix("setFont:"), let pane, let size = Double(action.dropFirst(8)) {
            tab.registry.mutate(pane.definitionID) { $0.fontSize = size }
        } else if action.hasPrefix("setGlobalFont:") {
            let parts = action.dropFirst(14).split(separator: ",")
            ConfigStore.shared.update { c in
                if let f = parts.first { c.font.family = String(f) }
                if parts.count > 1, let s = Double(parts[1]) { c.font.size = s }
            }
        } else if action.hasPrefix("setTextLayout:"), let pane {
            let parts = action.dropFirst(14).split(separator: ",")
            tab.registry.mutate(pane.definitionID) { d in
                if let p = parts.first { d.padding = Double(p) }
                if parts.count > 1 { d.lineWrap = parts[1] == "wrap" ? true : parts[1] == "nowrap" ? false : nil }
            }
        } else if action == "dumpTextLayout" {
            for p in tab.registry.livePanes {
                DebugOutput.print("layout \(p.index) padding=\(p.padding) wraps=\(p.wrapsLines) cols=\(p.session.terminal.cols) visible=\(p.visibleColumns)")
            }
        } else if action.hasPrefix("scrollTerminal:"), let pane, let n = Int(action.dropFirst(15)) {
            pane.session.scroll(by: n)
            DebugOutput.print("scroll top=\(pane.session.scrollPosition.top) max=\(pane.session.scrollPosition.maxTop) back=\(pane.session.isScrolledBack)")
        } else if action.hasPrefix("applyWorkspaceJSON:") {
            let path = String(action.dropFirst(19))
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                DebugOutput.print("applyJSON missing \(path)")
                return
            }
            tab.showWorkspaceSettings(selecting: nil)
            DebugOutput.print("applyJSON \(tab.workspaceSettings?.applyJSONForTesting(text) ?? "no panel")")
        } else if action == "dumpWorkspaceJSON" {
            DebugOutput.print("workspaceJSON=\(escaped(tab.workspaceDocument.jsonText()))")
        } else if action == "dumpNames" {
            for id in tab.registry.order {
                DebugOutput.print("name \(tab.registry.number(of: id)) header=\(tab.registry.pane(for: id)?.displayTitle ?? "-") row=\(tab.registry.pane(for: id)?.displayTitle ?? tab.registry.definition(id)?.displayName ?? "")")
            }
        } else if action.hasPrefix("rename:"), let pane {
            let name = String(action.dropFirst(7))
            tab.registry.mutate(pane.definitionID) { $0.name = name.isEmpty ? nil : name }
        } else if action.hasPrefix("setEnv:"), let pane {
            let env = String(action.dropFirst(7))
            tab.setEnvironment(env.isEmpty ? nil : env, for: pane.definitionID)
        } else if action.hasPrefix("secret:"), let pane {
            // secret:NAME=value gives the focused terminal a secret variable.
            let body = action.dropFirst(7)
            guard let eq = body.firstIndex(of: "=") else { return }
            let name = String(body[..<eq]), value = String(body[body.index(after: eq)...])
            let ref = SecretStore.newRef()
            let stored = SecretStore.setValue(value, for: ref, label: "Termsie test: \(name)")
            tab.registry.mutate(pane.definitionID) { $0.env.append(EnvVar(name: name, secret: true, secretRef: ref)) }
            DebugOutput.print("secret stored=\(stored)")
        } else if action.hasPrefix("plainVar:"), let pane {
            let body = action.dropFirst(9)
            guard let eq = body.firstIndex(of: "=") else { return }
            tab.registry.mutate(pane.definitionID) {
                $0.env.append(EnvVar(name: String(body[..<eq]), value: String(body[body.index(after: eq)...])))
            }
        } else if action.hasPrefix("dumpThumb:"), let id = idNumber(action.dropFirst(10)) {
            DebugOutput.print("thumb renders=\(tab.sidebar.renderCount(for: id))")
        } else if action.hasPrefix("openTerminal:"), let id = idNumber(action.dropFirst(13)) {
            tab.openTerminal(id, isReopen: true)
        } else if action.hasPrefix("closeTerminal:"), let p = paneNumber(action.dropFirst(14)) {
            tab.closePane(p, force: true)
        } else if action.hasPrefix("deleteTerminal:"), let id = idNumber(action.dropFirst(15)) {
            tab.sidebarDidRequestDelete(id)
        } else if action.hasPrefix("setSidebarWidth:"), let w = Double(action.dropFirst(16)) {
            window.setSidebarWidth(CGFloat(w))
        } else if action.hasPrefix("dumpRow:"), let id = idNumber(action.dropFirst(8)) {
            DebugOutput.print("row \(tab.sidebar.describeRow(id, width: window.sidebarWidth))")
        } else if action.hasPrefix("pressRun:"), let id = idNumber(action.dropFirst(9)) {
            tab.runStartupCommands(for: id, askIfBusy: false)
        } else if action.hasPrefix("dumpText:"), let p = paneNumber(action.dropFirst(9)) {
            DebugOutput.print("--- text \(p.index)")
            DebugOutput.print(p.session.screenText)
            DebugOutput.print("--- end")
        } else if action == "dumpScreen", let pane {
            DebugOutput.print("--- screen")
            DebugOutput.print(pane.session.screenText)
            DebugOutput.print("--- end")
        } else if action.hasPrefix("pane:"), let p = paneNumber(action.dropFirst(5)) {
            tab.setActivePane(p)
        } else if action == "dumpTitle" {
            DebugOutput.print("title=\(window.title)")
        } else if action == "dumpState" {
            DebugOutput.print("state windows=\(App.shared.windows.count) tabs=\(window.tabs.count) terminals=\(tab.registry.count) open=\(tab.registry.openCount)"
                + " sidebar=\(window.sidebarVisible) width=\(Int(window.sidebarWidth)) modified=\(tab.isWorkspaceModified) workspace=\(tab.workspaceName ?? "")"
                + " backdrop=\(App.shared.backdropActive) shell=\(ConfigStore.shared.config.resolvedShell)")
        } else if action == "dumpProcess", let pane {
            DebugOutput.print("process pid=\(pane.session.pid) running=\(pane.session.isRunning) job=\(pane.foregroundJob ?? "-") busy=\(pane.hasRunningJob) exited=\(pane.hasExited) code=\(pane.exitCode.map(String.init) ?? "-")")
        } else if action == "pollNow" {
            tab.pollProcesses()
        } else if action.hasPrefix("snapshot:") {
            let ok = window.snapshot(to: String(action.dropFirst(9)))
            DebugOutput.print("snapshot=\(ok ? "ok" : "failed") path=\(action.dropFirst(9))")
        } else if action == "dumpSession" {
            DebugOutput.print("session=\(json(App.shared.currentSession()))")
        } else if action == "saveSession" {
            WorkspaceStore.saveSession(App.shared.currentSession())
        } else if action == "dumpConfigDir" {
            DebugOutput.print("configDir=\(ConfigStore.shared.configDir.path)")
        } else {
            DebugOutput.print("unknown action \(action)")
        }
    }
}
