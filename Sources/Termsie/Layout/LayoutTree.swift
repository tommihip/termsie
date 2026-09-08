import Foundation

// MARK: - Legacy v1 layout format
//
// Termsie once laid terminals out as a nested split tree. That format survives here for one reason
// only: opening workspace and session files written before the floating canvas existed.
// `LegacyMigration` converts these into `TerminalDefinition`s.
//
// These types are deliberately `Decodable`, not `Codable` — the compiler now prevents anything from
// writing a v1 file by accident.

enum SplitOrientation: String, Decodable {
    /// Children side by side (left/right).
    case horizontal
    /// Children stacked (top/bottom).
    case vertical
}

/// A leaf of the old split tree.
struct PaneSpec: Decodable, Equatable {
    var title: String?
    var cwd: String?
    var command: String?
}

/// The old split tree. Read-only; see the note above.
indirect enum LayoutNode: Decodable, Equatable {
    case pane(PaneSpec)
    case split(orientation: SplitOrientation, sizes: [Double], children: [LayoutNode])

    private enum CodingKeys: String, CodingKey { case type, title, cwd, command, orientation, sizes, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "pane"
        switch type {
        case "split":
            let orientation = try c.decodeIfPresent(SplitOrientation.self, forKey: .orientation) ?? .horizontal
            let children = try c.decode([LayoutNode].self, forKey: .children)
            var sizes = try c.decodeIfPresent([Double].self, forKey: .sizes) ?? []
            if sizes.count != children.count || sizes.contains(where: { $0 <= 0 }) {
                sizes = Array(repeating: 1.0 / Double(max(children.count, 1)), count: children.count)
            }
            self = .split(orientation: orientation, sizes: sizes, children: children)
        default:
            self = .pane(PaneSpec(
                title: try c.decodeIfPresent(String.self, forKey: .title),
                cwd: try c.decodeIfPresent(String.self, forKey: .cwd),
                command: try c.decodeIfPresent(String.self, forKey: .command)))
        }
    }
}
