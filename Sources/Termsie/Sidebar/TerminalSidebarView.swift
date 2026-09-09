import AppKit

protocol TerminalSidebarDelegate: AnyObject {
    func sidebarDidActivate(_ id: String)
    func sidebarDidRequestSettings(_ id: String)
    func sidebarDidRequestClose(_ id: String)
    func sidebarDidRequestOpen(_ id: String)
    func sidebarDidRequestDelete(_ id: String)
    func sidebarDidRequestDuplicate(_ id: String)
    func sidebarDidReorder()
    func sidebarDidRequestNew()
    func sidebarDidSetEnvironment(_ environment: String?, for id: String)
}

/// The PowerPoint-style list of terminals down the left of the window.
final class TerminalSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let pasteboardType = NSPasteboard.PasteboardType("com.termsie.terminal-definition")

    weak var delegate: TerminalSidebarDelegate?
    let registry: TerminalRegistry

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let footer = SidebarFooterView()
    private var sources: [String: ThumbnailSource] = [:]
    private var refreshTimer: Timer?
    private var quietTicks = 0

    init(registry: TerminalRegistry) {
        self.registry = registry
        super.init(frame: .zero)
        wantsLayer = true

        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = CGFloat(ConfigStore.shared.config.sidebar.rowHeight)
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("terminal"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.registerForDraggedTypes([Self.pasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask([], forLocal: false)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        footer.onAdd = { [weak self] in self?.delegate?.sidebarDidRequestNew() }
        addSubview(footer)

        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.hex(ConfigStore.shared.config.colors.sidebarBackground).cgColor
        let footerH = SidebarFooterView.height
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footerH)
        scrollView.frame = NSRect(x: 0, y: footerH, width: bounds.width,
                                  height: max(0, bounds.height - footerH))
    }

    // MARK: Refresh

    func reloadAll() {
        tableView.rowHeight = CGFloat(ConfigStore.shared.config.sidebar.rowHeight)
        tableView.reloadData()
        syncSelection()
        kickTimer()
    }

    /// Repaints one row in place. Note `reloadData(forRowIndexes:)` would NOT work here: it
    /// refreshes cell views, and all of this row's drawing lives in the row view itself.
    func reloadRow(_ id: String) {
        guard let row = registry.index(of: id), row < tableView.numberOfRows else { return }
        guard let view = tableView.rowView(atRow: row, makeIfNecessary: false) as? TerminalRowView else { return }
        configure(view, row: row)
        view.needsDisplay = true
    }

    func syncSelection() {
        guard let active = activeID, let row = registry.index(of: active) else { return }
        guard row < tableView.numberOfRows else { return }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        tableView.scrollRowToVisible(row)
    }

    var activeID: String?

    func dropCache(for id: String) { sources[id]?.invalidate() }
    func forgetCache(for id: String) { sources.removeValue(forKey: id) }
    func renderCount(for id: String) -> Int { sources[id]?.renderCount ?? 0 }

    private func source(for id: String) -> ThumbnailSource {
        if let s = sources[id] { return s }
        let s = ThumbnailSource()
        sources[id] = s
        return s
    }

    @objc private func scrolled() {
        refreshVisibleThumbnails(force: false)
    }

    /// One shared timer for the whole window, stopped entirely when nothing is producing output.
    /// Each pane already runs its own 1.5 s poll timer, so a second unconditional timer per pane
    /// would double the app's idle wakeups.
    func kickTimer() {
        quietTicks = 0
        guard refreshTimer == nil else { return }
        let interval = Double(max(ConfigStore.shared.config.sidebar.thumbnailRefreshMs, 100)) / 1000
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func tick() {
        let did = refreshVisibleThumbnails(force: false)
        quietTicks = did ? 0 : quietTicks + 1
        if quietTicks >= 5 { stopTimer() }
    }

    @discardableResult
    func refreshVisibleThumbnails(force: Bool) -> Bool {
        guard !isHidden, window?.occlusionState.contains(.visible) ?? false else { return false }
        let range = tableView.rows(in: scrollView.contentView.bounds)
        guard range.length > 0 else { return false }
        let colors = ConfigStore.shared.config.colors
        let scale = window?.backingScaleFactor ?? 2
        var didRender = false
        let lower = max(0, range.location - 1)
        let upper = min(registry.count, range.location + range.length + 1)
        guard lower < upper else { return false }
        for row in lower..<upper {
            guard let id = registry.id(at: row) else { continue }
            guard let pane = registry.pane(for: id) else { continue }
            guard force || pane.thumbnailDirty else { continue }
            pane.thumbnailDirty = false
            let src = source(for: id)
            let before = src.renderCount
            _ = src.refresh(terminal: pane.terminalView.getTerminal(),
                            size: TerminalRowView.thumbnailSize, scale: scale,
                            colors: colors, showCursor: pane.isActive,
                            background: pane.environmentBackground, force: force)
            if src.renderCount != before {
                didRender = true
                reloadRow(id)
            }
        }
        return didRender
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { registry.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = TerminalRowView()
        configure(view, row: row)
        return view
    }

    private func configure(_ view: TerminalRowView, row: Int) {
        guard let id = registry.id(at: row), let def = registry.definition(id) else { return }
        let pane = registry.pane(for: id)
        view.number = row + 1
        view.isOpen = pane != nil
        view.isBusy = pane?.hasRunningJob ?? false
        view.isActivePane = (id == activeID)
        view.title = pane?.displayTitle ?? def.displayName
        view.subtitle = pane?.displayDirectory ?? (def.cwd.map(ProcessInspector.abbreviateHome) ?? "")
        view.badge = pane?.header.badge ?? .none
        let config = ConfigStore.shared.config
        let style = config.environment(def.environment)
        view.environmentTint = style?.tint.flatMap { NSColor(hex: $0) }
        view.environmentLabel = style?.tint == nil ? nil : style?.label
        let colors = config.colors
        let scale = window?.backingScaleFactor ?? 2
        let background = config.background(for: def.environment)
        if let pane {
            view.thumbnail = source(for: id).refresh(terminal: pane.terminalView.getTerminal(),
                                                     size: TerminalRowView.thumbnailSize,
                                                     scale: scale, colors: colors,
                                                     showCursor: pane.isActive,
                                                     background: background)
        } else {
            view.thumbnail = source(for: id).setRecipe(def, size: TerminalRowView.thumbnailSize,
                                                       scale: scale, colors: colors,
                                                       background: background)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        nil
    }

    // MARK: Drag reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let id = registry.id(at: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(id, forType: Self.pasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .above, info.draggingSource as? NSTableView === tableView else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.pasteboardType) else { return false }
        registry.move(id, to: row)
        delegate?.sidebarDidReorder()
        return true
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, let id = registry.id(at: row) else { return }
        if registry.isOpen(id) { delegate?.sidebarDidActivate(id) }
        else { delegate?.sidebarDidRequestOpen(id) }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, let id = registry.id(at: row) else { return }
        delegate?.sidebarDidRequestSettings(id)
    }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, let first = chars.unicodeScalars.first else {
            super.keyDown(with: event); return
        }
        let row = tableView.selectedRow
        guard row >= 0, let id = registry.id(at: row) else { super.keyDown(with: event); return }
        switch Int(first.value) {
        case NSCarriageReturnCharacter, NSEnterCharacter:
            registry.isOpen(id) ? delegate?.sidebarDidActivate(id) : delegate?.sidebarDidRequestOpen(id)
        case NSDeleteCharacter, NSBackspaceCharacter:
            delegate?.sidebarDidRequestDelete(id)
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: p)
        guard row >= 0, let id = registry.id(at: row) else { return nil }
        let isOpen = registry.isOpen(id)
        let menu = NSMenu()
        let openItem = NSMenuItem(title: isOpen ? "Close Terminal" : "Open Terminal",
                                  action: #selector(contextToggleOpen(_:)), keyEquivalent: "")
        openItem.representedObject = id
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        for (title, sel) in [("Terminal Settings…", #selector(contextSettings(_:))),
                             ("Duplicate", #selector(contextDuplicate(_:))),
                             ("Reveal Working Folder in Finder", #selector(contextReveal(_:))),
                             ("Copy Working Folder Path", #selector(contextCopyPath(_:)))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.representedObject = id
            item.target = self
            menu.addItem(item)
        }
        let envMenu = NSMenu()
        let current = registry.definition(id)?.environment ?? ""
        let noneItem = NSMenuItem(title: "None", action: #selector(contextSetEnvironment(_:)), keyEquivalent: "")
        noneItem.representedObject = [id, ""]
        noneItem.target = self
        noneItem.state = current.isEmpty ? .on : .off
        envMenu.addItem(noneItem)
        envMenu.addItem(.separator())
        for style in ConfigStore.shared.config.environments {
            let envItem = NSMenuItem(title: style.label, action: #selector(contextSetEnvironment(_:)),
                                     keyEquivalent: "")
            envItem.representedObject = [id, style.id]
            envItem.target = self
            envItem.state = current == style.id ? .on : .off
            envMenu.addItem(envItem)
        }
        envMenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Environments…",
                                action: #selector(AppDelegate.openEnvironmentSettings(_:)), keyEquivalent: "")
        manage.target = AppDelegate.shared
        envMenu.addItem(manage)
        let envParent = NSMenuItem(title: "Environment", action: nil, keyEquivalent: "")
        envParent.submenu = envMenu
        menu.addItem(envParent)
        menu.addItem(.separator())
        let del = NSMenuItem(title: "Delete", action: #selector(contextDelete(_:)), keyEquivalent: "")
        del.representedObject = id
        del.target = self
        menu.addItem(del)
        return menu
    }

    private func contextID(_ sender: Any?) -> String? {
        (sender as? NSMenuItem)?.representedObject as? String
    }

    @objc private func contextToggleOpen(_ sender: Any?) {
        guard let id = contextID(sender) else { return }
        registry.isOpen(id) ? delegate?.sidebarDidRequestClose(id) : delegate?.sidebarDidRequestOpen(id)
    }
    @objc private func contextSettings(_ sender: Any?) {
        contextID(sender).map { delegate?.sidebarDidRequestSettings($0) }
    }
    @objc private func contextDuplicate(_ sender: Any?) {
        contextID(sender).map { delegate?.sidebarDidRequestDuplicate($0) }
    }
    @objc private func contextDelete(_ sender: Any?) {
        contextID(sender).map { delegate?.sidebarDidRequestDelete($0) }
    }
    @objc private func contextSetEnvironment(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [String], pair.count == 2 else { return }
        delegate?.sidebarDidSetEnvironment(pair[1].isEmpty ? nil : pair[1], for: pair[0])
    }

    @objc private func contextReveal(_ sender: Any?) {
        guard let id = contextID(sender),
              let dir = registry.pane(for: id)?.currentDirectory ?? registry.definition(id)?.cwd else { return }
        let path = (dir as NSString).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    @objc private func contextCopyPath(_ sender: Any?) {
        guard let id = contextID(sender),
              let dir = registry.pane(for: id)?.currentDirectory ?? registry.definition(id)?.cwd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((dir as NSString).expandingTildeInPath, forType: .string)
    }

    /// Anchors the settings popover to a row.
    func rowRect(for id: String) -> NSRect? {
        guard let row = registry.index(of: id), row < tableView.numberOfRows else { return nil }
        return convert(tableView.rect(ofRow: row), from: tableView)
    }
}
