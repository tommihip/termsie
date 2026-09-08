import AppKit

/// The window's content view: the terminal list, a draggable divider, and the canvas.
///
/// Deliberately not an `NSSplitViewController` — the whole app is `NSWindowController`-based with
/// manual frame layout, and a view-controller container would be the odd one out.
final class SidebarContainerView: NSView {
    let sidebar: TerminalSidebarView
    let canvasHost: NSView
    /// Blurs whatever is behind the window, the way Terminal.app does.
    private let backdrop = NSVisualEffectView()
    /// The sidebar gets its own material so it reads as a panel rather than a hole.
    private let sidebarBackdrop = NSVisualEffectView()

    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 420
    static let dividerWidth: CGFloat = 1
    private static let dividerGrab: CGFloat = 6

    var sidebarVisible: Bool = true {
        didSet {
            sidebar.isHidden = !sidebarVisible
            needsLayout = true
            layoutSubtreeIfNeeded()
            window?.invalidateCursorRects(for: self)
        }
    }

    var sidebarWidth: CGFloat = 220 {
        didSet {
            sidebarWidth = min(max(sidebarWidth, Self.minWidth), Self.maxWidth)
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    var onGeometryChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    init(sidebar: TerminalSidebarView, canvasHost: NSView) {
        self.sidebar = sidebar
        self.canvasHost = canvasHost
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        addSubview(backdrop)
        sidebarBackdrop.material = .sidebar
        sidebarBackdrop.blendingMode = .behindWindow
        sidebarBackdrop.state = .followsWindowActiveState
        addSubview(sidebarBackdrop)
        addSubview(sidebar)
        addSubview(canvasHost)
        applyConfig()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// How many blur views are actually participating, for headless assertions.
    var activeBackdropCount: Int {
        [backdrop, sidebarBackdrop].filter { !$0.isHidden && $0.frame.width > 0 }.count
    }

    func applyConfig() {
        let blur = ConfigStore.shared.config.blurBackground
        backdrop.isHidden = !blur
        sidebarBackdrop.isHidden = !blur
        layer?.backgroundColor = blur
            ? NSColor.clear.cgColor
            : NSColor.hex(ConfigStore.shared.config.colors.background).cgColor
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        sidebarBackdrop.frame = sidebarVisible
            ? NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
            : .zero
        if sidebarVisible {
            sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
            let x = sidebarWidth + Self.dividerWidth
            canvasHost.frame = NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height)
        } else {
            canvasHost.frame = bounds
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard sidebarVisible else { return }
        NSColor.hex(ConfigStore.shared.config.colors.divider).setFill()
        NSRect(x: sidebarWidth, y: 0, width: Self.dividerWidth, height: bounds.height).fill()
    }

    private var dividerRect: NSRect {
        NSRect(x: sidebarWidth - Self.dividerGrab / 2, y: 0,
               width: Self.dividerGrab + Self.dividerWidth, height: bounds.height)
    }

    override func resetCursorRects() {
        guard sidebarVisible else { return }
        addCursorRect(dividerRect, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard sidebarVisible else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard dividerRect.contains(p) else { return }
        let startX = p.x
        let startWidth = sidebarWidth
        guard let window else { return }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
            guard let ev else { stop.pointee = true; return }
            let q = self.convert(ev.locationInWindow, from: nil)
            self.sidebarWidth = startWidth + (q.x - startX)
            if ev.type == .leftMouseUp { stop.pointee = true }
        }
        window.invalidateCursorRects(for: self)
        onGeometryChanged?()
    }
}
