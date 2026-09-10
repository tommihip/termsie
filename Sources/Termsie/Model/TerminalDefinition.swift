import Foundation

/// A terminal as a persistent, named thing: its settings, its place on the canvas, and its identity.
///
/// The `id` is deliberately used for three purposes at once — sidebar row identity, canvas identity,
/// and the shell history key — which is what lets a terminal's command history survive being closed,
/// reopened, and relaunched.
struct TerminalDefinition: Codable, Equatable {
    /// Stable across close/reopen/relaunch. Also names this terminal's history directory.
    var id: String
    /// `nil` means "derive from the running process", matching the pane header's own fallback chain.
    var name: String?
    /// The *configured* startup directory, stored tilde-preserving. Never overwritten by the live cwd.
    var cwd: String?
    /// Commands run once, in order, when the terminal opens.
    var startupCommands: [String] = []
    /// Whether `startupCommands` run again when the terminal is reopened or the session is restored.
    var runCommandsOnReopen: Bool = true
    /// Whether this terminal gets its own shell history file.
    var isolatedHistory: Bool = true
    /// Font overrides. Either may be nil to inherit the corresponding global setting.
    var fontFamily: String?
    var fontSize: Double?
    /// Which configured environment this terminal belongs to, tinting its background.
    /// `nil` or an unknown id means the untinted default.
    var environment: String?
    /// Blank margin between this terminal's border and its text, in points. `nil` inherits.
    var padding: Double?
    /// Whether long lines wrap in this terminal. `nil` inherits the global setting.
    var lineWrap: Bool?
    /// Position on the canvas as `[x, y, width, height]`, fractional 0...1, top-left origin.
    /// Fractional so a layout saved on a large display still opens sensibly on a laptop.
    var frame: [Double]?
    /// Canvas stacking order, back to front. Independent of sidebar order.
    var z: Int = 0
    /// Whether this terminal was live when the session was saved.
    var openOnRestore: Bool = true

    init(id: String = TerminalDefinition.newID(),
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

    static func newID() -> String {
        "t-" + UUID().uuidString.lowercased().prefix(18)
    }

    /// Tolerant decode, mirroring `TermsieConfig`: every key optional, every absence a default.
    /// A hand-written `{"cwd": "~/src/api"}` must still produce a usable terminal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? TerminalDefinition.newID()
        name = try c.decodeIfPresent(String.self, forKey: .name)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        startupCommands = try c.decodeIfPresent([String].self, forKey: .startupCommands) ?? []
        runCommandsOnReopen = try c.decodeIfPresent(Bool.self, forKey: .runCommandsOnReopen) ?? true
        isolatedHistory = try c.decodeIfPresent(Bool.self, forKey: .isolatedHistory) ?? true
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
    var fractionalFrame: NSRect? {
        get {
            guard let f = frame, f.count == 4 else { return nil }
            return NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        set { frame = newValue.map { [$0.minX, $0.minY, $0.width, $0.height] } }
    }

    /// Display name when no live pane can supply a better one.
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let dir = cwd, !dir.isEmpty {
            let base = ((dir as NSString).expandingTildeInPath as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return "shell"
    }

    /// True when this terminal uses the global font rather than its own.
    var usesGlobalFont: Bool { fontFamily == nil && fontSize == nil }

    /// Commands to send on open, honoring `runCommandsOnReopen`.
    func commands(isReopen: Bool) -> [String] {
        if isReopen && !runCommandsOnReopen { return [] }
        return startupCommands.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
    }
}

/// One tab's worth of terminals. This replaces `LayoutNode` as the persisted layout unit.
struct TabLayout: Codable, Equatable {
    static let currentVersion = 2

    var version: Int = TabLayout.currentVersion
    var terminals: [TerminalDefinition] = []
    /// Id of the terminal that was focused.
    var selected: String?
    /// The workspace this tab came from, so session restore can keep the association.
    var workspaceName: String?

    init(terminals: [TerminalDefinition] = [], selected: String? = nil, workspaceName: String? = nil) {
        self.terminals = terminals
        self.selected = selected
        self.workspaceName = workspaceName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? TabLayout.currentVersion
        terminals = try c.decodeIfPresent([TerminalDefinition].self, forKey: .terminals) ?? []
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
    }

    /// A comparable form used to decide whether a workspace has unsaved changes.
    ///
    /// Stacking order and focus deliberately do not count: both change every time you click a
    /// terminal, and treating that as an edit would leave every workspace permanently "modified".
    func modificationSignature() -> String {
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

    var isEmpty: Bool { terminals.isEmpty }

    /// A copy with startup commands removed, for the cases that must not re-run anything.
    func strippingCommands() -> TabLayout {
        var copy = self
        for i in copy.terminals.indices { copy.terminals[i].startupCommands = [] }
        return copy
    }

    /// A copy with fresh ids, so opening the same workspace twice does not make two live
    /// terminals share one history file.
    func regeneratingIDs() -> TabLayout {
        var copy = self
        var remap: [String: String] = [:]
        for i in copy.terminals.indices {
            let fresh = TerminalDefinition.newID()
            remap[copy.terminals[i].id] = fresh
            copy.terminals[i].id = fresh
        }
        copy.selected = copy.selected.flatMap { remap[$0] }
        return copy
    }

    static func single(cwd: String? = nil) -> TabLayout {
        TabLayout(terminals: [TerminalDefinition(cwd: cwd, frame: NSRect(x: 0, y: 0, width: 1, height: 1))])
    }
}
