import Foundation
import SwiftTerm

extension Notification.Name {
    public static let termsieConfigChanged = Notification.Name("TermsieConfigChanged")
}

/// User configuration, stored as JSON at `~/.config/termsie/config.json` (on Windows,
/// `%APPDATA%\termsie\config.json`). Every key is optional; missing keys fall back to the
/// defaults below.
public struct TermsieConfig: Codable, Equatable {
    public struct Font: Codable, Equatable {
        public var family: String = TermsieConfig.defaultFontFamily
        public var size: Double = 13

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            family = try c.decodeIfPresent(String.self, forKey: .family) ?? family
            size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        }
    }

    public struct Colors: Codable, Equatable {
        public var foreground = "#c8ccd4"
        public var background = "#1c1f24"
        public var cursor = "#e5e5e5"
        public var selection = "#3a4b66"
        public var activeBorder = "#4f9cff"
        public var inactiveBorder = "#2c3038"
        public var divider = "#2c3038"
        public var headerBackground = "#15171b"
        public var headerActiveBackground = "#1f2430"
        public var headerText = "#8a919c"
        public var headerActiveText = "#e6e9ee"
        public var activity = "#e5c07b"
        public var bell = "#e06c75"
        public var exited = "#6c7480"
        public var sidebarBackground = "#12141899"
        public var sidebarSelection = "#1f2430"
        public var warning = "#e5c07b"
        public var ansi: [String] = [
            "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
            "#5c6370", "#ef7a85", "#a8d38b", "#f0cc8a", "#74baf5", "#d391e6", "#6bc6d1", "#ffffff",
        ]

        public init() {}
        public init(from decoder: Decoder) throws {
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
    public struct History: Codable, Equatable {
        public var isolate = true
        public var size: Int? = nil
        public var saveSize: Int? = nil
        /// Append a terminal's commands to the user's real history file when it exits, so
        /// isolation does not mean losing them.
        public var mergeToGlobalOnExit = true
        /// A user who deliberately set `setopt share_history` keeps one shared history.
        public var respectShareHistory = true
        public var exportHistfileForUnknownShells = true
        public var retentionDays = 30

        public init() {}
        public init(from decoder: Decoder) throws {
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

    public struct StartupCommands: Codable, Equatable {
        /// "shim" runs them from the shell before the first prompt; "typed" sends keystrokes.
        public var mode = "shim"
        public var echo = true
        public var recordInHistory = true
        /// Ask before running them when a workspace or the last session is opened.
        public var askBeforeRunning = true

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
            echo = try c.decodeIfPresent(Bool.self, forKey: .echo) ?? echo
            recordInHistory = try c.decodeIfPresent(Bool.self, forKey: .recordInHistory) ?? recordInHistory
            askBeforeRunning = try c.decodeIfPresent(Bool.self, forKey: .askBeforeRunning) ?? askBeforeRunning
        }
    }

    /// The copy tools in the terminal list, and what they act on.
    public struct Copy: Codable, Equatable {
        /// Put a mouse selection on the clipboard the moment it is made.
        public var autoCopyOnSelect = false
        /// Show the copy tools above the New Terminal button.
        public var showTools = true
        /// Ask the shell to mark where each prompt, command and its output begin (OSC 133).
        /// Without this the command buttons fall back to what Termsie saw you type.
        public var commandMarks = true
        /// Drop the trailing blank lines and right-hand padding a terminal grid always has.
        public var trimCopiedText = true

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            autoCopyOnSelect = try c.decodeIfPresent(Bool.self, forKey: .autoCopyOnSelect) ?? autoCopyOnSelect
            showTools = try c.decodeIfPresent(Bool.self, forKey: .showTools) ?? showTools
            commandMarks = try c.decodeIfPresent(Bool.self, forKey: .commandMarks) ?? commandMarks
            trimCopiedText = try c.decodeIfPresent(Bool.self, forKey: .trimCopiedText) ?? trimCopiedText
        }
    }

    public struct Updates: Codable, Equatable {
        /// Look for a new release once a day, and offer to install it.
        public var checkAutomatically = true

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            checkAutomatically = try c.decodeIfPresent(Bool.self, forKey: .checkAutomatically) ?? checkAutomatically
        }
    }

    public struct Sidebar: Codable, Equatable {
        public var visible = true
        public var width: Double = 264
        public var rowHeight: Double = 84
        /// blocks | text | none
        public var thumbnailStyle = "blocks"
        public var thumbnailRefreshMs = 500

        public init() {}
        public init(from decoder: Decoder) throws {
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
    public struct EnvironmentStyle: Codable, Equatable {
        public var id = ""
        public var label = ""
        /// Hex tint, or nil for the untinted default.
        public var tint: String? = nil
        /// How far the terminal background is pulled toward the tint, 0...1.
        public var strength: Double = 0.22

        public init() {}
        public init(id: String, label: String, tint: String?, strength: Double = 0.22) {
            self.id = id; self.label = label; self.tint = tint; self.strength = strength
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? id
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? (id.isEmpty ? "" : id.capitalized)
            tint = try c.decodeIfPresent(String.self, forKey: .tint)
            strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        }
    }

    public var font = Font()
    /// Shell executable. `null` means `$SHELL`, falling back to /bin/zsh (pwsh, then Windows PowerShell, on Windows).
    public var shell: String? = nil
    public var shellArgs: [String] = TermsieConfig.defaultShellArgs
    public var scrollback: Int = 10_000
    /// How many lines of a terminal's output are kept when it closes and shown again when it
    /// reopens, including across quitting and reopening a workspace. 0 keeps nothing. A
    /// workspace can set its own.
    public var restoredOutputLines: Int = 1000
    /// "metal" (GPU, default) or "coregraphics".
    public var renderer: String = "metal"
    /// block | bar | underline, optionally prefixed with "blink" (e.g. "blinkBar").
    public var cursorStyle: String = "block"
    /// none | sound | visual | both
    public var bell: String = "visual"
    public var optionAsMeta: Bool = true
    public var showPaneHeaders: Bool = true
    /// always | clean | never — whether a pane closes automatically when its shell exits.
    public var closePaneOnExit: String = "clean"
    public var confirmClosingRunningProcess: Bool = true
    public var restoreSession: Bool = true
    /// Delay after the shell's first output (its prompt) before a workspace command is typed in.
    public var commandDelayMs: Int = 150
    /// Terminal background opacity, 0...1. Below 1 the window blur shows through.
    public var opacity: Double = 0.88
    /// Extra opacity for the focused terminal. Overlapping translucent terminals otherwise let
    /// you read the one behind through the one you are typing in. Set to 0 for uniform opacity.
    public var activeOpacityBoost: Double = 0.07
    /// Blur whatever is behind the window, the way Terminal.app does.
    public var blurBackground = true
    /// Corner radius of each floating terminal.
    public var cornerRadius: Double = 10
    /// Blank margin between a terminal's border and its text, in points. Individual terminals
    /// can override it.
    public var terminalPadding: Double = 0
    /// Whether a line longer than the terminal is wrapped onto the next row. Off, the grid is
    /// `unwrappedColumns` wide however narrow the terminal is, and scrolls sideways.
    public var lineWrap: Bool = true
    /// The column count a terminal reports while `lineWrap` is off. A terminal emulator throws
    /// away whatever runs past its last column, so "do not wrap" has to mean "be wider than the
    /// pane and scroll", and this is that width.
    public var unwrappedColumns: Int = 200
    /// Show the red/yellow/green buttons on each terminal.
    public var trafficLights = true
    /// Selectable environments. The first is the untinted default.
    public var environments: [EnvironmentStyle] = [
        EnvironmentStyle(id: "development", label: "Development", tint: "#61afef"),
        EnvironmentStyle(id: "staging", label: "Staging", tint: "#e5c07b"),
        EnvironmentStyle(id: "production", label: "Production", tint: "#e06c75", strength: 0.26),
    ]
    /// "auto" or "off". Off means terminals launch exactly as a plain shell would.
    public var shellIntegration = "auto"
    public var history = History()
    public var startupCommands = StartupCommands()
    public var copy = Copy()
    public var sidebar = Sidebar()
    public var updates = Updates()
    /// When the window is resized, scale the terminals with it. Off means they keep their size
    /// and position and only stay reachable inside the smaller window.
    public var resizeTerminalsWithWindow = true
    /// Quantize terminal resizes to whole character cells so the emulator only reflows when the
    /// grid actually changes.
    public var snapToCells = true
    public var colors = Colors()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = try c.decodeIfPresent(Font.self, forKey: .font) ?? font
        shell = try c.decodeIfPresent(String.self, forKey: .shell)
        shellArgs = try c.decodeIfPresent([String].self, forKey: .shellArgs) ?? shellArgs
        scrollback = try c.decodeIfPresent(Int.self, forKey: .scrollback) ?? scrollback
        restoredOutputLines = try c.decodeIfPresent(Int.self, forKey: .restoredOutputLines) ?? restoredOutputLines
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
        terminalPadding = try c.decodeIfPresent(Double.self, forKey: .terminalPadding) ?? terminalPadding
        lineWrap = try c.decodeIfPresent(Bool.self, forKey: .lineWrap) ?? lineWrap
        unwrappedColumns = try c.decodeIfPresent(Int.self, forKey: .unwrappedColumns) ?? unwrappedColumns
        trafficLights = try c.decodeIfPresent(Bool.self, forKey: .trafficLights) ?? trafficLights
        if let envs = try c.decodeIfPresent([EnvironmentStyle].self, forKey: .environments) {
            environments = envs
        }
        shellIntegration = try c.decodeIfPresent(String.self, forKey: .shellIntegration) ?? shellIntegration
        history = try c.decodeIfPresent(History.self, forKey: .history) ?? history
        startupCommands = try c.decodeIfPresent(StartupCommands.self, forKey: .startupCommands) ?? startupCommands
        copy = try c.decodeIfPresent(Copy.self, forKey: .copy) ?? copy
        sidebar = try c.decodeIfPresent(Sidebar.self, forKey: .sidebar) ?? sidebar
        updates = try c.decodeIfPresent(Updates.self, forKey: .updates) ?? updates
        resizeTerminalsWithWindow = try c.decodeIfPresent(Bool.self, forKey: .resizeTerminalsWithWindow) ?? resizeTerminalsWithWindow
        snapToCells = try c.decodeIfPresent(Bool.self, forKey: .snapToCells) ?? snapToCells
        colors = try c.decodeIfPresent(Colors.self, forKey: .colors) ?? colors
    }

    // MARK: Platform defaults

    #if os(Windows)
    public static let defaultFontFamily = "Cascadia Mono"
    /// pwsh and Windows PowerShell take no login flag; `-l` would be read as a script name.
    public static let defaultShellArgs: [String] = []
    #else
    public static let defaultFontFamily = "Menlo"
    public static let defaultShellArgs: [String] = ["-l"]
    #endif

    // MARK: Resolved values

    /// The most output lines a terminal can be told to keep between closing and reopening.
    public static let maxRestoredOutputLines = 100_000

    public static let minFontSize: Double = 6
    public static let maxFontSize: Double = 72

    public static let maxPadding: Double = 48
    public static let minUnwrappedColumns = 40
    public static let maxUnwrappedColumns = 2000

    /// The font family and size for a terminal, given its optional overrides. A nil field inherits
    /// the global one, which is what makes changing the global font move every terminal that has
    /// not opted out. Each platform turns this into its own font object.
    public func resolvedFontSpec(family: String?, size: Double?) -> (family: String, size: Double) {
        let name = (family?.isEmpty == false) ? family! : font.family
        let points = min(max(size ?? font.size, Self.minFontSize), Self.maxFontSize)
        return (name, points)
    }

    /// The padding for a terminal, given its optional override. `nil` inherits the global value,
    /// which is what makes changing the global setting move every terminal that has not opted out.
    public func resolvedPadding(_ override: Double?) -> CGFloat {
        CGFloat(min(max(override ?? terminalPadding, 0), Self.maxPadding))
    }

    /// Whether a terminal wraps, given its optional override.
    public func resolvedLineWrap(_ override: Bool?) -> Bool { override ?? lineWrap }

    public var resolvedUnwrappedColumns: Int {
        min(max(unwrappedColumns, Self.minUnwrappedColumns), Self.maxUnwrappedColumns)
    }

    /// `unwrappedColumns` seen as a Double, so the settings form needs only one numeric binding.
    /// Computed, so it stays out of `CodingKeys` and never reaches config.json.
    public var unwrappedColumnsValue: Double {
        get { Double(unwrappedColumns) }
        set { unwrappedColumns = Int(newValue.rounded()) }
    }

    /// `restoredOutputLines` as a Double, for the same reason.
    public var restoredOutputLinesValue: Double {
        get { Double(restoredOutputLines) }
        set { restoredOutputLines = Int(newValue.rounded()) }
    }

    public var resolvedShell: String {
        if let s = shell, !s.isEmpty { return s }
        #if os(Windows)
        return ShellLocator.defaultWindowsShell()
        #else
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        return "/bin/zsh"
        #endif
    }

    public var useMetal: Bool { renderer.lowercased() != "coregraphics" }

    public var terminalCursorStyle: CursorStyle {
        let s = cursorStyle.lowercased()
        let blink = s.hasPrefix("blink")
        if s.contains("bar") { return blink ? .blinkBar : .steadyBar }
        if s.contains("underline") { return blink ? .blinkUnderline : .steadyUnderline }
        return blink ? .blinkBlock : .steadyBlock
    }

    public var resolvedOpacity: CGFloat { CGFloat(min(max(opacity, 0.25), 1.0)) }

    public func resolvedOpacity(active: Bool) -> CGFloat {
        let boost = active ? max(activeOpacityBoost, 0) : 0
        return CGFloat(min(max(opacity + boost, 0.25), 1.0))
    }

    public func environment(_ id: String?) -> EnvironmentStyle? {
        guard let id, !id.isEmpty else { return nil }
        return environments.first { $0.id == id }
    }

    /// The terminal background for an environment: the configured background pulled toward the
    /// environment's tint. Opacity is applied by whoever draws it.
    public func backgroundRGBA(for environmentID: String?) -> RGBA {
        let base = RGBA.hex(colors.background)
        guard let env = environment(environmentID), let hex = env.tint,
              let tint = RGBA(hex: hex) else { return base }
        return base.blended(withFraction: min(max(env.strength, 0), 1), of: tint)
    }

    public var ansiColors: [SwiftTerm.Color] {
        colors.ansi.map { SwiftTerm.Color(hex: $0) ?? SwiftTerm.Color(red: 0, green: 0, blue: 0) }
    }
}

// MARK: - Colour

/// A colour in sRGB, 0...1 per channel. The portable stand-in for NSColor in everything the
/// config and the model compute; each platform converts at the point it draws.
public struct RGBA: Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `#rrggbb` or `#rrggbbaa`, the `#` optional.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 8 {
            self.init(r: Double((v >> 24) & 0xff) / 255, g: Double((v >> 16) & 0xff) / 255,
                      b: Double((v >> 8) & 0xff) / 255, a: Double(v & 0xff) / 255)
        } else {
            self.init(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255,
                      b: Double(v & 0xff) / 255, a: 1)
        }
    }

    public static func hex(_ hex: String, fallback: RGBA = RGBA(r: 1, g: 0, b: 1)) -> RGBA {
        RGBA(hex: hex) ?? fallback
    }

    /// Linear interpolation toward `other`, the same blend AppKit's `blended(withFraction:of:)` makes.
    public func blended(withFraction f: Double, of other: RGBA) -> RGBA {
        let t = min(max(f, 0), 1)
        return RGBA(r: r + (other.r - r) * t, g: g + (other.g - g) * t,
                    b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
        return a >= 1 ? base : base + String(format: "%02x", byte(a))
    }

    /// The xterm 256-colour palette: the configured 16, then the 6×6×6 cube, then the grey ramp.
    public static func ansi256(_ i: Int, palette: [RGBA]) -> RGBA {
        if i < 16, i < palette.count { return palette[i] }
        if i >= 232 {
            let level = Double(8 + 10 * (i - 232)) / 255
            return RGBA(r: level, g: level, b: level)
        }
        let levels: [Double] = [0, 95, 135, 175, 215, 255]
        let n = max(i - 16, 0)
        return RGBA(r: levels[(n / 36) % 6] / 255, g: levels[(n / 6) % 6] / 255, b: levels[n % 6] / 255)
    }
}

