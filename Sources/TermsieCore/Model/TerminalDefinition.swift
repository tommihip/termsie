import Foundation

/// A terminal as a persistent, named thing: its settings, its place on the canvas, and its identity.
///
/// The `id` is deliberately used for three purposes at once — sidebar row identity, canvas identity,
/// and the shell history key — which is what lets a terminal's command history survive being closed,
/// reopened, and relaunched.
public struct TerminalDefinition: Codable, Equatable {
    /// Stable across close/reopen/relaunch. Also names this terminal's history directory.
    public var id: String
    /// `nil` means "derive from the running process", matching the pane header's own fallback chain.
    public var name: String?
    /// The *configured* startup directory, stored tilde-preserving. Never overwritten by the live cwd.
    public var cwd: String?
    /// Commands run once, in order, when the terminal opens.
    public var startupCommands: [String] = []
    /// Whether `startupCommands` run again when the terminal is reopened or the session is restored.
    public var runCommandsOnReopen: Bool = true
    /// Whether this terminal gets its own shell history file.
    public var isolatedHistory: Bool = true
    /// Set in this terminal's shell when it starts, whether or not the startup commands run.
    /// Overrides a workspace variable of the same name.
    public var env: [EnvVar] = []
    /// Font overrides. Either may be nil to inherit the corresponding global setting.
    public var fontFamily: String?
    public var fontSize: Double?
    /// Which configured environment this terminal belongs to, tinting its background.
    /// `nil` or an unknown id means the untinted default.
    public var environment: String?
    /// Blank margin between this terminal's border and its text, in points. `nil` inherits.
    public var padding: Double?
    /// Whether long lines wrap in this terminal. `nil` inherits the global setting.
    public var lineWrap: Bool?
    /// Position on the canvas as `[x, y, width, height]`, fractional 0...1, top-left origin.
    /// Fractional so a layout saved on a large display still opens sensibly on a laptop.
    public var frame: [Double]?
    /// Canvas stacking order, back to front. Independent of sidebar order.
    public var z: Int = 0
    /// Whether this terminal was live when the session was saved.
    public var openOnRestore: Bool = true

    public init(id: String = TerminalDefinition.newID(),
         name: String? = nil,
         cwd: String? = nil,
         startupCommands: [String] = [],
         frame: NSRect? = nil,
         z: Int = 0) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.startupCommands = startupCommands
        self.frame = frame.map { [$0.minX, $0.minY, $0.width, $0.height] }
        self.z = z
    }

    public static func newID() -> String {
        "t-" + UUID().uuidString.lowercased().prefix(18)
    }

    /// Tolerant decode, mirroring `TermsieConfig`: every key optional, every absence a default.
    /// A hand-written `{"cwd": "~/src/api"}` must still produce a usable terminal.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? TerminalDefinition.newID()
        name = try c.decodeIfPresent(String.self, forKey: .name)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        startupCommands = try c.decodeIfPresent([String].self, forKey: .startupCommands) ?? []
        runCommandsOnReopen = try c.decodeIfPresent(Bool.self, forKey: .runCommandsOnReopen) ?? true
        isolatedHistory = try c.decodeIfPresent(Bool.self, forKey: .isolatedHistory) ?? true
        env = try c.decodeIfPresent([EnvVar].self, forKey: .env) ?? []
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding)
        lineWrap = try c.decodeIfPresent(Bool.self, forKey: .lineWrap)
        z = try c.decodeIfPresent(Int.self, forKey: .z) ?? 0
        openOnRestore = try c.decodeIfPresent(Bool.self, forKey: .openOnRestore) ?? true
        if let f = try c.decodeIfPresent([Double].self, forKey: .frame), f.count == 4,
           f[2] > 0, f[3] > 0 {
            frame = f
        } else {
            frame = nil
        }
    }

    // MARK: Geometry

    /// The stored fractional frame, clamped into the unit square. `nil` when unset.
    public var fractionalFrame: NSRect? {
        get {
            guard let f = frame, f.count == 4 else { return nil }
            return NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        set { frame = newValue.map { [$0.minX, $0.minY, $0.width, $0.height] } }
    }

    /// Display name when no live pane can supply a better one.
    public var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let dir = cwd, !dir.isEmpty {
            let base = HomePath.lastComponent(HomePath.expand(dir))
            if !base.isEmpty { return base }
        }
        return "shell"
    }

    /// True when this terminal uses the global font rather than its own.
    public var usesGlobalFont: Bool { fontFamily == nil && fontSize == nil }

    /// Commands to send on open, honoring `runCommandsOnReopen`.
    public func commands(isReopen: Bool) -> [String] {
        if isReopen && !runCommandsOnReopen { return [] }
        return startupCommands.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
    }
}

