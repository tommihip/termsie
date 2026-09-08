import Foundation

/// A named layout: the terminals of one tab, with their folders and startup commands.
struct Workspace: Codable {
    // Declared explicitly: writing both coder halves suppresses synthesis.
    private enum CodingKeys: String, CodingKey { case version, name, layout }

    var version: Int = TabLayout.currentVersion
    var name: String
    var layout: TabLayout

    init(name: String, layout: TabLayout) {
        self.name = name
        self.layout = layout
    }

    /// Decodes both v2 (`terminals`) and v1 (`layout` as a split tree).
    ///
    /// The version gate is load-bearing, not cosmetic: `LayoutNode` decodes a missing `type` as
    /// `"pane"` and treats every field as optional, so a v2 payload would decode *successfully* as
    /// one empty pane. Sniffing shapes instead of versions would silently discard the user's data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if version >= 2 {
            layout = try c.decodeIfPresent(TabLayout.self, forKey: .layout) ?? TabLayout()
        } else {
            let legacy = try c.decode(LayoutNode.self, forKey: .layout)
            layout = LegacyMigration.tabLayout(from: legacy)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(TabLayout.currentVersion, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(layout, forKey: .layout)
    }
}

/// One tab, in either format.
///
/// Sniffing shapes is not optional here: every `TabLayout` key is optional, so a v1 split tree
/// decodes as an *empty* v2 tab rather than failing. Discriminating on which keys are present is
/// the only way to tell them apart without silently discarding the user's layout.
private struct TabEntry: Decodable {
    let layout: TabLayout

    private enum Probe: String, CodingKey { case terminals, type, children }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: Probe.self),
           c.contains(.terminals) || !(c.contains(.type) || c.contains(.children)) {
            layout = try TabLayout(from: decoder)
        } else {
            layout = LegacyMigration.tabLayout(from: try LayoutNode(from: decoder))
        }
    }
}

/// Everything needed to bring back the open windows on next launch.
struct SessionSnapshot: Codable {
    struct WindowSnapshot: Codable {
        private enum CodingKeys: String, CodingKey {
            case frame, tabs, selectedTab, sidebarVisible, sidebarWidth
        }

        var frame: [Double]
        var tabs: [TabLayout]
        var selectedTab: Int
        var sidebarVisible: Bool?
        var sidebarWidth: Double?

        init(frame: [Double], tabs: [TabLayout], selectedTab: Int,
             sidebarVisible: Bool? = nil, sidebarWidth: Double? = nil) {
            self.frame = frame
            self.tabs = tabs
            self.selectedTab = selectedTab
            self.sidebarVisible = sidebarVisible
            self.sidebarWidth = sidebarWidth
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            frame = try c.decodeIfPresent([Double].self, forKey: .frame) ?? []
            selectedTab = try c.decodeIfPresent(Int.self, forKey: .selectedTab) ?? 0
            sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible)
            sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth)
            tabs = (try c.decodeIfPresent([TabEntry].self, forKey: .tabs) ?? []).map(\.layout)
        }
    }

    private enum CodingKeys: String, CodingKey { case version, windows }

    var version: Int = TabLayout.currentVersion
    var windows: [WindowSnapshot]

    init(windows: [WindowSnapshot]) { self.windows = windows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        windows = try c.decodeIfPresent([WindowSnapshot].self, forKey: .windows) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(TabLayout.currentVersion, forKey: .version)
        try c.encode(windows, forKey: .windows)
    }
}

enum WorkspaceStore {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func url(for name: String) -> URL {
        ConfigStore.shared.workspacesDir.appendingPathComponent(name).appendingPathExtension("json")
    }

    static func list() -> [String] {
        let dir = ConfigStore.shared.workspacesDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func load(name: String) throws -> Workspace {
        let data = try Data(contentsOf: url(for: name))
        var ws = try JSONDecoder().decode(Workspace.self, from: data)
        if ws.name.isEmpty { ws.name = name }
        return ws
    }

    static func load(fileURL: URL) throws -> Workspace {
        let data = try Data(contentsOf: fileURL)
        var ws = try JSONDecoder().decode(Workspace.self, from: data)
        if ws.name.isEmpty { ws.name = fileURL.deletingPathExtension().lastPathComponent }
        return ws
    }

    static func save(_ workspace: Workspace) throws {
        var ws = workspace
        ws.name = workspace.name.replacingOccurrences(of: "/", with: "-")
        try encoder.encode(ws).write(to: url(for: ws.name), options: .atomic)
    }

    // MARK: Session

    private static var sessionWork: DispatchWorkItem?

    /// Debounced: the sidebar changes state far more often than the old layout did.
    static func scheduleSessionSave(_ provider: @escaping () -> SessionSnapshot) {
        sessionWork?.cancel()
        let work = DispatchWorkItem { saveSession(provider()) }
        sessionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    static func saveSession(_ snapshot: SessionSnapshot) {
        sessionWork?.cancel()
        sessionWork = nil
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: ConfigStore.shared.sessionURL, options: .atomic)
    }

    static func loadSession() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: ConfigStore.shared.sessionURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    static func clearSession() {
        sessionWork?.cancel()
        sessionWork = nil
        try? FileManager.default.removeItem(at: ConfigStore.shared.sessionURL)
    }
}