extension SwiftTerm.Color {
    public convenience init?(hex: String) {
        guard let c = RGBA(hex: hex) else { return nil }
        self.init(red8: UInt16((c.r * 255).rounded()), green8: UInt16((c.g * 255).rounded()),
                  blue8: UInt16((c.b * 255).rounded()))
    }
}

// MARK: - Store

/// Owns the on-disk config and knows the config directory layout. Each platform adds its own
/// file watcher and calls `reload()` when the file changes.
public final class ConfigStore {
    public static let shared = ConfigStore()

    public let configDir: URL
    public let configURL: URL
    public let workspacesDir: URL
    public let sessionURL: URL
    /// Per-terminal state: the shell shims and the private history file.
    public let panesDir: URL

    public private(set) var config: TermsieConfig

    private init() {
        configDir = ConfigStore.defaultConfigDirectory()
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

    /// `$XDG_CONFIG_HOME/termsie` when set. Otherwise `~/.config/termsie` on macOS, and
    /// `%APPDATA%\termsie` on Windows, which is where Windows users look for an app's settings.
    public static func defaultConfigDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("termsie", isDirectory: true)
        }
        #if os(Windows)
        if let appData = environment["APPDATA"], !appData.isEmpty {
            return URL(fileURLWithPath: appData, isDirectory: true).appendingPathComponent("termsie", isDirectory: true)
        }
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config").appendingPathComponent("termsie", isDirectory: true)
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
        write(TermsieConfig(), to: url)
    }

    /// Applies a change and writes config.json back.
    ///
    /// The file watcher will see our own write and call `reload()`, which compares the decoded
    /// result against what we already hold and does nothing — so this cannot loop.
    public func update(_ transform: (inout TermsieConfig) -> Void) {
        var updated = config
        transform(&updated)
        guard updated != config else { return }
        config = updated
        ConfigStore.write(updated, to: configURL)
        NotificationCenter.default.post(name: .termsieConfigChanged, object: self)
    }

    @discardableResult
    public static func write(_ config: TermsieConfig, to url: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Termsie: could not write config.json: \(error)")
            return false
        }
    }

    public func reload() {
        let fresh = ConfigStore.load(from: configURL) ?? TermsieConfig()
        guard fresh != config else { return }
        config = fresh
        NotificationCenter.default.post(name: .termsieConfigChanged, object: self)
    }
}
