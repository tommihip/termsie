import AppKit

/// One place to configure a whole workspace: the defaults its terminals share, and each
/// terminal's folder, startup commands, environment variables and looks.
///
/// Two views of the same `WorkspaceDocument`: a form, and the document as JSON for editing by
/// hand or by a tool. Edits collect in a draft and reach the tab only on Apply, because the JSON
/// view can only be applied whole, and the form should not behave differently from it.
///
/// A secret typed into either view goes to the Keychain as soon as it leaves the field that
/// holds it (on switching views, or on Apply) and is never rendered back as text.
final class WorkspaceSettingsWindowController: NSWindowController, NSWindowDelegate,
                                               NSTableViewDataSource, NSTableViewDelegate {
    private enum Mode: Int { case form = 0, json = 1 }
    private enum Scope: Equatable { case workspace, terminal(Int) }

    private weak var controller: TerminalWindowController?

    /// The document as the tab last had it, and the one being edited.
    private var baseline = WorkspaceDocument()
    private var draft = WorkspaceDocument()
    private var baselineJSON = ""
    /// Keychain items stashed from this draft, offered for clean-up once it is applied or dropped.
    private var createdRefs: [String] = []
    private var mode = Mode.form
    /// Row in the list: 0 is the workspace defaults, then one per terminal.
    private var selectedRow = 0
    private var isApplying = false

    private let modeControl = NSSegmentedControl(labels: ["Form", "JSON"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let formView = NSView()
    private let jsonScroll = NSScrollView()
    private let jsonView = NSTextView()
    private let list = NSTableView()
    private let listScroll = NSScrollView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let detailScroll = NSScrollView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let globalButton = NSButton(title: "Global Settings…", target: nil, action: nil)
    /// Closures behind the detail form's controls. Rebuilt with it.
    private var handlers: [Handler] = []

    init(controller: TerminalWindowController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        reloadFromWorkspace()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(selecting id: String?) {
        if let id, let index = draft.terminals.firstIndex(where: { $0.id == id }) {
            select(row: index + 1)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Build

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let b = content.bounds

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        modeControl.sizeToFit()
        modeControl.frame.origin = NSPoint(x: (b.width - modeControl.frame.width) / 2, y: b.height - 40)
        modeControl.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.addSubview(modeControl)

        let middle = NSRect(x: 16, y: 56, width: b.width - 32, height: b.height - 108)

        // Form: the list of the workspace and its terminals, beside the selected one's settings.
        formView.frame = middle
        formView.autoresizingMask = [.width, .height]
        content.addSubview(formView)

        listScroll.frame = NSRect(x: 0, y: 30, width: 210, height: middle.height - 30)
        listScroll.autoresizingMask = [.height]
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 200
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 22
        list.dataSource = self
        list.delegate = self
        listScroll.documentView = list
        formView.addSubview(listScroll)

        for (button, symbol, action) in [(addButton, "plus", #selector(addTerminal)),
                                         (removeButton, "minus", #selector(removeTerminal))] {
            button.bezelStyle = .smallSquare
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "plus" ? "Add terminal" : "Remove terminal")
            button.target = self
            button.action = action
            formView.addSubview(button)
        }
        addButton.frame = NSRect(x: 0, y: 0, width: 28, height: 24)
        removeButton.frame = NSRect(x: 27, y: 0, width: 28, height: 24)
        addButton.toolTip = "Add a terminal"
        removeButton.toolTip = "Remove the selected terminal"

        detailScroll.frame = NSRect(x: 222, y: 0, width: middle.width - 222, height: middle.height)
        detailScroll.autoresizingMask = [.width, .height]
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        formView.addSubview(detailScroll)

        // JSON: the same document as text.
        jsonScroll.frame = middle
        jsonScroll.autoresizingMask = [.width, .height]
        jsonScroll.hasVerticalScroller = true
        jsonScroll.borderType = .bezelBorder
        jsonView.font = UIFonts.monospaced(size: 12, weight: .regular)
        jsonView.isRichText = false
        jsonView.allowsUndo = true
        jsonView.isAutomaticQuoteSubstitutionEnabled = false
        jsonView.isAutomaticDashSubstitutionEnabled = false
        jsonView.isAutomaticTextReplacementEnabled = false
        jsonView.isAutomaticSpellingCorrectionEnabled = false
        jsonView.isContinuousSpellCheckingEnabled = false
        jsonView.autoresizingMask = [.width]
        jsonView.isVerticallyResizable = true
        jsonView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        jsonView.textContainerInset = NSSize(width: 6, height: 6)
        jsonScroll.documentView = jsonView
        jsonScroll.isHidden = true
        content.addSubview(jsonScroll)
        let jsonHandler = Handler { [weak self] _ in self?.refreshButtons() }
        handlersJSON = jsonHandler
        jsonView.delegate = jsonHandler

        // Bottom bar.
        messageLabel.frame = NSRect(x: 16, y: 10, width: b.width - 420, height: 38)
        messageLabel.autoresizingMask = [.width]
        messageLabel.font = UIFonts.system(size: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        content.addSubview(messageLabel)

        var x = b.width - 16
        for (button, width, action) in [(applyButton, 90.0, #selector(applyChanges)),
                                        (revertButton, 90.0, #selector(revertChanges)),
                                        (globalButton, 140.0, #selector(openGlobalSettings))] {
            x -= width
            button.bezelStyle = .rounded
            button.frame = NSRect(x: x, y: 14, width: width, height: 28)
            button.autoresizingMask = [.minXMargin]
            button.target = self
            button.action = action
            content.addSubview(button)
            x -= 8
        }
        applyButton.keyEquivalent = "\r"
        applyButton.keyEquivalentModifierMask = [.command]
        globalButton.toolTip = "The app-wide font, colours and behaviour every workspace inherits."
    }

    private var handlersJSON: Handler?

    // MARK: Loading

    /// Re-reads the tab. Skipped while there are unapplied edits, so a drag in the canvas or a
    /// rename in the list never throws away what is being typed here.
    func workspaceDidChange() {
        guard !isApplying, let controller, !isDirty else { return }
        guard controller.workspaceDocument != baseline else { updateTitle(); return }
        reloadFromWorkspace()
    }

    private func reloadFromWorkspace() {
        guard let controller else { return }
        baseline = controller.workspaceDocument
        draft = baseline
        baselineJSON = baseline.jsonText()
        if mode == .json { jsonView.string = baselineJSON }
        list.reloadData()
        select(row: min(selectedRow, draft.terminals.count))
        updateTitle()
        refreshButtons()
    }

    private func updateTitle() {
        let name = controller?.workspaceName ?? "Untitled"
        window?.title = "Workspace Settings — \(name)"
    }

    private var isDirty: Bool {
        mode == .json ? jsonView.string != baselineJSON : draft != baseline
    }

    private func refreshButtons() {
        applyButton.isEnabled = isDirty
        revertButton.isEnabled = isDirty
        removeButton.isEnabled = mode == .form && selectedRow > 0 && draft.terminals.count > 1
    }

    private func draftChanged(reloadList: Bool = true) {
        if reloadList {
            list.reloadData()
            list.selectRowIndexes([selectedRow], byExtendingSelection: false)
        }
        refreshButtons()
    }

    private func showMessage(_ text: String, isError: Bool = false) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? NSColor.hex(ConfigStore.shared.config.colors.bell) : .secondaryLabelColor
    }

    // MARK: Modes

    @objc private func modeChanged() {
        let wanted = Mode(rawValue: modeControl.selectedSegment) ?? .form
        guard wanted != mode else { return }
        if wanted == .json {
            window?.makeFirstResponder(nil)
            createdRefs += draft.stashSecrets()
            jsonView.string = draft.jsonText()
        } else {
            guard parseJSON() else {
                modeControl.selectedSegment = Mode.json.rawValue
                return
            }
        }
        mode = wanted
        formView.isHidden = mode != .form
        jsonScroll.isHidden = mode != .json
        if mode == .form { list.reloadData(); select(row: min(selectedRow, draft.terminals.count)) }
        else { window?.makeFirstResponder(jsonView) }
        showMessage(mode == .json
            ? "null means inherit. Secrets show as \"secret\": true; add a \"value\" to set or replace one — it moves to the Keychain and is never shown again."
            : "")
        refreshButtons()
    }

    /// Reads the JSON view into the draft. False, with the reason shown, when it cannot.
    private func parseJSON() -> Bool {
        do {
            var doc = try WorkspaceDocument(jsonText: jsonView.string)
            doc.adoptSecretRefs(from: draft)
            createdRefs += doc.stashSecrets()
            draft = doc
            return true
        } catch {
            showMessage(error.localizedDescription, isError: true)
            return false
        }
    }

    // MARK: Apply / revert

    @objc private func applyChanges() {
        window?.makeFirstResponder(nil)
        guard let removed = prepareApply() else { return }
        guard !removed.isEmpty, let window, !DebugDriver.isActive else { commit(); return }
        let alert = NSAlert()
        alert.messageText = removed.count == 1
            ? "Delete the terminal “\(removed[0])”?"
            : "Delete \(removed.count) terminals?"
        alert.informativeText = (removed.count == 1 ? "" : removed.joined(separator: ", ") + "\n\n")
            + "They are no longer in the workspace settings. Running processes in them will be terminated."
        alert.addButton(withTitle: "Delete and Apply")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.commit() }
        }
    }

    /// Parses and validates the draft. Returns the terminals applying would delete, or nil —
    /// with the reason shown — when it cannot be applied.
    private func prepareApply() -> [String]? {
        if mode == .json, !parseJSON() { return nil }
        createdRefs += draft.stashSecrets()
        let problems = draft.problems(environments: ConfigStore.shared.config.environments.map(\.id))
        guard problems.isEmpty else {
            showMessage(problems.prefix(3).joined(separator: "\n"), isError: true)
            return nil
        }
        return controller?.terminalsRemoved(by: draft) ?? []
    }

    private func commit() {
        guard let controller else { return }
        isApplying = true
        controller.apply(draft)
        isApplying = false
        SecretStore.discard(createdRefs)
        createdRefs = []
        let hadRunning = controller.registry.openCount > 0
        reloadFromWorkspace()
        if mode == .json { jsonView.string = baselineJSON }
        refreshButtons()
        showMessage(hadRunning ? "Applied. Changed variables reach a running terminal the next time it starts." : "Applied.")
    }

    @objc private func revertChanges() {
        SecretStore.discard(createdRefs)
        createdRefs = []
        draft = baseline
        jsonView.string = baselineJSON
        showMessage("")
        list.reloadData()
        select(row: min(selectedRow, draft.terminals.count))
        refreshButtons()
    }

    /// Closes without asking, dropping unapplied edits — for when the tab itself is closing.
    func discardAndClose() {
        revertChanges()
        close()
    }

    @objc private func openGlobalSettings() {
        SettingsWindowController.shared.show()
    }

    /// Applies JSON as the JSON view would, for headless tests. Returns "ok" or the problem.
    func applyJSONForTesting(_ text: String) -> String {
        if mode != .json {
            modeControl.selectedSegment = Mode.json.rawValue
            modeChanged()
        }
        jsonView.string = text
        guard prepareApply() != nil else { return messageLabel.stringValue }
        commit()
        return "ok"
    }

    /// The JSON view's text after switching to it, for tests.
    func renderedJSONForTesting() -> String {
        if mode != .json {
            modeControl.selectedSegment = Mode.json.rawValue
            modeChanged()
        }
        return jsonView.string
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.makeFirstResponder(nil)
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Apply your changes to the workspace?"
        alert.informativeText = "They are lost otherwise."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard self.prepareApply() != nil else { return }
                self.commit()
                sender.close()
            case .alertSecondButtonReturn:
                self.revertChanges()
                sender.close()
            default: break
            }
        }
        return false
    }

    // MARK: List

    func numberOfRows(in tableView: NSTableView) -> Int { draft.terminals.count + 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        if row == 0 {
            cell.stringValue = "Workspace defaults"
            cell.font = UIFonts.system(size: 12, weight: .semibold)
        } else {
            let t = draft.terminals[row - 1]
            let vars = t.env.count
            cell.stringValue = "\(row). \(t.displayName)" + (vars > 0 ? "  ·  \(vars) var\(vars == 1 ? "" : "s")" : "")
            cell.font = UIFonts.system(size: 12)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = list.selectedRow
        guard row >= 0, row != selectedRow else { return }
        window?.makeFirstResponder(nil)
        selectedRow = row
        buildDetail()
        refreshButtons()
    }

    private func select(row: Int) {
        selectedRow = max(0, row)
        list.selectRowIndexes([selectedRow], byExtendingSelection: false)
        buildDetail()
        refreshButtons()
    }

    @objc private func addTerminal() {
        window?.makeFirstResponder(nil)
        draft.terminals.append(WorkspaceDocument.Terminal(id: TerminalDefinition.newID()))
        list.reloadData()
        select(row: draft.terminals.count)
    }

    @objc private func removeTerminal() {
        guard selectedRow > 0, draft.terminals.count > 1 else { return }
        window?.makeFirstResponder(nil)
        draft.terminals.remove(at: selectedRow - 1)
        list.reloadData()
        select(row: min(selectedRow, draft.terminals.count))
    }

    // MARK: Detail form

    private func buildDetail() {
        handlers = []
        let width = max(detailScroll.contentSize.width, 480)
        let form = DetailForm(frame: NSRect(x: 0, y: 0, width: width, height: 100), owner: self)
        if selectedRow == 0 || selectedRow > draft.terminals.count {
            buildWorkspaceDetail(form)
        } else {
            buildTerminalDetail(form, index: selectedRow - 1)
        }
        form.finish()
        detailScroll.documentView = form
        form.scroll(.zero)
    }

    private func buildWorkspaceDetail(_ f: DetailForm) {
        let config = ConfigStore.shared.config
        f.heading("Workspace defaults",
                  "Every terminal in this workspace uses these unless it sets its own. Empty means the global setting.")
        f.section("Text")
        f.fontRow(family: draft.workspace.fontFamily, size: draft.workspace.fontSize,
                  inheritedFamily: "Global (\(config.font.family))",
                  inheritedSize: config.font.size) { [unowned self] family, size in
            draft.workspace.fontFamily = family
            draft.workspace.fontSize = size
            draftChanged(reloadList: false)
        }
        f.layoutRow(wrap: draft.workspace.lineWrap, padding: draft.workspace.padding,
                    inheritedWrap: "Global (\(config.lineWrap ? "wrap" : "no wrap"))",
                    inheritedPadding: config.terminalPadding) { [unowned self] wrap, padding in
            draft.workspace.lineWrap = wrap
            draft.workspace.padding = padding
            draftChanged(reloadList: false)
        }
        f.section("Output")
        f.integerRow("Keep", draft.workspace.restoredOutputLines, placeholder: "\(config.restoredOutputLines)",
                     unit: "lines", range: 0...TermsieConfig.maxRestoredOutputLines) { [unowned self] v in
            draft.workspace.restoredOutputLines = v
            draftChanged(reloadList: false)
        }
        f.hint("The last lines of each terminal's output, shown again when it reopens — after closing the terminal, the workspace, or Termsie. 0 keeps nothing. Empty uses the global setting.")
        f.section("Environment variables")
        f.hint("Set in every terminal of the workspace when its shell starts, whether or not its startup commands run. A terminal's own variable of the same name wins.")
        buildEnvRows(f, scope: .workspace)
    }

    private func buildTerminalDetail(_ f: DetailForm, index i: Int) {
        let config = ConfigStore.shared.config
        let t = draft.terminals[i]
        f.heading("Terminal \(i + 1)", nil)
        f.textRow("Name", t.name, placeholder: "from the running process") { [unowned self] v in
            draft.terminals[i].name = v
            draftChanged()
        }
        f.folderRow(t.cwd) { [unowned self] v in
            draft.terminals[i].cwd = v
            draftChanged()
        }
        var envItems: [(String, String?)] = [("None", nil)]
        envItems += config.environments.map { ($0.label, Optional($0.id)) }
        f.popupRow("Environment", items: envItems, selected: t.environment) { [unowned self] v in
            draft.terminals[i].environment = v
            draftChanged(reloadList: false)
        }

        f.section("Starting up")
        f.commandsRow(t.startupCommands) { [unowned self] v in
            draft.terminals[i].startupCommands = v
            draftChanged(reloadList: false)
        }
        f.checkRow("Run commands when reopening", t.runCommandsOnReopen) { [unowned self] v in
            draft.terminals[i].runCommandsOnReopen = v
            draftChanged(reloadList: false)
        }
        f.checkRow("Own command history", t.isolatedHistory) { [unowned self] v in
            draft.terminals[i].isolatedHistory = v
            draftChanged(reloadList: false)
        }

        f.section("Environment variables")
        f.hint("Set when this terminal's shell starts, whether or not the startup commands run. Secrets are kept in your Keychain, never in the workspace file.")
        if !draft.workspace.env.isEmpty {
            f.hint("Inherited from the workspace: " + draft.workspace.env.map(\.name).joined(separator: ", "))
        }
        buildEnvRows(f, scope: .terminal(i))

        f.section("Text")
        let ws = draft.workspace
        let family = ws.fontFamily.map { "Workspace (\($0))" } ?? "Global (\(config.font.family))"
        f.fontRow(family: t.fontFamily, size: t.fontSize, inheritedFamily: family,
                  inheritedSize: ws.fontSize ?? config.font.size) { [unowned self] family, size in
            draft.terminals[i].fontFamily = family
            draft.terminals[i].fontSize = size
            draftChanged(reloadList: false)
        }
        let wrapSource = ws.lineWrap != nil ? "Workspace" : "Global"
        let wrapValue = ws.lineWrap ?? config.lineWrap
        f.layoutRow(wrap: t.lineWrap, padding: t.padding,
                    inheritedWrap: "\(wrapSource) (\(wrapValue ? "wrap" : "no wrap"))",
                    inheritedPadding: ws.padding ?? config.terminalPadding) { [unowned self] wrap, padding in
            draft.terminals[i].lineWrap = wrap
            draft.terminals[i].padding = padding
            draftChanged(reloadList: false)
        }
    }

    private func envList(_ scope: Scope) -> [WorkspaceDocument.Variable] {
        switch scope {
        case .workspace: return draft.workspace.env
        case .terminal(let i): return draft.terminals[i].env
        }
    }

    private func setEnvList(_ scope: Scope, _ list: [WorkspaceDocument.Variable]) {
        switch scope {
        case .workspace: draft.workspace.env = list
        case .terminal(let i): draft.terminals[i].env = list
        }
    }

    private func buildEnvRows(_ f: DetailForm, scope: Scope) {
        let vars = envList(scope)
        for (j, v) in vars.enumerated() {
            f.envRow(v, onName: { [unowned self] name in
                var list = envList(scope); list[j].name = name; setEnvList(scope, list)
                draftChanged()
            }, onValue: { [unowned self] value in
                var list = envList(scope)
                // For a secret, an empty field means "keep what is stored".
                list[j].value = list[j].secret && value.isEmpty ? nil : value
                setEnvList(scope, list)
                draftChanged(reloadList: false)
            }, onSecret: { [unowned self] secret in
                window?.makeFirstResponder(nil)
                var list = envList(scope)
                if secret {
                    // What was typed as plain text becomes the secret's value.
                    let typed = list[j].value ?? ""
                    list[j].value = typed.isEmpty ? nil : typed
                } else {
                    // Never reveal a stored secret by unticking the box: start from empty.
                    list[j].value = ""
                    list[j].ref = nil
                }
                list[j].secret = secret
                setEnvList(scope, list)
                draftChanged(reloadList: false)
                buildDetail()
            }, onRemove: { [unowned self] in
                window?.makeFirstResponder(nil)
                var list = envList(scope); list.remove(at: j); setEnvList(scope, list)
                draftChanged()
                buildDetail()
            })
        }
        f.addVariableButton { [unowned self] in
            window?.makeFirstResponder(nil)
            var list = envList(scope)
            list.append(.init(name: "", value: "", secret: false))
            setEnvList(scope, list)
            draftChanged()
            buildDetail()
        }
    }

    fileprivate func retain(_ handler: Handler) { handlers.append(handler) }
}

// MARK: - Form building

/// Target/delegate glue so each control can carry a closure.
final class Handler: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    let onChange: (Any) -> Void
    init(_ onChange: @escaping (Any) -> Void) { self.onChange = onChange }
    @objc func fire(_ sender: Any) { onChange(sender) }
    func controlTextDidChange(_ obj: Notification) { if let o = obj.object { onChange(o) } }
    func textDidChange(_ notification: Notification) { if let o = notification.object { onChange(o) } }
}

/// A top-down form, laid out as it is built: label column on the left, controls on the right.
private final class DetailForm: NSView {
    private unowned let owner: WorkspaceSettingsWindowController
    private var y: CGFloat = 16
    private let margin: CGFloat = 16
    private let labelWidth: CGFloat = 116
    private var controlX: CGFloat { margin + labelWidth + 8 }
    private var controlWidth: CGFloat { bounds.width - controlX - margin }

    override var isFlipped: Bool { true }

    init(frame: NSRect, owner: WorkspaceSettingsWindowController) {
        self.owner = owner
        super.init(frame: frame)
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func finish() { frame.size.height = y + 16 }

    private func handler(_ body: @escaping (Any) -> Void) -> Handler {
        let h = Handler(body)
        owner.retain(h)
        return h
    }

    private func rowLabel(_ text: String) {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: margin, y: y + 3, width: labelWidth, height: 18)
        addSubview(l)
    }

    func heading(_ title: String, _ subtitle: String?) {
        let l = NSTextField(labelWithString: title)
        l.font = UIFonts.system(size: 15, weight: .semibold)
        l.frame = NSRect(x: margin, y: y, width: bounds.width - 2 * margin, height: 20)
        addSubview(l)
        y += 26
        if let subtitle { hint(subtitle, indent: false) }
    }

    func section(_ title: String) {
        y += 8
        let l = NSTextField(labelWithString: title.uppercased())
        l.font = UIFonts.system(size: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        l.frame = NSRect(x: margin, y: y, width: bounds.width - 2 * margin, height: 14)
        addSubview(l)
        let line = NSBox(frame: NSRect(x: margin, y: y + 17, width: bounds.width - 2 * margin, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width]
        addSubview(line)
        y += 26
    }

    func hint(_ text: String, indent: Bool = true) {
        let x = indent ? controlX : margin
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = UIFonts.system(size: 11)
        l.textColor = .tertiaryLabelColor
        let w = bounds.width - x - margin
        l.frame = NSRect(x: x, y: y, width: w, height: 0)
        l.frame.size.height = l.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude)).height
        addSubview(l)
        y += l.frame.height + 8
    }

    private func field(_ value: String?, placeholder: String, x: CGFloat, width: CGFloat,
                       secure: Bool = false, onChange: @escaping (String) -> Void) -> NSTextField {
        let f = secure ? NSSecureTextField() : NSTextField()
        f.stringValue = value ?? ""
        f.placeholderString = placeholder
        f.frame = NSRect(x: x, y: y + 1, width: width, height: 22)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.delegate = handler { [weak f] _ in if let f { onChange(f.stringValue) } }
        addSubview(f)
        return f
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    func textRow(_ label: String, _ value: String?, placeholder: String, onChange: @escaping (String?) -> Void) {
        rowLabel(label)
        _ = field(value, placeholder: placeholder, x: controlX, width: controlWidth) { onChange(Self.trimmed($0)) }
        y += 30
    }

    /// A whole number with a unit after it. Empty inherits; out-of-range input is clamped.
    func integerRow(_ label: String, _ value: Int?, placeholder: String, unit text: String,
                    range: ClosedRange<Int>, onChange: @escaping (Int?) -> Void) {
        rowLabel(label)
        let f = field(value.map(String.init), placeholder: placeholder, x: controlX, width: 80) { raw in
            onChange(Int(raw.trimmingCharacters(in: .whitespaces)).map { min(max($0, range.lowerBound), range.upperBound) })
        }
        f.alignment = .right
        unit(text, after: f)
        y += 30
    }

    func folderRow(_ value: String?, onChange: @escaping (String?) -> Void) {
        rowLabel("Folder")
        let f = field(value, placeholder: "~", x: controlX, width: controlWidth - 90) { onChange(Self.trimmed($0)) }
        let choose = NSButton(title: "Choose…", target: nil, action: nil)
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: controlX + controlWidth - 84, y: y, width: 84, height: 24)
        let h = handler { [weak f] _ in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            if let current = f.flatMap({ Self.trimmed($0.stringValue) }) {
                panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let path = ProcessInspector.abbreviateHome(url.path)
            f?.stringValue = path
            onChange(path)
        }
        choose.target = h
        choose.action = #selector(Handler.fire(_:))
        addSubview(choose)
        y += 30
    }

    func popupRow(_ label: String, items: [(String, String?)], selected: String?,
                  onChange: @escaping (String?) -> Void) {
        rowLabel(label)
        let p = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: min(controlWidth, 260), height: 24), pullsDown: false)
        for (title, value) in items {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = value ?? ""
            p.menu?.addItem(item)
        }
        p.selectItem(at: items.firstIndex { $0.1 == selected } ?? 0)
        let h = handler { [weak p] _ in
            let v = p?.selectedItem?.representedObject as? String
            onChange((v?.isEmpty ?? true) ? nil : v)
        }
        p.target = h
        p.action = #selector(Handler.fire(_:))
        addSubview(p)
        y += 30
    }

    func checkRow(_ title: String, _ value: Bool, onChange: @escaping (Bool) -> Void) {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = value ? .on : .off
        b.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        let h = handler { [weak b] _ in onChange(b?.state == .on) }
        b.target = h
        b.action = #selector(Handler.fire(_:))
        addSubview(b)
        y += 24
    }

    func commandsRow(_ value: [String], onChange: @escaping ([String]) -> Void) {
        rowLabel("Commands")
        let scroll = NSScrollView(frame: NSRect(x: controlX, y: y, width: controlWidth, height: 96))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.font = UIFonts.monospaced(size: 11, weight: .regular)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.string = value.joined(separator: "\n")
        tv.delegate = handler { [weak tv] _ in
            guard let tv else { return }
            onChange(tv.string.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        scroll.documentView = tv
        addSubview(scroll)
        y += 100
        hint("One per line, run in order when the terminal opens. Lines starting with # are skipped.")
    }

    /// Font family and size on one row. Empty or "inherit" values mean follow the level above.
    func fontRow(family: String?, size: Double?, inheritedFamily: String, inheritedSize: Double,
                 onChange: @escaping (String?, Double?) -> Void) {
        rowLabel("Font")
        let p = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: min(controlWidth - 70, 260), height: 24), pullsDown: false)
        let inherit = NSMenuItem(title: inheritedFamily, action: nil, keyEquivalent: "")
        inherit.representedObject = ""
        p.menu?.addItem(inherit)
        p.menu?.addItem(.separator())
        for name in FontCatalog.families(including: family) { p.menu?.addItem(FontCatalog.menuItem(for: name)) }
        if let family, !family.isEmpty { p.selectItem(withTitle: family) } else { p.selectItem(at: 0) }
        addSubview(p)
        var currentFamily = family
        var currentSize = size
        let sizeField = field(size.map { String(format: "%g", $0) }, placeholder: String(format: "%g", inheritedSize),
                              x: p.frame.maxX + 8, width: 50) { text in
            currentSize = Double(text.trimmingCharacters(in: .whitespaces)).map {
                min(max($0, TermsieConfig.minFontSize), TermsieConfig.maxFontSize)
            }
            onChange(currentFamily, currentSize)
        }
        sizeField.alignment = .right
        sizeField.toolTip = "Point size. Empty inherits."
        unit("pt", after: sizeField)
        let h = handler { [weak p] _ in
            let v = p?.selectedItem?.representedObject as? String
            currentFamily = (v?.isEmpty ?? true) ? nil : v
            onChange(currentFamily, currentSize)
        }
        p.target = h
        p.action = #selector(Handler.fire(_:))
        y += 30
    }

    /// Line wrapping and padding on one row, the way the terminal settings popover pairs them.
    func layoutRow(wrap: Bool?, padding: Double?, inheritedWrap: String, inheritedPadding: Double,
                   onChange: @escaping (Bool?, Double?) -> Void) {
        rowLabel("Wrapping")
        let p = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: min(controlWidth - 70, 260), height: 24), pullsDown: false)
        for (title, tag) in [(inheritedWrap, 0), ("Wrap long lines", 1), ("Do not wrap", 2)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            p.menu?.addItem(item)
        }
        p.selectItem(withTag: wrap.map { $0 ? 1 : 2 } ?? 0)
        addSubview(p)
        var currentWrap = wrap
        var currentPadding = padding
        let padField = field(padding.map { String(format: "%g", $0) }, placeholder: String(format: "%g", inheritedPadding),
                             x: p.frame.maxX + 8, width: 50) { text in
            currentPadding = Double(text.trimmingCharacters(in: .whitespaces)).map {
                min(max($0, 0), TermsieConfig.maxPadding)
            }
            onChange(currentWrap, currentPadding)
        }
        padField.alignment = .right
        padField.toolTip = "Padding between the border and the text, in points. Empty inherits."
        unit("pt padding", after: padField)
        let h = handler { [weak p] _ in
            switch p?.selectedItem?.tag ?? 0 {
            case 1: currentWrap = true
            case 2: currentWrap = false
            default: currentWrap = nil
            }
            onChange(currentWrap, currentPadding)
        }
        p.target = h
        p.action = #selector(Handler.fire(_:))
        y += 30
    }

    private func unit(_ text: String, after view: NSView) {
        let l = NSTextField(labelWithString: text)
        l.font = UIFonts.system(size: 11)
        l.textColor = .tertiaryLabelColor
        l.frame = NSRect(x: view.frame.maxX + 6, y: y + 5, width: 90, height: 16)
        addSubview(l)
    }

    func envRow(_ v: WorkspaceDocument.Variable,
                onName: @escaping (String) -> Void, onValue: @escaping (String) -> Void,
                onSecret: @escaping (Bool) -> Void, onRemove: @escaping () -> Void) {
        let x = margin
        let total = bounds.width - 2 * margin
        let nameWidth: CGFloat = 170
        let secretWidth: CGFloat = 70
        let removeWidth: CGFloat = 24
        let valueWidth = total - nameWidth - secretWidth - removeWidth - 24

        let name = field(v.name, placeholder: "NAME", x: x, width: nameWidth) {
            onName($0.trimmingCharacters(in: .whitespaces))
        }
        name.font = UIFonts.monospaced(size: 11, weight: .regular)
        if !v.name.isEmpty, let problem = EnvVar.problem(withName: v.name) { name.toolTip = problem; name.textColor = .systemRed }

        let placeholder = v.secret
            ? (v.ref != nil ? "•••••••• in Keychain — type to replace" : "secret value")
            : "value"
        // A secret field starts empty: the stored value is never read back into the window.
        let value = field(v.secret ? nil : v.value, placeholder: placeholder,
                          x: x + nameWidth + 8, width: valueWidth, secure: v.secret, onChange: onValue)
        value.font = UIFonts.monospaced(size: 11, weight: .regular)

        let secret = NSButton(checkboxWithTitle: "Secret", target: nil, action: nil)
        secret.state = v.secret ? .on : .off
        secret.toolTip = "Keep the value in your Keychain instead of the workspace file, and never show it."
        secret.frame = NSRect(x: value.frame.maxX + 8, y: y + 2, width: secretWidth, height: 20)
        let hs = handler { [weak secret] _ in onSecret(secret?.state == .on) }
        secret.target = hs
        secret.action = #selector(Handler.fire(_:))
        addSubview(secret)

        let remove = NSButton()
        remove.bezelStyle = .inline
        remove.isBordered = false
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove variable")
        remove.frame = NSRect(x: secret.frame.maxX + 4, y: y + 1, width: removeWidth, height: 22)
        let hr = handler { _ in onRemove() }
        remove.target = hr
        remove.action = #selector(Handler.fire(_:))
        addSubview(remove)
        y += 28
    }

    func addVariableButton(_ action: @escaping () -> Void) {
        let b = NSButton(title: "Add Variable", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.frame = NSRect(x: margin, y: y, width: 130, height: 24)
        let h = handler { _ in action() }
        b.target = h
        b.action = #selector(Handler.fire(_:))
        addSubview(b)
        y += 32
    }
}
