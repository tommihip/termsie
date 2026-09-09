import AppKit

/// Edits one terminal's saved settings: name, working folder, startup commands.
///
/// A popover rather than a sheet (which would be modal while you edit a path) or a permanent
/// inspector (which would eat the vertical space the thumbnails exist to fill).
final class TerminalSettingsPopover: NSViewController, NSTextFieldDelegate {
    private let definitionID: String
    private weak var registry: TerminalRegistry?
    private let onApply: (String, [String]) -> Void

    private let nameField = NSTextField()
    private let cwdField = NSTextField()
    private let cwdWarning = NSTextField(labelWithString: "")
    private let commandsView = NSTextView()
    private let environmentPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let reopenCheck = NSButton(checkboxWithTitle: "Run commands when reopening", target: nil, action: nil)
    private let historyCheck = NSButton(checkboxWithTitle: "Own command history", target: nil, action: nil)
    private let applyButton = NSButton(title: "Run Commands Now", target: nil, action: nil)

    let popover = NSPopover()

    /// Called when the environment changes, so the terminal repaints immediately rather than
    /// waiting for the popover to close.
    var onEnvironmentChange: ((String, String?) -> Void)?

    init(definitionID: String, registry: TerminalRegistry, onApply: @escaping (String, [String]) -> Void) {
        self.definitionID = definitionID
        self.registry = registry
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 466))
        let pad: CGFloat = 14
        let width = root.bounds.width - 2 * pad
        var y = root.bounds.height - pad

        func label(_ text: String) {
            y -= 16
            let l = NSTextField(labelWithString: text)
            l.font = UIFonts.system(size: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: pad, y: y, width: width, height: 16)
            root.addSubview(l)
            y -= 4
        }

        label("Name")
        y -= 22
        nameField.frame = NSRect(x: pad, y: y, width: width, height: 22)
        nameField.placeholderString = registry?.definition(definitionID)?.displayName ?? "shell"
        nameField.delegate = self
        root.addSubview(nameField)
        y -= 10

        label("Environment")
        y -= 24
        environmentPopUp.frame = NSRect(x: pad, y: y, width: width, height: 24)
        environmentPopUp.target = self
        environmentPopUp.action = #selector(environmentChanged)
        let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        none.representedObject = ""
        environmentPopUp.menu?.addItem(none)
        for style in ConfigStore.shared.config.environments {
            let item = NSMenuItem(title: style.label, action: nil, keyEquivalent: "")
            item.representedObject = style.id
            if let hex = style.tint, let color = NSColor(hex: hex) {
                // A colour swatch beside the name, so the tint is obvious before you pick it.
                let swatch = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                    color.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
                }
                item.image = swatch
            }
            environmentPopUp.menu?.addItem(item)
        }
        root.addSubview(environmentPopUp)
        y -= 10

        // Font: empty fields mean "inherit", which is why the placeholders show the global values.
        label("Font")
        y -= 24
        fontPopUp.frame = NSRect(x: pad, y: y, width: width - 74, height: 24)
        fontPopUp.target = self
        fontPopUp.action = #selector(fontChanged)
        let globalFamily = ConfigStore.shared.config.font.family
        let inherit = NSMenuItem(title: "Global (\(globalFamily))", action: nil, keyEquivalent: "")
        inherit.representedObject = ""
        fontPopUp.menu?.addItem(inherit)
        fontPopUp.menu?.addItem(.separator())
        for family in FontCatalog.families(including: definitionFamily) {
            fontPopUp.menu?.addItem(FontCatalog.menuItem(for: family))
        }
        root.addSubview(fontPopUp)
        fontSizeField.frame = NSRect(x: pad + width - 70, y: y + 1, width: 44, height: 22)
        fontSizeField.alignment = .right
        fontSizeField.placeholderString = String(format: "%g", ConfigStore.shared.config.font.size)
        fontSizeField.delegate = self
        root.addSubview(fontSizeField)
        fontSizeStepper.frame = NSRect(x: pad + width - 22, y: y, width: 19, height: 24)
        fontSizeStepper.minValue = TermsieConfig.minFontSize
        fontSizeStepper.maxValue = TermsieConfig.maxFontSize
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped)
        root.addSubview(fontSizeStepper)
        y -= 10

        label("Working folder")
        y -= 22
        cwdField.frame = NSRect(x: pad, y: y, width: width - 78, height: 22)
        cwdField.placeholderString = "~"
        cwdField.delegate = self
        root.addSubview(cwdField)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: pad + width - 74, y: y - 1, width: 74, height: 24)
        root.addSubview(choose)
        y -= 16
        cwdWarning.frame = NSRect(x: pad, y: y, width: width, height: 14)
        cwdWarning.font = UIFonts.system(size: 10)
        cwdWarning.textColor = NSColor.hex(ConfigStore.shared.config.colors.bell)
        root.addSubview(cwdWarning)
        y -= 8

        label("Commands to run on open (one per line)")
        y -= 92
        let scroll = NSScrollView(frame: NSRect(x: pad, y: y, width: width, height: 92))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        commandsView.font = UIFonts.monospaced(size: 11, weight: .regular)
        commandsView.isRichText = false
        commandsView.isAutomaticQuoteSubstitutionEnabled = false
        commandsView.autoresizingMask = [.width]
        commandsView.minSize = NSSize(width: 0, height: 0)
        commandsView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        commandsView.isVerticallyResizable = true
        scroll.documentView = commandsView
        root.addSubview(scroll)
        y -= 12

        y -= 20
        reopenCheck.frame = NSRect(x: pad, y: y, width: width, height: 20)
        root.addSubview(reopenCheck)
        y -= 22
        historyCheck.frame = NSRect(x: pad, y: y, width: width, height: 20)
        root.addSubview(historyCheck)
        y -= 30
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(applyNow)
        applyButton.frame = NSRect(x: pad, y: y, width: width, height: 24)
        root.addSubview(applyButton)

        view = root
        load()
    }

    private func load() {
        guard let def = registry?.definition(definitionID) else { return }
        nameField.stringValue = def.name ?? ""
        cwdField.stringValue = def.cwd ?? ""
        commandsView.string = def.startupCommands.joined(separator: "\n")
        reopenCheck.state = def.runCommandsOnReopen ? .on : .off
        // Offset by one for the leading "None" item.
        let envIndex = ConfigStore.shared.config.environments.firstIndex { $0.id == (def.environment ?? "") }
        environmentPopUp.selectItem(at: envIndex.map { $0 + 1 } ?? 0)
        if let family = def.fontFamily, !family.isEmpty {
            fontPopUp.selectItem(withTitle: family)
        } else {
            fontPopUp.selectItem(at: 0)
        }
        fontSizeField.stringValue = def.fontSize.map { String(format: "%g", $0) } ?? ""
        fontSizeStepper.doubleValue = def.fontSize ?? ConfigStore.shared.config.font.size
        historyCheck.state = def.isolatedHistory ? .on : .off
        applyButton.isEnabled = registry?.isOpen(definitionID) ?? false
        validateFolder()
    }

    /// Warns but never blocks: the folder may be on a volume that is not mounted right now,
    /// and refusing to save would make the app unusable with external disks.
    private func validateFolder() {
        let raw = cwdField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            cwdWarning.stringValue = ""
            cwdField.layer?.borderWidth = 0
            return
        }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
        cwdWarning.stringValue = exists ? "" : "Folder not found — this terminal will open in your home folder."
        cwdField.wantsLayer = true
        cwdField.layer?.borderWidth = exists ? 0 : 1
        cwdField.layer?.borderColor = NSColor.hex(ConfigStore.shared.config.colors.bell).cgColor
        cwdField.layer?.cornerRadius = 4
    }

    private var enteredCommands: [String] {
        commandsView.string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func controlTextDidChange(_ obj: Notification) {
        let field = obj.object as? NSTextField
        if field === cwdField { validateFolder() }
        if field === fontSizeField {
            if let size = enteredFontSize { fontSizeStepper.doubleValue = size }
            commit()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    private var selectedEnvironment: String? {
        let value = environmentPopUp.selectedItem?.representedObject as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    private var definitionFamily: String? { registry?.definition(definitionID)?.fontFamily }

    private var selectedFontFamily: String? {
        let value = fontPopUp.selectedItem?.representedObject as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// An empty size field means "inherit the global size".
    private var enteredFontSize: Double? {
        let text = fontSizeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Double(text) else { return nil }
        return min(max(value, TermsieConfig.minFontSize), TermsieConfig.maxFontSize)
    }

    @objc private func fontChanged() { commit() }

    @objc private func fontSizeStepped() {
        fontSizeField.stringValue = String(format: "%g", fontSizeStepper.doubleValue)
        commit()
    }

    @objc private func environmentChanged() {
        commit()
        onEnvironmentChange?(definitionID, selectedEnvironment)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current = registry?.definition(definitionID)?.cwd {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.cwdField.stringValue = ProcessInspector.abbreviateHome(url.path)
            self.validateFolder()
            self.commit()
        }
    }

    @objc private func applyNow() {
        onApply(definitionID, enteredCommands)
    }

    /// Changes commit on end-editing and on close, matching the app's hot-reloading config feel.
    func commit() {
        registry?.mutate(definitionID) { def in
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            def.name = name.isEmpty ? nil : name
            let cwd = cwdField.stringValue.trimmingCharacters(in: .whitespaces)
            def.cwd = cwd.isEmpty ? nil : cwd
            def.startupCommands = enteredCommands
            def.runCommandsOnReopen = reopenCheck.state == .on
            def.isolatedHistory = historyCheck.state == .on
            def.environment = selectedEnvironment
            def.fontFamily = selectedFontFamily
            def.fontSize = enteredFontSize
        }
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.contentViewController = self
        popover.behavior = .semitransient
        popover.delegate = PopoverCloser.shared
        PopoverCloser.shared.onClose = { [weak self] in self?.commit() }
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }
}

/// Commits edits when the popover closes without the caller having to observe it.
final class PopoverCloser: NSObject, NSPopoverDelegate {
    static let shared = PopoverCloser()
    var onClose: (() -> Void)?
    func popoverWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}
