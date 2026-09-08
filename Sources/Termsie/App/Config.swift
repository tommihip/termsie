import AppKit
import SwiftTerm

extension Notification.Name {
    static let termsieConfigChanged = Notification.Name("TermsieConfigChanged")
}

/// User configuration, stored as JSON at `~/.config/termsie/config.json`.
/// Every key is optional; missing keys fall back to the defaults below.
struct TermsieConfig: Codable, Equatable {
    struct Font: Codable, Equatable {
        var family: String = "Menlo"
        var size: Double = 13

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            family = try c.decodeIfPresent(String.self, forKey: .family) ?? family
            size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        }
    }

    struct Colors: Codable, Equatable {
        var foreground = "#c8ccd4"
        var background = "#1c1f24"
        var cursor = "#e5e5e5"
        var selection = "#3a4b66"
        var activeBorder = "#4f9cff"
        var inactiveBorder = "#2c3038"
        var divider = "#2c3038"
        var headerBackground = "#15171b"
        var headerActiveBackground = "#1f2430"
        var headerText = "#8a919c"
        var headerActiveText = "#e6e9ee"
        var activity = "#e5c07b"
        var bell = "#e06c75"
        var exited = "#6c7480"
        var sidebarBackground = "#12141899"
        var sidebarSelection = "#1f2430"
        var warning = "#e5c07b"
        var ansi: [String] = [
            "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
            "#5c6370", "#ef7a85", "#a8d38b", "#f0cc8a", "#74baf5", "#d391e6", "#6bc6d1", "#ffffff",
        ]

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            foreground = try c.decodeIfPresent(String.self, forKey: .foreground) ?? foreground
            background = try c.decodeIfPresent(String.self, forKey: .background) ?? background
            cursor = try c.decodeIfPresent(String.self, forKey: .cursor) ?? cursor
            selection = try c.decodeIfPresent(String.self, forKey: .selection) ?? selection
            activeBorder = try c.decodeIfPresent(String.self, forKey: .activeBorder) ?? activeBorder
            inactiveBorder = try c.decodeIfPresent(String.self, forKey: .inactiveBorder) ?? inactiveBorder
            divider = try c.decodeIfPresent(String.self, forKey: .divider) ?? divider
            headerBackground = try c.decodeIfPresent(String.self, forKey: .headerBackground) ?? headerBackground
            headerActiveBackground = try c.decodeIfPresent(String.self, forKey: .headerActiveBackground) ?? headerActiveBackground
            headerText = try c.decodeIfPresent(String.self, forKey: .headerText) ?? headerText
            headerActiveText = try c.decodeIfPresent(String.self, forKey: .headerActiveText) ?? headerActiveText
            activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? activity
            bell = try c.decodeIfPresent(String.self, forKey: .bell) ?? bell
            exited = try c.decodeIfPresent(String.self, forKey: .exited) ?? exited
            sidebarBackground = try c.decodeIfPresent(String.self, forKey: .sidebarBackground) ?? sidebarBackground
            sidebarSelection = try c.decodeIfPresent(String.self, forKey: .sidebarSelection) ?? sidebarSelection
            warning = try c.decodeIfPresent(String.self, forKey: .warning) ?? warning
            if let a = try c.decodeIfPresent([String].self, forKey: .ansi), a.count == 16 { ansi = a }
        }
    }

    /// Per-terminal shell history.
    struct History: Codable, Equatable {
        var isolate = true
        var size: Int? = nil
        var saveSize: Int? = nil
        /// Append a terminal's commands to the user's real history file when it exits, so
        /// isolation does not mean losing them.
        var mergeToGlobalOnExit = true
        /// A user who deliberately set `setopt share_history` keeps one shared history.
        var respectShareHistory = true
        var exportHistfileForUnknownShells = true
        var retentionDays = 30

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isolate = try c.decodeIfPresent(Bool.self, forKey: .isolate) ?? isolate
            size = try c.decodeIfPresent(Int.self, forKey: .size)
            saveSize = try c.decodeIfPresent(Int.self, forKey: .saveSize)
            mergeToGlobalOnExit = try c.decodeIfPresent(Bool.self, forKey: .mergeToGlobalOnExit) ?? mergeToGlobalOnExit
            respectShareHistory = try c.decodeIfPresent(Bool.self, forKey: .respectShareHistory) ?? respectShareHistory
            exportHistfileForUnknownShells = try c.decodeIfPresent(Bool.self, forKey: .exportHistfileForUnknownShells) ?? exportHistfileForUnknownShells
            retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays
        }
    }

    struct StartupCommands: Codable, Equatable {
        /// "shim" runs them from the shell before the first prompt; "typed" sends keystrokes.
        var mode = "shim"
        var echo = true
        var recordInHistory = false

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
            echo = try c.decodeIfPresent(Bool.self, forKey: .echo) ?? echo
            recordInHistory = try c.decodeIfPresent(Bool.self, forKey: .recordInHistory) ?? recordInHistory
        }
    }

    struct Sidebar: Codable, Equatable {
        var visible = true
        var width: Double = 264
        var rowHeight: Double = 84
        /// blocks | text | none
        var thumbnailStyle = "blocks"
        var thumbnailRefreshMs = 500

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? visible
            width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
            rowHeight = try c.decodeIfPresent(Double.self, forKey: .rowHeight) ?? rowHeight
            thumbnailStyle = try c.decodeIfPresent(String.self, forKey: .thumbnailStyle) ?? thumbnailStyle
            thumbnailRefreshMs = try c.decodeIfPresent(Int.self, forKey: .thumbnailRefreshMs) ?? thumbnailRefreshMs
        }
    }

    /// A named environment a terminal can belong to, tinting its background so a production
    /// shell never looks like a local one.
    struct EnvironmentStyle: Codable, Equatable {
        var id = ""
        var label = ""
        /// Hex tint, or nil for the untinted default.
        var tint: String? = nil
        /// How far the terminal background is pulled toward the tint, 0...1.
        var strength: Double = 0.22

        init() {}
        init(id: String, label: String, tint: String?, strength: Double = 0.22) {
            self.id = id; self.label = label; self.tint = tint; self.strength = strength
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? id
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? (id.isEmpty ? "" : id.capitalized)
            tint = try c.decodeIfPresent(String.self, forKey: .tint)
            strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        }
    }

    var font = Font()
    /// Shell executable. `null` means `$SHELL`, falling back to /bin/zsh.
    var shell: String? = nil
    var shellArgs: [String] = ["-l"]
    var scrollback: Int = 10_000
    /// "metal" (GPU, default) or "coregraphics".
    var renderer: String = "metal"
    /// block | bar | underline, optionally prefixed with "blink" (e.g. "blinkBar").
    var cursorStyle: String = "block"
    /// none | sound | visual | both
    var bell: String = "visual"
    var optionAsMeta: Bool = true
    var showPaneHeaders: Bool = true
    /// always | clean | never — whether a pane closes automatically when its shell exits.
    var closePaneOnExit: String = "clean"
    var confirmClosingRunningProcess: Bool = true
    var restoreSession: Bool = true
    /// Delay after the shell's first output (its prompt) before a workspace command is typed in.
    var commandDelayMs: Int = 150
    /// Terminal background opacity, 0...1. Below 1 the window blur shows through.
    var opacity: Double = 0.88
    /// Extra opacity for the focused terminal. Overlapping translucent terminals otherwise let
    /// you read the one behind through the one you are typing in. Set to 0 for uniform opacity.
    var activeOpacityBoost: Double = 0.07
    /// Blur whatever is behind the window, the way Terminal.app does.
    var blurBackground = true
    /// Corner radius of each floating terminal.
    var cornerRadius: Double = 10
    /// Show the red/yellow/green buttons on each terminal.
    var trafficLights = true
    /// Selectable environments. The first is the untinted default.
    var environments: [EnvironmentStyle] = [
        EnvironmentStyle(id: "local", label: "Local", tint: nil),
        EnvironmentStyle(id: "development", label: "Development", tint: "#61afef"),
        EnvironmentStyle(id: "staging", label: "Staging", tint: "#e5c07b"),
        EnvironmentStyle(id: "production", label: "Production", tint: "#e06c75", strength: 0.26),
    ]
    /// "auto" or "off". Off means terminals launch exactly as a plain shell would.
    var shellIntegration = "auto"
    var history = History()
    var startupCommands = StartupCommands()
    var sidebar = Sidebar()
    /// Quantize terminal resizes to whole character cells so the emulator only reflows when the
    /// grid actually changes.
    var snapToCells = true
    var colors = Colors()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = try c.decodeIfPresent(Font.self, forKey: .font) ?? font
        shell = try c.decodeIfPresent(String.self, forKey: .shell)
        shellArgs = try c.decodeIfPresent([String].self, forKey: .shellArgs) ?? shellArgs
        scrollback = try c.decodeIfPresent(Int.self, forKey: .scrollback) ?? scrollback
        renderer = try c.decodeIfPresent(String.self, forKey: .renderer) ?? renderer
        cursorStyle = try c.decodeIfPresent(String.self, forKey: .cursorStyle) ?? cursorStyle
        bell = try c.decodeIfPresent(String.self, forKey: .bell) ?? bell
        optionAsMeta = try c.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? optionAsMeta
        showPaneHeaders = try c.decodeIfPresent(Bool.self, forKey: .showPaneHeaders) ?? showPaneHeaders
        closePaneOnExit = try c.decodeIfPresent(String.self, forKey: .closePaneOnExit) ?? closePaneOnExit
        confirmClosingRunningProcess = try c.decodeIfPresent(Bool.self, forKey: .confirmClosingRunningProcess) ?? confirmClosingRunningProcess
        restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? restoreSession
        commandDelayMs = try c.decodeIfPresent(Int.self, forKey: .commandDelayMs) ?? commandDelayMs
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        activeOpacityBoost = try c.decodeIfPresent(Double.self, forKey: .activeOpacityBoost) ?? activeOpacityBoost
        blurBackground = try c.decodeIfPresent(Bool.self, forKey: .blurBackground) ?? blurBackground
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? cornerRadius
        trafficLights = try c.decodeIfPresent(Bool.self, forKey: .trafficLights) ?? trafficLights
        if let envs = try c.decodeIfPresent([EnvironmentStyle].self, forKey: .environments), !envs.isEmpty {
            environments = envs
        }
        shellIntegration = try c.decodeIfPresent(String.self, forKey: .shellIntegration) ?? shellIntegration
        history = try c.decodeIfPresent(History.self, forKey: .history) ?? history
        startupCommands = try c.decodeIfPresent(StartupCommands.self, forKey: .startupCommands) ?? startupCommands
        sidebar = try c.decodeIfPresent(Sidebar.self, forKey: .sidebar) ?? sidebar
        snapToCells = try c.decodeIfPresent(Bool.self, forKey: .snapToCells) ?? snapToCells
        colors = try c.decodeIfPresent(Colors.self, forKey: .colors) ?? colors
    }

    // MARK: Resolved values

    var nsFont: NSFont {
        NSFont(name: font.family, size: font.size)
            ?? NSFont.monospacedSystemFont(ofSize: font.size, weight: .regular)
    }

    var resolvedShell: String {
        if let s = shell, !s.isEmpty { return s }
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        return "/bin/zsh"
    }

    var useMetal: Bool { renderer.lowercased() != "coregraphics" }

    var terminalCursorStyle: CursorStyle {
        let s = cursorStyle.lowercased()
        let blink = s.hasPrefix("blink")
        if s.contains("bar") { return blink ? .blinkBar : .steadyBar }
        if s.contains("underline") { return blink ? .blinkUnderline : .steadyUnderline }
        return blink ? .blinkBlock : .steadyBlock
    }

    var terminalBellStyle: BellStyle {
        switch bell.lowercased() {
        case "none": return .none
        case "sound": return .sound
        case "both", "soundandvisual": return .soundAndVisual
        default: return .visual
        }
    }

    var resolvedOpacity: CGFloat { CGFloat(min(max(opacity, 0.25), 1.0)) }

    func resolvedOpacity(active: Bool) -> CGFloat {
        let boost = active ? max(activeOpacityBoost, 0) : 0
        return CGFloat(min(max(opacity + boost, 0.25), 1.0))
    }

    func environment(_ id: String?) -> EnvironmentStyle? {
        guard let id, !id.isEmpty else { return nil }
        return environments.first { $0.id == id }
    }

    /// The terminal background for an environment: the configured background pulled toward the
    /// environment's tint, then given the window's opacity.
    func background(for environmentID: String?) -> NSColor {
        let base = NSColor.hex(colors.background)
        guard let env = environment(environmentID), let hex = env.tint,
              let tint = NSColor(hex: hex) else { return base }
        let blended = base.usingColorSpace(.sRGB)?
            .blended(withFraction: CGFloat(min(max(env.strength, 0), 1)), of: tint) ?? base
        return blended
    }

    var ansiColors: [SwiftTerm.Color] {
        colors.ansi.map { SwiftTerm.Color(hex: $0) ?? SwiftTerm.Color(red: 0, green: 0, blue: 0) }
    }
}

