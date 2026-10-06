import Foundation
import TermsieCore

protocol TerminalRegistryDelegate: AnyObject {
    func registryDidChangeOrder(_ registry: TerminalRegistry)
    func registry(_ registry: TerminalRegistry, didChange id: String)
    func registry(_ registry: TerminalRegistry, didOpen id: String, pane: Pane)
    func registry(_ registry: TerminalRegistry, didClose id: String)
    func registryBecameEmpty(_ registry: TerminalRegistry)
    func registryDidChangeSettings(_ registry: TerminalRegistry)
}

/// The terminals belonging to one tab: the definition list, its order, and the mapping from a
/// definition to its live pane. The same contract as the macOS registry.
///
/// Sidebar order lives in `order`; canvas stacking lives in each definition's `z`. They are kept
/// separate on purpose, otherwise clicking a terminal would reshuffle the list.
final class TerminalRegistry {
    weak var delegate: TerminalRegistryDelegate?

    private(set) var order: [String] = []
    private var defs: [String: TerminalDefinition] = [:]
    private var live: [String: Pane] = [:]
    var settings = WorkspaceSettings() {
        didSet { if settings != oldValue { delegate?.registryDidChangeSettings(self) } }
    }

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }
    var definitions: [TerminalDefinition] { order.compactMap { defs[$0] } }
    var livePanes: [Pane] { order.compactMap { live[$0] } }
    var openCount: Int { live.count }

    func definition(_ id: String) -> TerminalDefinition? { defs[id] }

    /// The definition with the workspace defaults folded in: what the terminal looks like.
    func effectiveDefinition(_ id: String) -> TerminalDefinition? {
        defs[id].map { settings.applied(to: $0) }
    }

    func environmentVariables(for id: String) -> (values: [String: String], missing: [String]) {
        EnvVar.resolve([settings.env, defs[id]?.env ?? []])
    }

    func pane(for id: String) -> Pane? { live[id] }
    func isOpen(_ id: String) -> Bool { live[id] != nil }
    func index(of id: String) -> Int? { order.firstIndex(of: id) }
    func id(at index: Int) -> String? { index >= 0 && index < order.count ? order[index] : nil }
    func number(of id: String) -> Int { (index(of: id) ?? 0) + 1 }
    var maxZ: Int { defs.values.map(\.z).max() ?? 0 }

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

    func mutate(_ id: String, _ body: (inout TerminalDefinition) -> Void) {
        guard var def = defs[id] else { return }
        body(&def)
        def.id = id
        defs[id] = def
        delegate?.registry(self, didChange: id)
    }

    /// Updates geometry without announcing a change: it is the canvas's own bookkeeping.
    func setGeometry(_ id: String, fraction: CGRect, z: Int) {
        guard var def = defs[id] else { return }
        def.fractionalFrame = fraction
        def.z = z
        defs[id] = def
    }

    func reorder(_ ids: [String]) {
        let known = ids.filter { defs[$0] != nil }
        let rest = order.filter { !known.contains($0) }
        let next = known + rest
        guard next != order else { return }
        order = next
        delegate?.registryDidChangeOrder(self)
    }

    func move(_ id: String, to index: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        var to = max(0, min(index, order.count))
        order.remove(at: from)
        if to > from { to -= 1 }
        order.insert(id, at: min(to, order.count))
        delegate?.registryDidChangeOrder(self)
    }

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

    func attach(_ pane: Pane, to id: String) {
        guard defs[id] != nil else { return }
        live[id] = pane
        delegate?.registry(self, didOpen: id, pane: pane)
    }

    func detach(_ id: String) {
        guard let pane = live.removeValue(forKey: id) else { return }
        pane.terminate()
        mutate(id) { $0.openOnRestore = false }
        delegate?.registry(self, didClose: id)
    }

    /// Captures the definitions for saving. `includeLiveState` folds each live terminal's
    /// actual folder and running command back in: only for an explicit Save As, never for the
    /// session, so a terminal's configured folder is never silently rewritten.
    func snapshot(selected: String?, includeLiveState: Bool = false) -> TabLayout {
        var out: [TerminalDefinition] = []
        for id in order {
            guard var def = defs[id] else { continue }
            def.openOnRestore = live[id] != nil
            if includeLiveState, let pane = live[id] {
                let snap = pane.liveSnapshot
                if let cwd = snap.cwd { def.cwd = HomePath.abbreviate(cwd) }
                if let cmd = snap.runningCommand, !def.startupCommands.contains(cmd) {
                    def.startupCommands.append(cmd)
                }
            }
            out.append(def)
        }
        return TabLayout(terminals: out, settings: settings, selected: selected)
    }

    func load(_ layout: TabLayout) {
        order.removeAll()
        defs.removeAll()
        live.removeAll()
        settings = layout.settings
        for def in layout.terminals {
            defs[def.id] = def
            order.append(def.id)
        }
        delegate?.registryDidChangeOrder(self)
    }
}
