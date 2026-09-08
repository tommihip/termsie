import Foundation

/// Converts v1 split-tree layouts into v2 terminal definitions.
///
/// The subdivision mirrors the old split view's sizing arithmetic but in unit space, so an
/// old workspace opens as floating terminals sitting exactly where its split panes used to be.
enum LegacyMigration {
    /// Flattens a split tree in reading order. Traversal order fixes both the sidebar order and `z`.
    static func definitions(from node: LayoutNode) -> [TerminalDefinition] {
        var out: [TerminalDefinition] = []
        flatten(node, into: NSRect(x: 0, y: 0, width: 1, height: 1), &out)
        for i in out.indices { out[i].z = i }
        return out
    }

    static func tabLayout(from node: LayoutNode) -> TabLayout {
        TabLayout(terminals: definitions(from: node))
    }

    private static func flatten(_ node: LayoutNode, into rect: NSRect, _ out: inout [TerminalDefinition]) {
        switch node {
        case .pane(let spec):
            var def = TerminalDefinition(
                name: spec.title,
                cwd: spec.cwd,
                startupCommands: spec.command.map { [$0] } ?? [],
                frame: rect)
            def.openOnRestore = true
            out.append(def)

        case .split(let orientation, let sizes, let children):
            guard !children.isEmpty else { return }
            let f = normalized(sizes, count: children.count)
            var offset: CGFloat = 0
            for (i, child) in children.enumerated() {
                // The last child absorbs rounding, exactly as applyLayout does.
                let length = (i == children.count - 1) ? max(0, 1 - offset) : CGFloat(f[i])
                let sub: NSRect
                switch orientation {
                case .horizontal:
                    sub = NSRect(x: rect.minX + offset * rect.width, y: rect.minY,
                                 width: length * rect.width, height: rect.height)
                case .vertical:
                    sub = NSRect(x: rect.minX, y: rect.minY + offset * rect.height,
                                 width: rect.width, height: length * rect.height)
                }
                flatten(child, into: sub, &out)
                offset += length
            }
        }
    }

    private static func normalized(_ sizes: [Double], count: Int) -> [Double] {
        guard sizes.count == count, !sizes.contains(where: { $0 <= 0 }) else {
            return Array(repeating: 1.0 / Double(max(count, 1)), count: count)
        }
        let sum = sizes.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1.0 / Double(max(count, 1)), count: count) }
        return sizes.map { $0 / sum }
    }
}