// MARK: - Color helpers

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xff) / 255; g = CGFloat((v >> 16) & 0xff) / 255
            b = CGFloat((v >> 8) & 0xff) / 255; a = CGFloat(v & 0xff) / 255
        } else {
            r = CGFloat((v >> 16) & 0xff) / 255; g = CGFloat((v >> 8) & 0xff) / 255
            b = CGFloat(v & 0xff) / 255; a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func hex(_ hex: String, fallback: NSColor = .magenta) -> NSColor {
        NSColor(hex: hex) ?? fallback
    }
}

extension SwiftTerm.Color {
    convenience init?(hex: String) {
        guard let c = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return nil }
        self.init(red8: UInt16(c.redComponent * 255), green8: UInt16(c.greenComponent * 255), blue8: UInt16(c.blueComponent * 255))
    }
}

// MARK: - Store

/// Owns the on-disk config, reloads it when the file changes, and knows the config directory layout.
final class ConfigStore {
    static let shared = ConfigStore()

    let configDir: URL
    let configURL: URL
    let workspacesDir: URL
    let sessionURL: URL
    /// Per-terminal state: the zsh ZDOTDIR shim and the private history file.
    let panesDir: URL

    private(set) var config: TermsieConfig
    private var watcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
        configDir = (xdg ?? home.appendingPathComponent(".config")).appendingPathComponent("termsie", isDirectory: true)
        configURL = configDir.appendingPathComponent("config.json")
        workspacesDir = configDir.appendingPathComponent("workspaces", isDirectory: true)
        sessionURL = configDir.appendingPathComponent("session.json")
        panesDir = configDir.appendingPathComponent("panes", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspacesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: panesDir, withIntermediateDirectories: true)
        config = ConfigStore.load(from: configURL) ?? TermsieConfig()
        if !FileManager.default.fileExists(atPath: configURL.path) {
            ConfigStore.writeDefault(to: configURL)
        }
    }

    private static func load(from url: URL) -> TermsieConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(TermsieConfig.self, from: data)
        } catch {
            NSLog("Termsie: config.json is invalid, using defaults: \(error)")
            return nil
        }
    }

    private static func writeDefault(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(TermsieConfig()) {
            try? data.write(to: url)
        }
    }

    func reload() {
        let fresh = ConfigStore.load(from: configURL) ?? TermsieConfig()
        guard fresh != config else { return }
        config = fresh
        NotificationCenter.default.post(name: .termsieConfigChanged, object: self)
    }

    /// Watches both the file (in-place edits) and its directory (atomic saves replace the file).
    func startWatching() {
        watchDirectory()
        watchFile()
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func watchDirectory() {
        let fd = open(configDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleReload()
            if self.fileWatcher == nil { self.watchFile() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let events = src.data
            self.scheduleReload()
            if events.contains(.delete) || events.contains(.rename) {
                // The file was replaced; watch the new inode once the writer is done.
                self.fileWatcher?.cancel()
                self.fileWatcher = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watchFile() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatcher = src
    }
}
