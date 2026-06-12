import Foundation

/// A reusable tab layout: the split structure plus what KIND of pane goes in
/// each slot (not specific pane instances). Saved from a live tab, applied as
/// a new tab with freshly spawned panes.
struct LayoutTemplate: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var node: TemplateNode
}

indirect enum TemplateNode: Codable, Equatable {
    /// directory nil = the workspace's base repo at apply time.
    case pane(kind: PaneKind, directory: String?, url: String?)
    case split(axis: SplitAxis, children: [TemplateNode], fractions: [Double])

    private enum CodingKeys: String, CodingKey { case type, kind, directory, url, axis, children, fractions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .type) == "pane" {
            self = .pane(
                kind: try c.decode(PaneKind.self, forKey: .kind),
                directory: try c.decodeIfPresent(String.self, forKey: .directory),
                url: try c.decodeIfPresent(String.self, forKey: .url))
        } else {
            self = .split(
                axis: try c.decode(SplitAxis.self, forKey: .axis),
                children: try c.decode([TemplateNode].self, forKey: .children),
                fractions: try c.decode([Double].self, forKey: .fractions))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let kind, let directory, let url):
            try c.encode("pane", forKey: .type)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(directory, forKey: .directory)
            try c.encodeIfPresent(url, forKey: .url)
        case .split(let axis, let children, let fractions):
            try c.encode("split", forKey: .type)
            try c.encode(axis, forKey: .axis)
            try c.encode(children, forKey: .children)
            try c.encode(fractions, forKey: .fractions)
        }
    }
}
