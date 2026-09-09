import AppKit

/// The title bar of a floating terminal: window buttons, its number, name, working directory and
/// state. Also the drag handle that moves the terminal around the canvas.
final class PaneHeaderView: NSView {
    static let height: CGFloat = 26

    typealias Badge = BadgeDrawing.Badge

    weak var pane: TerminalPane?
    let lights = TrafficLightsView(frame: .zero)

    var index: Int = 0 { didSet { needsDisplay = true } }
    var title: String = "" { didSet { needsDisplay = true } }
    var subtitle: String = "" { didSet { needsDisplay = true } }
    var isActive: Bool = false {
        didSet { lights.isActive = isActive; needsDisplay = true }
    }
    var badge: Badge = .none { didSet { needsDisplay = true } }
    var isBroadcasting: Bool = false { didSet { needsDisplay = true } }
    var isZoomed: Bool = false { didSet { lights.isZoomed = isZoomed; needsDisplay = true } }
    var isCollapsed: Bool = false { didSet { lights.isCollapsed = isCollapsed; needsDisplay = true } }
    /// Transient overlay such as the cols × rows readout shown while resizing.
    var transientNote: String? { didSet { needsDisplay = true } }
    /// Label and colour of the terminal's environment, if it has one.
    var environmentLabel: String?
    var environmentTint: NSColor? { didSet { needsDisplay = true } }
    var showsTrafficLights = true {
        didSet {
            lights.isHidden = !showsTrafficLights
            needsLayout = true
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(lights)
        lights.onClose = { [weak self] in
            guard let pane = self?.pane else { return }
            pane.controller?.closePane(pane)
        }
        lights.onCollapse = { [weak self] in self?.pane?.toggleCollapsed() }
        lights.onZoom = { [weak self] in self?.pane?.toggleZoom() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        lights.frame = NSRect(x: 10, y: 0, width: TrafficLightsView.width, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = ConfigStore.shared.config.colors
        var background = NSColor.hex(isActive ? colors.headerActiveBackground : colors.headerBackground)
        // The header carries the environment tint too, so a production terminal reads as one at a
        // glance even when its output happens to be dark.
        if let tint = environmentTint {
            background = background.blended(withFraction: isActive ? 0.34 : 0.22, of: tint) ?? background
        }
        background.withAlphaComponent(isActive ? 0.96 : 0.88).setFill()
        bounds.fill()

        // A hairline under the header separates it from the terminal without a hard edge.
        NSColor(white: 1, alpha: 0.07).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()

        let textColor = NSColor.hex(isActive ? colors.headerActiveText : colors.headerText)
        let dimColor = NSColor.hex(colors.headerText)
        let midY = bounds.midY

        var x: CGFloat = 10
        if showsTrafficLights { x = lights.frame.maxX + 12 }

        let pill = BadgeDrawing.drawIndexPill(index, at: NSPoint(x: x, y: midY - BadgeDrawing.pillHeight / 2),
                                              active: isActive, colors: colors)
        x = pill.maxX + 8

        var rightX = bounds.width - 8
        if let note = transientNote {
            rightX = BadgeDrawing.drawLabel(note, rightEdge: rightX, midY: midY,
                                            color: NSColor.hex(colors.activeBorder), filled: true).minX - 6
        }
        rightX = BadgeDrawing.draw(badge, rightEdge: rightX, midY: midY, colors: colors)
        if isBroadcasting {
            rightX = BadgeDrawing.drawLabel("BROADCAST", rightEdge: rightX, midY: midY,
                                            color: NSColor.hex(colors.activity), filled: false).minX - 6
        }
        if let label = environmentLabel, let tint = environmentTint {
            rightX = BadgeDrawing.drawLabel(label.uppercased(), rightEdge: rightX, midY: midY,
                                            color: tint, filled: true).minX - 6
        }

        let titleFont = UIFonts.system(size: 11, weight: isActive ? .semibold : .medium)
        let used = BadgeDrawing.drawTruncated(title, font: titleFont, color: textColor,
                                              at: NSPoint(x: x, y: midY - 7), maxWidth: max(0, rightX - x))
        x += used + 10
        if !subtitle.isEmpty, rightX - x > 30 {
            BadgeDrawing.drawTruncated(subtitle, font: UIFonts.monospaced(size: 10.5, weight: .regular),
                                       color: dimColor, at: NSPoint(x: x, y: midY - 7), maxWidth: rightX - x)
        }
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        pane?.activate()
        if event.clickCount == 2 {
            // Double-click maximizes, the window-manager convention. Rename lives on ⌥⌘R and in
            // the context menu.
            pane?.toggleZoom()
            return
        }
        guard let pane else { return }
        pane.beginTracking(event, zone: .move)
    }

    override func rightMouseDown(with event: NSEvent) {
        pane?.activate()
        guard let pane, let controller = pane.controller else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: pane.isZoomed ? "Restore" : "Maximize",
                     action: #selector(TerminalWindowController.toggleZoom(_:)), keyEquivalent: "")
        menu.addItem(withTitle: pane.isCollapsed ? "Expand" : "Collapse",
                     action: #selector(TerminalWindowController.toggleCollapse(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Rename…",
                     action: #selector(TerminalWindowController.renameActivePane(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Terminal Settings…",
                     action: #selector(TerminalWindowController.showTerminalSettings(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // Environment submenu, so switching a terminal to production is two clicks from its header.
        let envMenu = NSMenu()
        let noneItem = NSMenuItem(title: "None",
                                  action: #selector(TerminalWindowController.setEnvironmentFromMenu(_:)),
                                  keyEquivalent: "")
        noneItem.representedObject = ""
        noneItem.target = controller
        noneItem.state = (controller.registry.definition(pane.definitionID)?.environment ?? "").isEmpty ? .on : .off
        envMenu.addItem(noneItem)
        envMenu.addItem(.separator())
        for style in ConfigStore.shared.config.environments {
            let item = NSMenuItem(title: style.label,
                                  action: #selector(TerminalWindowController.setEnvironmentFromMenu(_:)),
                                  keyEquivalent: "")
            item.representedObject = style.id
            item.target = controller
            item.state = (controller.registry.definition(pane.definitionID)?.environment ?? "") == style.id ? .on : .off
            envMenu.addItem(item)
        }
        envMenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Environments…",
                                action: #selector(AppDelegate.openEnvironmentSettings(_:)), keyEquivalent: "")
        manage.target = AppDelegate.shared
        envMenu.addItem(manage)
        let envItem = NSMenuItem(title: "Environment", action: nil, keyEquivalent: "")
        envItem.submenu = envMenu
        menu.addItem(envItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring to Front",
                     action: #selector(TerminalWindowController.bringPaneToFront(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Send to Back",
                     action: #selector(TerminalWindowController.sendPaneToBack(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Terminal",
                     action: #selector(TerminalWindowController.closeActivePane(_:)), keyEquivalent: "")
        for item in menu.items where item.target == nil { item.target = controller }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
