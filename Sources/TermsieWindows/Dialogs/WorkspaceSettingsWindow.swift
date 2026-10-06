import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// Every terminal of one workspace in one place, as a form or as JSON. Both views edit the same
/// `WorkspaceDocument`, so they can never disagree about what a field means; changes take effect
/// on Apply and Revert throws them away.
final class WorkspaceSettingsWindow: FormWindow {
    private weak var tab: TabController?
    private weak var mainWindow: MainWindow?
    private var document = WorkspaceDocument()
    private var baseline = WorkspaceDocument()
    private var selected = 0
    private var showingJSON = false
    private var created: [String] = []
    private var built = false
    private var environments: [TermsieConfig.EnvironmentStyle] = []

    private static let applyID: Int32 = 20
    private static let revertID: Int32 = 21
    private static let closeID: Int32 = 22

    init(tab: TabController, owner: MainWindow) {
        self.tab = tab
        self.mainWindow = owner
        super.init()
    }

    private static let formKeys = ["wsHeading", "wsFontFamily", "wsFontSize", "wsPadding", "wsWrap", "wsKept", "wsEnv",
                                   "tHeading", "terminal", "add", "remove", "tName", "tCwd", "tEnvironment", "tCommands",
                                   "tReopen", "tHistory", "tFontFamily", "tFontSize", "tPadding", "tWrap", "tEnv", "envNote"]

    func show(selecting id: String?) {
        guard let tab else { return }
        if !built {
            guard buildWindow() else { return }
            built = true
        }
        baseline = tab.workspaceDocument
        if !isDirty { document = baseline }
        if let id, let i = document.terminals.firstIndex(where: { $0.id == id }) { selected = i }
        loadForm()
        showModeless()
    }

    private func buildWindow() -> Bool {
        let config = ConfigStore.shared.config
        environments = config.environments
        let fonts = [""] + FontCache.families(monospacedOnly: true)
        let wrapOptions = ["Inherit", "Wrap", "Don't wrap"]
        labelWidth = 150
        fieldWidth = 420
        guard build(title: "Workspace Settings", owner: mainWindow?.hwnd, fields: [
            Field("view", "View", .choice(["Form", "JSON"], selected: 0)),
            Field("wsHeading", "", .heading("Workspace defaults (empty inherits the global settings)")),
            Field("wsFontFamily", "Font", .combo(fonts, text: "")),
            Field("wsFontSize", "Size", .text("")),
            Field("wsPadding", "Padding", .text("")),
            Field("wsWrap", "Long lines", .choice(wrapOptions, selected: 0)),
            Field("wsKept", "Output kept on close (lines)", .text("")),
            Field("wsEnv", "Variables for every terminal", .multiline("", lines: 3, monospace: true)),
            Field("tHeading", "", .heading("Terminal")),
            Field("terminal", "Terminal", .choice([], selected: 0)),
            Field("add", "", .button("Add Terminal")),
            Field("remove", "", .button("Remove This Terminal")),
            Field("tName", "Name", .text("")),
            Field("tCwd", "Working folder", .text(""), accessory: "Browse…"),
            Field("tEnvironment", "Environment", .choice(["None"] + environments.map(\.label), selected: 0)),
            Field("tCommands", "Startup commands", .multiline("", lines: 4, monospace: true)),
            Field("tReopen", "Run them when reopened", .check(true)),
            Field("tHistory", "Own command history", .check(true)),
            Field("tFontFamily", "Font", .combo(fonts, text: "")),
            Field("tFontSize", "Size", .text("")),
            Field("tPadding", "Padding", .text("")),
            Field("tWrap", "Long lines", .choice(wrapOptions, selected: 0)),
            Field("tEnv", "Variables", .multiline("", lines: 3, monospace: true)),
            Field("envNote", "", .note(EnvText.help)),
            Field("status", "", .note("")),
        ], buttons: [
            ButtonSpec(id: WorkspaceSettingsWindow.revertID, title: "Revert"),
            ButtonSpec(id: WorkspaceSettingsWindow.applyID, title: "Apply", isDefault: true),
            ButtonSpec(id: WorkspaceSettingsWindow.closeID, title: "Close"),
        ], resizable: false) else { return false }

        // The JSON view sits where the form does and is shown instead of it.
        if let first = labels["wsHeading"] ?? controls["wsFontFamily"], let last = controls["envNote"], let hwnd {
            var a = RECT(), b = RECT()
            GetWindowRect(first, &a)
            GetWindowRect(last, &b)
            var topLeft = POINT(x: a.left, y: a.top), bottomRight = POINT(x: b.right, y: b.bottom)
            ScreenToClient(hwnd, &topLeft)
            ScreenToClient(hwnd, &bottomRight)
            let frame = CGRect(x: margin, y: CGFloat(topLeft.y) / s, width: labelWidth + fieldWidth + margin,
                               height: CGFloat(bottomRight.y - topLeft.y) / s)
            if let json = makeControl("EDIT", "", style: Win.WS_TABSTOP | 0x0004 | 0x1000 | 0x0040 | Win.WS_VSCROLL | Win.WS_HSCROLL | 0x0080,
                                      exStyle: Win.WS_EX_CLIENTEDGE, frame: frame, id: 900, mono: true) {
                registerExtra("json", json)
                ShowWindow(json, Win.SW_HIDE)
            }
        }
        return true
    }

