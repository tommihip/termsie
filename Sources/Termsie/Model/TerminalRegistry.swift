import AppKit

protocol TerminalRegistryDelegate: AnyObject {
    /// The list itself changed: an insert, a delete, or a reorder.
    func registryDidChangeOrder(_ registry: TerminalRegistry)
    /// One terminal's displayed state changed; repaint just its row.
    func registry(_ registry: TerminalRegistry, didChange id: String)
    /// A terminal gained a live process.
    func registry(_ registry: TerminalRegistry, didOpen id: String, pane: TerminalPane)
    /// A terminal lost its process but kept its definition.
    func registry(_ registry: TerminalRegistry, didClose id: String)
    /// The last definition was deleted; the window has nothing left to show.
    func registryBecameEmpty(_ registry: TerminalRegistry)
}

/// The terminals belonging to one window (or tab). Owns the definition list, its order, and the
/// mapping from a definition to its live pane.
///
/// Sidebar order lives in `order`; canvas stacking lives in each definition's `z`. They are kept
/// separate on purpose — otherwise clicking a terminal would reshuffle the sidebar.
final class TerminalRegistry {
    weak var delegate: TerminalRegistryDelegate?

    private(set) var order: [String] = []
    private var defs: [String: TerminalDefinition] = [:]
    private var live: [String: TerminalPane] = [:]

    // MARK: Reading

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }
    var definitions: [TerminalDefinition] { order.compactMap { defs[$0] } }
    /// Live panes in sidebar order.
    var livePanes: [TerminalPane] { order.compactMap { live[$0] } }
    var openCount: Int { live.count }

    func definition(_ id: String) -> TerminalDefinition? { defs[id] }
    func pane(for id: String) -> TerminalPane? { live[id] }
    func isOpen(_ id: String) -> Bool { live[id] != nil }
    func index(of id: String) -> Int? { order.firstIndex(of: id) }
    func id(at index: Int) -> String? {
        index >= 0 && index < order.count ? order[index] : nil
    }

    /// 1-based position in the sidebar, which is what the pane number pill and ⌥⌘N show.
    func number(of id: String) -> Int { (index(of: id) ?? 0) + 1 }

    var maxZ: Int { defs.values.map(\.z).max() ?? 0 }

    // MARK: Writing

    @discardableResult
    func insert(_ def: TerminalDefinition, at index: Int? = nil) -> String {
        var def = def
        if defs[def.id] != nil { def.id = TerminalDefinition.newID() }
        defs[def.id] = def
        let i = index.map { max(0, min($0, order.count)) } ?? order.count
        order.insert(def.id, at: i)
        delegate?.registryDidChangeOrder(self)
        return def.id
    }

    func update(_ def: TerminalDefinition) {
        guard defs[def.id] != nil else { return }
        defs[def.id] = def
        delegate?.registry(self, didChange: def.id)
    }

    /// Mutate one definition in place without the caller having to round-trip it.
    func mutate(_ id: String, _ body: (inout TerminalDefinition) -> Void) {
        guard var def = defs[id] else { return }
        body(&def)
        def.id = id
        defs[id] = def
        delegate?.registry(self, didChange: id)
    }

    func move(_ id: String, to index: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        var to = max(0, min(index, order.count))
        order.remove(at: from)
        if to > from { to -= 1 }
        order.insert(id, at: min(to, order.count))
        delegate?.registryDidChangeOrder(self)
    }

    /// Removes the definition entirely, terminating its process if it has one.
    func remove(_ id: String) {
        if let pane = live[id] {
            pane.terminate()
            live.removeValue(forKey: id)
        }
        defs.removeValue(forKey: id)
        order.removeAll { $0 == id }
        delegate?.registryDidChangeOrder(self)
        if order.isEmpty { delegate?.registryBecameEmpty(self) }
    }

    // MARK: Live panes

    func attach(_ pane: TerminalPane, to id: String) {
        guard defs[id] != nil else { return }
        live[id] = pane
        delegate?.registry(self, didOpen: id, pane: pane)
    }

    /// "Closed" means the process is gone but the definition and its row stay.
    func detach(_ id: String) {
        guard let pane = live.removeValue(forKey: id) else { return }
        pane.terminate()
        mutate(id) { $0.openOnRestore = false }
        delegate?.registry(self, didClose: id)
    }

    func noteChanged(_ id: String) {
        delegate?.registry(self, didChange: id)
    }

    // MARK: Serialization

    /// Captures the current definitions for saving.
    /// - Parameter includeLiveState: fold each live pane's actual working directory and running
    ///   command back into its definition. Only true for an explicit "Save Workspace", never for
    ///   session autosave, so a terminal's configured folder is never silently rewritten.
    func snapshot(selected: String?, includeLiveState: Bool = false) -> TabLayout {
        var out: [TerminalDefinition] = []
        for id in order {
            guard var def = defs[id] else { continue }
            def.openOnRestore = live[id] != nil
            if includeLiveState, let pane = live[id] {
                let snap = pane.liveSnapshot
                if let cwd = snap.cwd { def.cwd = ProcessInspector.abbreviateHome(cwd) }
                if let cmd = snap.runningCommand, !def.startupCommands.contains(cmd) {
                    def.startupCommands.append(cmd)
                }
            }
            out.append(def)
        }
        return TabLayout(terminals: out, selected: selected)
    }

    /// Replaces the whole contents, used when a window is built from a layout.
    func load(_ layout: TabLayout) {
        order.removeAll()
        defs.removeAll()
        live.removeAll()
        for def in layout.terminals {
            defs[def.id] = def
            order.append(def.id)
        }
        delegate?.registryDidChangeOrder(self)
    }
}
