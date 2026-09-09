import AppKit

/// The application settings window: the global font, and the environments a terminal can belong to.
///
/// Everything here writes straight through `ConfigStore.update`, which persists config.json and
/// posts the change notification, so open windows repaint immediately.
final class SettingsWindowController: NSWindowController, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private let tabs = NSTabView()
    private let generalForm = SettingsForm()
    private var configObserver: NSObjectProtocol?

    // Font tab
    private let fontPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let fontSample = NSTextField(labelWithString: "")

    // Environments tab
    private let table = NSTableView()
    private let nameField = NSTextField()
    private let colorWell = NSColorWell()
    private let tintCheck = NSButton(checkboxWithTitle: "Tint terminals", target: nil, action: nil)
    private let strengthSlider = NSSlider()
    private let strengthLabel = NSTextField(labelWithString: "")
    private let previewView = EnvironmentPreviewView()
    private let removeButton = NSButton()
    private var editorFields: [NSView] = []

    private var environments: [TermsieConfig.EnvironmentStyle] {
        get { ConfigStore.shared.config.environments }
        set { ConfigStore.shared.update { $0.environments = newValue } }
    }

    private var selected: Int? {
        table.selectedRow >= 0 && table.selectedRow < environments.count ? table.selectedRow : nil
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Termsie Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        configObserver = NotificationCenter.default.addObserver(
            forName: .termsieConfigChanged, object: nil, queue: .main) { [weak self] _ in
                self?.generalForm.refresh()
            }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        reloadAll()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Test hooks that drive the real controls.
    @discardableResult
    func clickGeneralSetting(_ title: String) -> Bool { generalForm.clickCheckbox(titled: title) }
    func generalSettingState(_ title: String) -> Bool? { generalForm.checkboxState(titled: title) }

    func showEnvironments() {
        show()
        // By identifier, so adding a tab ahead of it cannot send this to the wrong place.
        if let index = tabs.indexOfTabViewItem(withIdentifier: "environments") as Int?, index != NSNotFound {
            tabs.selectTabViewItem(at: index)
        }
    }

    // MARK: Build

    private func buildUI() {
        guard let content = window?.contentView else { return }
        tabs.frame = content.bounds.insetBy(dx: 12, dy: 12)
        tabs.autoresizingMask = [.width, .height]
        content.addSubview(tabs)

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = buildGeneralTab()
        tabs.addTabViewItem(generalTab)

        let fontTab = NSTabViewItem(identifier: "font")
        fontTab.label = "Font"
        fontTab.view = buildFontTab()
        tabs.addTabViewItem(fontTab)

        let envTab = NSTabViewItem(identifier: "environments")
        envTab.label = "Environments"
        envTab.view = buildEnvironmentsTab()
        tabs.addTabViewItem(envTab)
    }

    private func label(_ text: String, at y: CGFloat, in view: NSView, width: CGFloat = 200) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 16, y: y, width: width, height: 16)
        view.addSubview(l)
        return l
    }

    private func hint(_ text: String, at y: CGFloat, in view: NSView, width: CGFloat) {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.frame = NSRect(x: 16, y: y, width: width, height: 32)
        view.addSubview(l)
    }

    /// Global behaviour that is not about a single terminal. New settings go here as one
    /// `checkbox` call each.
    private func buildGeneralTab() -> NSView {
        generalForm.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        generalForm.autoresizingMask = [.width, .height]

        generalForm.section("Window")
        generalForm.checkbox("Resize terminals with the window", \.resizeTerminalsWithWindow,
                             hint: "Off keeps every terminal at its own size and position; they only slide back into view when the window becomes smaller than they are.")
        generalForm.checkbox("Snap terminal resizing to character cells", \.snapToCells,
                             hint: "Keeps a terminal a whole number of rows and columns while you drag its edge.")

        generalForm.section("Starting up")
        generalForm.checkbox("Reopen terminals from the last session", \.restoreSession)

        generalForm.section("Terminals")
        generalForm.checkbox("Show terminal headers", \.showPaneHeaders)
        generalForm.checkbox("Show window buttons on each terminal", \.trafficLights)
        generalForm.checkbox("Ask before closing a terminal that is running something",
                             \.confirmClosingRunningProcess)
        return generalForm
    }

    private func buildFontTab() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        var y: CGFloat = 320

        _ = label("Font", at: y, in: v)
        y -= 28
        fontPopUp.frame = NSRect(x: 16, y: y, width: 300, height: 26)
        fontPopUp.target = self
        fontPopUp.action = #selector(fontFamilyChanged)
        v.addSubview(fontPopUp)

        fontSizeField.frame = NSRect(x: 328, y: y + 2, width: 52, height: 22)
        fontSizeField.alignment = .right
        fontSizeField.delegate = self
        v.addSubview(fontSizeField)
        fontSizeStepper.frame = NSRect(x: 384, y: y, width: 19, height: 26)
        fontSizeStepper.minValue = TermsieConfig.minFontSize
        fontSizeStepper.maxValue = TermsieConfig.maxFontSize
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped)
        v.addSubview(fontSizeStepper)
        y -= 26

        hint("Only fixed-pitch fonts are listed, because a terminal draws on a character grid. Individual terminals can override this in their own settings.",
             at: y - 22, in: v, width: 480)
        y -= 74

        _ = label("Preview", at: y, in: v)
        y -= 96
        let box = NSView(frame: NSRect(x: 16, y: y, width: 488, height: 88))
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        fontSample.frame = NSRect(x: 12, y: 8, width: 464, height: 72)
        fontSample.maximumNumberOfLines = 4
        box.addSubview(fontSample)
        v.addSubview(box)
        return v
    }

    private func buildEnvironmentsTab() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))

        // Left: the list plus its add and remove buttons.
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 46, width: 200, height: 298))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("env"))
        column.width = 190
        table.addTableColumn(column)
        table.registerForDraggedTypes([.string])
        scroll.documentView = table
        v.addSubview(scroll)

        let add = NSButton(frame: NSRect(x: 16, y: 16, width: 28, height: 24))
        add.title = "+"
        add.bezelStyle = .rounded
        add.target = self
        add.action = #selector(addEnvironment)
        v.addSubview(add)

        removeButton.frame = NSRect(x: 46, y: 16, width: 28, height: 24)
        removeButton.title = "−"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeEnvironment)
        v.addSubview(removeButton)

        let orderHint = NSTextField(labelWithString: "Drag to reorder")
        orderHint.font = NSFont.systemFont(ofSize: 10)
        orderHint.textColor = .tertiaryLabelColor
        orderHint.frame = NSRect(x: 82, y: 20, width: 130, height: 16)
        v.addSubview(orderHint)

        // Right: the editor for whichever environment is selected.
        var y: CGFloat = 328
        let x: CGFloat = 232
        func sectionLabel(_ text: String) {
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: x, y: y, width: 260, height: 16)
            v.addSubview(l)
            editorFields.append(l)
            y -= 22
        }

        sectionLabel("Name")
        nameField.frame = NSRect(x: x, y: y, width: 272, height: 22)
        nameField.delegate = self
        v.addSubview(nameField)
        editorFields.append(nameField)
        y -= 34

        sectionLabel("Colour")
        colorWell.frame = NSRect(x: x, y: y - 4, width: 60, height: 26)
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        v.addSubview(colorWell)
        editorFields.append(colorWell)
        tintCheck.frame = NSRect(x: x + 72, y: y - 2, width: 210, height: 22)
        tintCheck.target = self
        tintCheck.action = #selector(tintToggled)
        v.addSubview(tintCheck)
        editorFields.append(tintCheck)
        y -= 40

        sectionLabel("Tint strength")
        strengthSlider.frame = NSRect(x: x, y: y - 2, width: 216, height: 22)
        strengthSlider.minValue = 0.05
        strengthSlider.maxValue = 0.6
        strengthSlider.target = self
        strengthSlider.action = #selector(strengthChanged)
        strengthSlider.isContinuous = true
        v.addSubview(strengthSlider)
        editorFields.append(strengthSlider)
        strengthLabel.frame = NSRect(x: x + 224, y: y - 2, width: 48, height: 20)
        strengthLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        strengthLabel.textColor = .secondaryLabelColor
        v.addSubview(strengthLabel)
        editorFields.append(strengthLabel)
        y -= 38

        sectionLabel("Preview")
        previewView.frame = NSRect(x: x, y: y - 92, width: 272, height: 96)
        v.addSubview(previewView)
        editorFields.append(previewView)
        return v
    }

    // MARK: Loading

    private func reloadAll() {
        generalForm.refresh()
        reloadFontTab()
        table.reloadData()
        if table.selectedRow < 0, !environments.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        reloadEditor()
    }

    private func reloadFontTab() {
        let config = ConfigStore.shared.config
        fontPopUp.menu?.removeAllItems()
        for family in FontCatalog.families(including: config.font.family) {
            fontPopUp.menu?.addItem(FontCatalog.menuItem(for: family))
        }
        fontPopUp.selectItem(withTitle: config.font.family)
        fontSizeField.stringValue = String(format: "%g", config.font.size)
        fontSizeStepper.doubleValue = config.font.size
        updateSample()
    }

    private func updateSample() {
        let config = ConfigStore.shared.config
        let font = config.resolvedFont(family: nil, size: nil)
        fontSample.attributedStringValue = NSAttributedString(
            string: "$ git status --short\n M Sources/Termsie/App/Config.swift\n?? Sources/Termsie/Settings/\n0123456789  iIlL1  oO0",
            attributes: [.font: font, .foregroundColor: NSColor.hex(config.colors.foreground)])
        fontSample.superview?.layer?.backgroundColor = config.background(for: nil).cgColor
    }

    private func reloadEditor() {
        let enabled = selected != nil
        for field in editorFields {
            (field as? NSControl)?.isEnabled = enabled
        }
        removeButton.isEnabled = enabled
        previewView.isHidden = !enabled
        guard let index = selected else {
            nameField.stringValue = ""
            strengthLabel.stringValue = ""
            return
        }
        let env = environments[index]
        nameField.stringValue = env.label
        let hasTint = env.tint != nil
        tintCheck.state = hasTint ? .on : .off
        colorWell.isEnabled = hasTint
        strengthSlider.isEnabled = hasTint
        colorWell.color = env.tint.flatMap { NSColor(hex: $0) } ?? NSColor(hex: "#61afef")!
        strengthSlider.doubleValue = env.strength
        strengthLabel.stringValue = String(format: "%.0f%%", env.strength * 100)
        previewView.style = env
        previewView.needsDisplay = true
    }

    private func mutateSelected(_ body: (inout TermsieConfig.EnvironmentStyle) -> Void) {
        guard let index = selected else { return }
        var list = environments
        body(&list[index])
        environments = list
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        reloadEditor()
    }

    // MARK: Font actions

    @objc private func fontFamilyChanged() {
        guard let family = fontPopUp.selectedItem?.representedObject as? String else { return }
        ConfigStore.shared.update { $0.font.family = family }
        updateSample()
    }

    @objc private func fontSizeStepped() {
        let size = fontSizeStepper.doubleValue
        fontSizeField.stringValue = String(format: "%g", size)
        ConfigStore.shared.update { $0.font.size = size }
        updateSample()
    }

    // MARK: Environment actions

    @objc private func addEnvironment() {
        var list = environments
        let base = "New Environment"
        var label = base
        var n = 2
        while list.contains(where: { $0.label == label }) { label = "\(base) \(n)"; n += 1 }
        let palette = ["#98c379", "#c678dd", "#56b6c2", "#e06c75", "#e5c07b", "#61afef"]
        let tint = palette[list.count % palette.count]
        list.append(TermsieConfig.EnvironmentStyle(id: Self.uniqueID(for: label, existing: list),
                                                   label: label, tint: tint))
        environments = list
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: list.count - 1), byExtendingSelection: false)
        reloadEditor()
        window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    @objc private func removeEnvironment() {
        guard let index = selected else { return }
        var list = environments
        let removed = list.remove(at: index)
        environments = list
        table.reloadData()
        let next = min(index, list.count - 1)
        if next >= 0 { table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false) }
        reloadEditor()
        // Terminals still referencing it simply lose their tint; re-adding an environment with the
        // same id brings them back, so nothing is silently rewritten here.
        NSLog("Termsie: removed environment '\(removed.id)'")
    }

    @objc private func colorChanged() {
        guard let hex = colorWell.color.hexString else { return }
        mutateSelected { $0.tint = hex }
    }

    @objc private func tintToggled() {
        let on = tintCheck.state == .on
        mutateSelected { $0.tint = on ? (colorWell.color.hexString ?? "#61afef") : nil }
    }

    @objc private func strengthChanged() {
        mutateSelected { $0.strength = (strengthSlider.doubleValue * 100).rounded() / 100 }
    }

    /// A stable slug, kept even when the label is later renamed, so terminals keep their
    /// environment across a rename.
    private static func uniqueID(for label: String, existing: [TermsieConfig.EnvironmentStyle]) -> String {
        let allowed = CharacterSet.alphanumerics
        var slug = String(label.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "env" }
        var candidate = slug
        var n = 2
        while existing.contains(where: { $0.id == candidate }) { candidate = "\(slug)-\(n)"; n += 1 }
        return candidate
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === nameField {
            let text = nameField.stringValue
            mutateSelectedPreservingFocus { $0.label = text }
        } else if field === fontSizeField {
            guard let value = Double(fontSizeField.stringValue) else { return }
            let clamped = min(max(value, TermsieConfig.minFontSize), TermsieConfig.maxFontSize)
            fontSizeStepper.doubleValue = clamped
            ConfigStore.shared.update { $0.font.size = clamped }
            updateSample()
        }
    }

    /// Renaming must not steal focus back from the text field on every keystroke.
    private func mutateSelectedPreservingFocus(_ body: (inout TermsieConfig.EnvironmentStyle) -> Void) {
        guard let index = selected else { return }
        var list = environments
        body(&list[index])
        environments = list
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        previewView.style = list[index]
        previewView.needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === fontSizeField { reloadFontTab() }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { environments.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < environments.count else { return nil }
        let env = environments[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 190, height: 30))
        let swatch = SwatchView(frame: NSRect(x: 4, y: 8, width: 14, height: 14))
        swatch.color = env.tint.flatMap { NSColor(hex: $0) }
        cell.addSubview(swatch)
        let text = NSTextField(labelWithString: env.label.isEmpty ? env.id : env.label)
        text.font = NSFont.systemFont(ofSize: 12)
        text.frame = NSRect(x: 26, y: 6, width: 158, height: 18)
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        reloadEditor()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        (op == .above && info.draggingSource as? NSTableView === tableView) ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: .string), let from = Int(text),
              from >= 0, from < environments.count else { return false }
        var list = environments
        let moved = list.remove(at: from)
        list.insert(moved, at: from < row ? row - 1 : row)
        environments = list
        table.reloadData()
        if let index = list.firstIndex(where: { $0.id == moved.id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        reloadEditor()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Colour wells keep grabbing the shared colour panel otherwise.
        colorWell.deactivate()
    }
}

