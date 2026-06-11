import Foundation

enum FocusDirection {
    case left, right, up, down
}

enum SplitAxis: String, Codable {
    case horizontal // children side by side (columns)
    case vertical   // children stacked (rows)
}

/// Binary-ish split tree: a node is either a single pane or a split containing
/// any number of children with proportional sizes. Supports arbitrary nesting
/// of rows, columns, and combinations.
indirect enum LayoutNode: Codable, Equatable {
    case pane(UUID)
    case split(axis: SplitAxis, children: [LayoutNode], fractions: [Double])

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case type, paneID, axis, children, fractions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        if type == "pane" {
            self = .pane(try c.decode(UUID.self, forKey: .paneID))
        } else {
            self = .split(
                axis: try c.decode(SplitAxis.self, forKey: .axis),
                children: try c.decode([LayoutNode].self, forKey: .children),
                fractions: try c.decode([Double].self, forKey: .fractions)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id):
            try c.encode("pane", forKey: .type)
            try c.encode(id, forKey: .paneID)
        case .split(let axis, let children, let fractions):
            try c.encode("split", forKey: .type)
            try c.encode(axis, forKey: .axis)
            try c.encode(children, forKey: .children)
            try c.encode(fractions, forKey: .fractions)
        }
    }

    // MARK: Queries

    var paneIDs: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, let children, _): return children.flatMap { $0.paneIDs }
        }
    }

    func contains(_ id: UUID) -> Bool { paneIDs.contains(id) }

    // MARK: Mutations (value-semantics: each returns a new tree)

    /// Split the pane `target`, inserting `newPane` beside it along `axis`.
    /// If the parent split already runs along `axis`, the new pane is inserted
    /// as a sibling; otherwise the target becomes a nested split.
    func splitting(target: UUID, with newPane: UUID, axis: SplitAxis) -> LayoutNode {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            return .split(axis: axis, children: [.pane(id), .pane(newPane)], fractions: [0.5, 0.5])
        case .split(let a, var children, var fractions):
            if a == axis, let idx = children.firstIndex(where: {
                if case .pane(let pid) = $0 { return pid == target } else { return false }
            }) {
                // Insert as sibling: halve the target's share.
                let share = fractions[idx] / 2
                fractions[idx] = share
                children.insert(.pane(newPane), at: idx + 1)
                fractions.insert(share, at: idx + 1)
                return .split(axis: a, children: children, fractions: fractions)
            }
            let newChildren = children.map { $0.splitting(target: target, with: newPane, axis: axis) }
            return .split(axis: a, children: newChildren, fractions: fractions)
        }
    }

    /// Remove a pane. Returns nil if the tree becomes empty. Collapses
    /// single-child splits so the tree stays minimal.
    func removing(_ target: UUID) -> LayoutNode? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(let axis, let children, let fractions):
            var newChildren: [LayoutNode] = []
            var newFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removing(target) {
                    newChildren.append(kept)
                    newFractions.append(fraction)
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }
            // Renormalize fractions to sum to 1.
            let total = newFractions.reduce(0, +)
            if total > 0 { newFractions = newFractions.map { $0 / total } }
            return .split(axis: axis, children: newChildren, fractions: newFractions)
        }
    }

    /// Approximate frame of every pane in a unit-square coordinate space
    /// (divider thickness ignored — close enough for spatial navigation).
    func paneFrames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
        switch self {
        case .pane(let id):
            return [id: rect]
        case .split(let axis, let children, let fractions):
            var result: [UUID: CGRect] = [:]
            var offset: CGFloat = 0
            for (idx, child) in children.enumerated() {
                let f = CGFloat(fractions.indices.contains(idx) ? fractions[idx] : 1.0 / Double(children.count))
                let childRect: CGRect
                if axis == .horizontal {
                    childRect = CGRect(x: rect.minX + offset * rect.width, y: rect.minY,
                                       width: f * rect.width, height: rect.height)
                } else {
                    childRect = CGRect(x: rect.minX, y: rect.minY + offset * rect.height,
                                       width: rect.width, height: f * rect.height)
                }
                result.merge(child.paneFrames(in: childRect)) { a, _ in a }
                offset += f
            }
            return result
        }
    }

    /// Spatially nearest pane in a direction from `from` — what ⌥⌘-arrows use.
    func neighbor(of from: UUID, direction: FocusDirection) -> UUID? {
        let frames = paneFrames()
        guard let origin = frames[from] else { return nil }
        let oc = CGPoint(x: origin.midX, y: origin.midY)

        func measure(_ frame: CGRect) -> (primary: CGFloat, secondary: CGFloat) {
            let c = CGPoint(x: frame.midX, y: frame.midY)
            switch direction {
            case .left:  return (oc.x - c.x, abs(c.y - oc.y))
            case .right: return (c.x - oc.x, abs(c.y - oc.y))
            case .up:    return (oc.y - c.y, abs(c.x - oc.x))
            case .down:  return (c.y - oc.y, abs(c.x - oc.x))
            }
        }

        func pick(requireCone: Bool) -> UUID? {
            var best: (id: UUID, score: CGFloat)?
            for (id, frame) in frames where id != from {
                let (primary, secondary) = measure(frame)
                guard primary > 0.001 else { continue } // must be in that direction
                // Cone: mostly-in-direction beats merely-in-direction, so
                // "right" never jumps to the pane below-right when a pane
                // sits straight right.
                if requireCone && secondary > primary + 0.001 { continue }
                let score = primary + secondary
                if best == nil || score < best!.score - 0.001
                    || (abs(score - best!.score) <= 0.001 && id.uuidString < best!.id.uuidString) {
                    best = (id, score)
                }
            }
            return best?.id
        }

        return pick(requireCone: true) ?? pick(requireCone: false)
    }

    /// Adjust the divider after child `index` in the split that directly
    /// contains it, moving `delta` (fraction of the split's full extent).
    func resizing(splitPath: [Int], dividerIndex: Int, delta: Double) -> LayoutNode {
        guard case .split(let axis, var children, var fractions) = self else { return self }
        if splitPath.isEmpty {
            guard dividerIndex >= 0, dividerIndex + 1 < fractions.count else { return self }
            let minSize = 0.05
            let moved = max(min(delta, fractions[dividerIndex + 1] - minSize), -(fractions[dividerIndex] - minSize))
            fractions[dividerIndex] += moved
            fractions[dividerIndex + 1] -= moved
            return .split(axis: axis, children: children, fractions: fractions)
        }
        let head = splitPath[0]
        guard head >= 0, head < children.count else { return self }
        children[head] = children[head].resizing(splitPath: Array(splitPath.dropFirst()), dividerIndex: dividerIndex, delta: delta)
        return .split(axis: axis, children: children, fractions: fractions)
    }
}