/// One tab's worth of terminals. This replaces `LayoutNode` as the persisted layout unit.
public struct TabLayout: Codable, Equatable {
    public static let currentVersion = 2

    public var version: Int = TabLayout.currentVersion
    public var terminals: [TerminalDefinition] = []
    /// Defaults shared by every terminal in the tab, including its environment variables.
    public var settings = WorkspaceSettings()
    /// Id of the terminal that was focused.
    public var selected: String?
    /// The workspace this tab came from, so session restore can keep the association.
    public var workspaceName: String?

    public init(terminals: [TerminalDefinition] = [], settings: WorkspaceSettings = WorkspaceSettings(),
         selected: String? = nil, workspaceName: String? = nil) {
        self.terminals = terminals
        self.settings = settings
        self.selected = selected
        self.workspaceName = workspaceName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? TabLayout.currentVersion
        terminals = try c.decodeIfPresent([TerminalDefinition].self, forKey: .terminals) ?? []
        settings = try c.decodeIfPresent(WorkspaceSettings.self, forKey: .settings) ?? WorkspaceSettings()
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
    }

    /// A comparable form used to decide whether a workspace has unsaved changes.
    ///
    /// Stacking order and focus deliberately do not count: both change every time you click a
    /// terminal, and treating that as an edit would leave every workspace permanently "modified".
    public func modificationSignature() -> String {
        var copy = self
        copy.selected = nil
        copy.workspaceName = nil
        for i in copy.terminals.indices {
            copy.terminals[i].z = 0
            copy.terminals[i].frame = copy.terminals[i].frame?.map { ($0 * 1000).rounded() / 1000 }
        }
        copy.terminals.sort { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(copy) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public var isEmpty: Bool { terminals.isEmpty }

    /// Every Keychain reference this tab's secrets use.
    public var secretRefs: Set<String> {
        Set((settings.env + terminals.flatMap(\.env)).compactMap { $0.secret ? $0.secretRef : nil })
    }

    /// A copy with startup commands removed, for the cases that must not re-run anything.
    public func strippingCommands() -> TabLayout {
        var copy = self
        for i in copy.terminals.indices { copy.terminals[i].startupCommands = [] }
        return copy
    }

    /// A copy with fresh ids for the terminals whose id is in `taken` (all of them when nil), so
    /// opening the same workspace twice does not make two live terminals share one history file.
    /// Ids not taken are kept: they are what carries a terminal's history and output over.
    public func regeneratingIDs(avoiding taken: Set<String>? = nil) -> TabLayout {
        var copy = self
        var remap: [String: String] = [:]
        for i in copy.terminals.indices {
            if let taken, !taken.contains(copy.terminals[i].id) { continue }
            let fresh = TerminalDefinition.newID()
            remap[copy.terminals[i].id] = fresh
            copy.terminals[i].id = fresh
        }
        copy.selected = copy.selected.map { remap[$0] ?? $0 }
        return copy
    }

    public static func single(cwd: String? = nil) -> TabLayout {
        TabLayout(terminals: [TerminalDefinition(cwd: cwd, frame: NSRect(x: 0, y: 0, width: 1, height: 1))])
    }
}