    private var extra: [String: HWND] = [:]
    private func registerExtra(_ key: String, _ h: HWND) { extra[key] = h }

    private func jsonText() -> String {
        guard let h = extra["json"] else { return "" }
        let n = Int(GetWindowTextLengthW(h))
        var buffer = [WCHAR](repeating: 0, count: n + 1)
        GetWindowTextW(h, &buffer, Int32(buffer.count))
        return String(wideBuffer: buffer).replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func setJSON(_ text: String) {
        guard let h = extra["json"] else { return }
        _ = withWide(text.replacingOccurrences(of: "\n", with: "\r\n")) { SetWindowTextW(h, $0) }
    }

    private func status(_ message: String) {
        setText("status", message)
    }

    // MARK: Document ↔ form

    private static func render(_ vars: [WorkspaceDocument.Variable]) -> String {
        vars.map { $0.secret ? "secret \($0.name)" : "\($0.name)=\($0.value ?? "")" }.joined(separator: "\n")
    }

    private func parseVariables(_ text: String, previous: [WorkspaceDocument.Variable], owner: String) throws -> [WorkspaceDocument.Variable] {
        let prev = previous.map { EnvVar(name: $0.name, value: $0.value ?? "", secret: $0.secret, secretRef: $0.ref) }
        let parsed = try EnvText.parse(text, previous: prev, owner: owner)
        created += parsed.created
        return parsed.vars.map { WorkspaceDocument.Variable(name: $0.name, value: $0.secret ? nil : $0.value, secret: $0.secret, ref: $0.secretRef) }
    }

    private func wrapIndex(_ b: Bool?) -> Int { b.map { $0 ? 1 : 2 } ?? 0 }
    private func wrapValue(_ i: Int) -> Bool? { i == 1 ? true : i == 2 ? false : nil }

    private func loadForm() {
        let ws = document.workspace
        setText("wsFontFamily", ws.fontFamily ?? "")
        setText("wsFontSize", OptionalNumber.render(ws.fontSize))
        setText("wsPadding", OptionalNumber.render(ws.padding))
        setSelection("wsWrap", wrapIndex(ws.lineWrap))
        setText("wsKept", ws.restoredOutputLines.map(String.init) ?? "")
        setText("wsEnv", Self.render(ws.env))
        selected = min(max(selected, 0), max(document.terminals.count - 1, 0))
        setOptions("terminal", document.terminals.enumerated().map { "\($0.offset + 1). \($0.element.displayName)" }, selected: selected)
        loadTerminal()
        updateViewVisibility()
    }

    private func loadTerminal() {
        guard document.terminals.indices.contains(selected) else { return }
        let t = document.terminals[selected]
        setText("tName", t.name ?? "")
        setText("tCwd", t.cwd ?? "")
        setSelection("tEnvironment", (t.environment.flatMap { id in environments.firstIndex { $0.id == id } } ?? -1) + 1)
        setText("tCommands", t.startupCommands.joined(separator: "\n"))
        setChecked("tReopen", t.runCommandsOnReopen)
        setChecked("tHistory", t.isolatedHistory)
        setText("tFontFamily", t.fontFamily ?? "")
        setText("tFontSize", OptionalNumber.render(t.fontSize))
        setText("tPadding", OptionalNumber.render(t.padding))
        setSelection("tWrap", wrapIndex(t.lineWrap))
        setText("tEnv", Self.render(t.env))
        setEnabled("remove", document.terminals.count > 1)
    }

    /// Reads the form into `document`. Throws with a message naming the field.
    private func storeForm() throws {
        var ws = document.workspace
        let family = text("wsFontFamily").trimmingCharacters(in: .whitespaces)
        ws.fontFamily = family.isEmpty ? nil : family
        ws.fontSize = try OptionalNumber.parse(text("wsFontSize"), range: TermsieConfig.minFontSize...TermsieConfig.maxFontSize,
                                               label: "Workspace font size")
        ws.padding = try OptionalNumber.parse(text("wsPadding"), range: 0...TermsieConfig.maxPadding, label: "Workspace padding")
        ws.lineWrap = wrapValue(selection("wsWrap"))
        ws.restoredOutputLines = try OptionalNumber.parse(text("wsKept"), range: 0...Double(TermsieConfig.maxRestoredOutputLines),
                                                          label: "Output kept").map { Int($0) }
        ws.env = try parseVariables(text("wsEnv"), previous: document.workspace.env, owner: "workspace")
        document.workspace = ws
        try storeTerminal()
    }

    private func storeTerminal() throws {
        guard document.terminals.indices.contains(selected) else { return }
        var t = document.terminals[selected]
        let name = text("tName").trimmingCharacters(in: .whitespaces)
        t.name = name.isEmpty ? nil : name
        let cwd = text("tCwd").trimmingCharacters(in: .whitespaces)
        t.cwd = cwd.isEmpty ? nil : cwd
        let envIndex = selection("tEnvironment")
        t.environment = envIndex > 0 && envIndex - 1 < environments.count ? environments[envIndex - 1].id : nil
        t.startupCommands = text("tCommands").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        t.runCommandsOnReopen = checked("tReopen")
        t.isolatedHistory = checked("tHistory")
        let family = text("tFontFamily").trimmingCharacters(in: .whitespaces)
        t.fontFamily = family.isEmpty ? nil : family
        t.fontSize = try OptionalNumber.parse(text("tFontSize"), range: TermsieConfig.minFontSize...TermsieConfig.maxFontSize,
                                              label: "Font size of \(t.displayName)")
        t.padding = try OptionalNumber.parse(text("tPadding"), range: 0...TermsieConfig.maxPadding, label: "Padding of \(t.displayName)")
        t.lineWrap = wrapValue(selection("tWrap"))
        t.env = try parseVariables(text("tEnv"), previous: t.env, owner: t.displayName)
        document.terminals[selected] = t
    }

    /// The document as the current view describes it.
    private func currentDocument() throws -> WorkspaceDocument {
        if showingJSON {
            var doc = try WorkspaceDocument(jsonText: jsonText())
            doc.adoptSecretRefs(from: document)
            return doc
        }
        try storeForm()
        return document
    }

    private var isDirty: Bool {
        guard built, let current = try? peekDocument() else { return document != baseline }
        return current != baseline
    }

    /// Like `currentDocument` but without storing new secrets, for the dirty check.
    private func peekDocument() throws -> WorkspaceDocument {
        showingJSON ? try WorkspaceDocument(jsonText: jsonText()) : document
    }

    private func updateViewVisibility() {
        for key in Self.formKeys { setVisible(key, !showingJSON) }
        if let json = extra["json"] { ShowWindow(json, showingJSON ? Win.SW_SHOW : Win.SW_HIDE) }
        setSelection("view", showingJSON ? 1 : 0)
    }

    // MARK: Events

    override func selectionChanged(_ key: String) {
        switch key {
        case "view":
            let wantJSON = selection("view") == 1
            guard wantJSON != showingJSON else { return }
            do {
                if wantJSON {
                    try storeForm()
                    var doc = document
                    created += doc.stashSecrets()
                    document = doc
                    setJSON(doc.jsonText())
                } else {
                    var doc = try WorkspaceDocument(jsonText: jsonText())
                    doc.adoptSecretRefs(from: document)
                    created += doc.stashSecrets()
                    document = doc
                    loadForm()
                }
                showingJSON = wantJSON
                status("")
                updateViewVisibility()
            } catch {
                setSelection("view", showingJSON ? 1 : 0)
                status(error.localizedDescription)
            }
        case "terminal":
            let next = selection("terminal")
            guard next != selected else { return }
            do {
                try storeTerminal()
                selected = next
                loadTerminal()
                status("")
            } catch {
                setSelection("terminal", selected)
                status(error.localizedDescription)
            }
        default:
            break
        }
    }

    override func accessoryPressed(_ key: String) {
        switch key {
        case "tCwd":
            let start = HomePath.expand(text("tCwd"))
            if let folder = FileDialog.folder(owner: hwnd, title: "Working Folder", start: start.isEmpty ? HomePath.home : start) {
                setText("tCwd", HomePath.abbreviate(folder))
            }
        case "add":
            do {
                try storeTerminal()
                document.terminals.append(WorkspaceDocument.Terminal(id: TerminalDefinition.newID()))
                selected = document.terminals.count - 1
                loadForm()
                focus("tName")
            } catch {
                status(error.localizedDescription)
            }
        case "remove":
            guard document.terminals.count > 1, document.terminals.indices.contains(selected) else { Shell.beep(); return }
            document.terminals.remove(at: selected)
            selected = max(0, selected - 1)
            loadForm()
        default:
            break
        }
    }

    override func buttonPressed(_ id: Int32) {
        switch id {
        case WorkspaceSettingsWindow.applyID, Win.IDOK:
            _ = apply()
        case WorkspaceSettingsWindow.revertID:
            revert()
        default:
            closeRequested()
        }
    }

    @discardableResult
    private func apply() -> Bool {
        guard let tab else { return false }
        do {
            var doc = try currentDocument()
            let problems = doc.problems(environments: ConfigStore.shared.config.environments.map(\.id))
            if let first = problems.first {
                status(first)
                return false
            }
            let removed = tab.terminalsRemoved(by: doc)
            if !removed.isEmpty {
                let names = removed.map { "“\($0)”" }.joined(separator: ", ")
                guard Alert.confirm("Delete \(removed.count == 1 ? "a terminal" : "\(removed.count) terminals")?",
                                    "Applying deletes \(names), with its settings.", owner: hwnd, warning: true) else { return false }
            }
            created += doc.stashSecrets()
            tab.apply(doc)
            baseline = tab.workspaceDocument
            document = baseline
            created = []
            if showingJSON { setJSON(document.jsonText()) } else { loadForm() }
            status("Applied.")
            return true
        } catch {
            status(error.localizedDescription)
            return false
        }
    }

    private func revert() {
        guard let tab else { return }
        SecretStore.discard(created)
        created = []
        baseline = tab.workspaceDocument
        document = baseline
        if showingJSON { setJSON(document.jsonText()) } else { loadForm() }
        status("Reverted.")
    }

    override func closeRequested() {
        if isDirty {
            switch Alert.yesNoCancel("Apply your changes to the workspace?", "Yes applies them, No throws them away.", owner: hwnd) {
            case .first: guard apply() else { return }
            case .second: SecretStore.discard(created); created = []
            case .third: return
            }
        }
        if let hwnd { ShowWindow(hwnd, Win.SW_HIDE) }
        if let owner = mainWindow?.hwnd { SetForegroundWindow(owner) }
    }

    /// The tab changed on its own (a drag, a rename): show it, unless there are edits pending.
    func workspaceDidChange() {
        guard built, let tab, let hwnd, IsWindowVisible(hwnd), !isDirty else { return }
        baseline = tab.workspaceDocument
        document = baseline
        if showingJSON { setJSON(document.jsonText()) } else { loadForm() }
    }

    func discardAndClose() {
        SecretStore.discard(created)
        created = []
        closeModeless()
    }

    // For the headless tests.
    func applyJSONForTesting(_ text: String) -> String {
        if !showingJSON {
            showingJSON = true
            updateViewVisibility()
        }
        setJSON(text)
        return apply() ? "applied" : "refused: \(self.text("status"))"
    }

    var jsonForTesting: String {
        (try? currentDocument().jsonText()) ?? document.jsonText()
    }
}