/// A small filled circle, or a dashed outline when an environment has no tint.
final class SwatchView: NSView {
    var color: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if let color {
            color.setFill()
            path.fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.setLineDash([2, 2], count: 2, phase: 0)
            path.stroke()
        }
    }
}

/// Shows a miniature terminal in the environment being edited, so the tint and strength can be
/// judged without applying them first.
final class EnvironmentPreviewView: NSView {
    var style: TermsieConfig.EnvironmentStyle?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let config = ConfigStore.shared.config
        let colors = config.colors
        var background = NSColor.hex(colors.background)
        var header = NSColor.hex(colors.headerActiveBackground)
        if let style, let hex = style.tint, let tint = NSColor(hex: hex) {
            background = background.blended(withFraction: CGFloat(style.strength), of: tint) ?? background
            header = header.blended(withFraction: 0.34, of: tint) ?? header
        }
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        background.setFill()
        body.fill()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        header.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 20).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 1, alpha: 0.12).setStroke()
        body.lineWidth = 1
        body.stroke()

        for (i, light) in [NSColor(srgbRed: 0.996, green: 0.373, blue: 0.345, alpha: 1),
                           NSColor(srgbRed: 0.996, green: 0.741, blue: 0.180, alpha: 1),
                           NSColor(srgbRed: 0.156, green: 0.804, blue: 0.259, alpha: 1)].enumerated() {
            light.setFill()
            NSBezierPath(ovalIn: NSRect(x: 8 + CGFloat(i) * 13, y: 7, width: 7, height: 7)).fill()
        }
        if let style, style.tint != nil, !style.label.isEmpty {
            _ = BadgeDrawing.drawLabel(style.label.uppercased(), rightEdge: bounds.width - 8, midY: 10,
                                       color: style.tint.flatMap { NSColor(hex: $0) } ?? .white, filled: true)
        }
        let sample = NSAttributedString(string: "$ npm run dev\n> listening on :3000", attributes: [
            .font: config.resolvedFont(family: nil, size: 10),
            .foregroundColor: NSColor.hex(colors.foreground),
        ])
        sample.draw(in: NSRect(x: 10, y: 28, width: bounds.width - 20, height: bounds.height - 34))
    }
}

extension NSColor {
    /// sRGB hex, for round-tripping a colour well back into config.json.
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
