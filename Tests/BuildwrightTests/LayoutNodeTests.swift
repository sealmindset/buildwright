import Testing
import Foundation
@testable import Buildwright

struct LayoutNodeTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func splitSinglePane() throws {
        let tree = LayoutNode.pane(a).splitting(target: a, with: b, axis: .horizontal)
        guard case .split(let axis, let children, let fractions) = tree else {
            Issue.record("expected split"); return
        }
        #expect(axis == .horizontal)
        #expect(children.count == 2)
        #expect(fractions == [0.5, 0.5])
        #expect(tree.paneIDs == [a, b])
    }

    @Test func splitSameAxisInsertsSibling() throws {
        var tree = LayoutNode.pane(a).splitting(target: a, with: b, axis: .horizontal)
        tree = tree.splitting(target: b, with: c, axis: .horizontal)
        guard case .split(_, let children, let fractions) = tree else {
            Issue.record("expected split"); return
        }
        #expect(children.count == 3, "same-axis split should flatten into siblings")
        #expect(abs(fractions.reduce(0, +) - 1.0) < 0.0001)
        #expect(tree.paneIDs == [a, b, c])
    }

    @Test func splitCrossAxisNests() throws {
        var tree = LayoutNode.pane(a).splitting(target: a, with: b, axis: .horizontal)
        tree = tree.splitting(target: b, with: c, axis: .vertical)
        guard case .split(let axis, let children, _) = tree else { Issue.record("expected split"); return }
        #expect(axis == .horizontal)
        guard case .split(let innerAxis, let innerChildren, _) = children[1] else {
            Issue.record("expected nested split"); return
        }
        #expect(innerAxis == .vertical)
        #expect(innerChildren.count == 2)
    }

    @Test func removeCollapsesSingleChildSplit() throws {
        var tree = LayoutNode.pane(a).splitting(target: a, with: b, axis: .horizontal)
        tree = tree.splitting(target: b, with: c, axis: .vertical)
        let removed = tree.removing(c)
        #expect(removed?.paneIDs == [a, b])
        guard case .split(_, let children, _) = removed else { Issue.record("expected split"); return }
        if case .split = children[1] { Issue.record("single-child split should collapse") }
    }

    @Test func removeLastPaneReturnsNil() {
        #expect(LayoutNode.pane(a).removing(a) == nil)
    }

    @Test func removeRenormalizesFractions() throws {
        var tree = LayoutNode.pane(a).splitting(target: a, with: b, axis: .horizontal)
        tree = tree.splitting(target: b, with: c, axis: .horizontal)
        let removed = tree.removing(b)
        guard case .split(_, _, let fractions) = removed else { Issue.record("expected split"); return }
        #expect(abs(fractions.reduce(0, +) - 1.0) < 0.0001)
    }

    @Test func resizeMovesDividerWithinBounds() throws {
        let tree = LayoutNode.pane(a).splitting(target: a, with: b, axis: .horizontal)
        let resized = tree.resizing(splitPath: [], dividerIndex: 0, delta: 0.2)
        guard case .split(_, _, let fractions) = resized else { Issue.record("expected split"); return }
        #expect(abs(fractions[0] - 0.7) < 0.0001)
        #expect(abs(fractions[1] - 0.3) < 0.0001)
        let extreme = resized.resizing(splitPath: [], dividerIndex: 0, delta: 0.9)
        guard case .split(_, _, let f2) = extreme else { Issue.record("expected split"); return }
        #expect(f2[1] >= 0.049)
    }

    @Test func codableRoundTrip() throws {
        var tree = LayoutNode.pane(a).splitting(target: a, with: b, axis: .horizontal)
        tree = tree.splitting(target: b, with: c, axis: .vertical)
        tree = tree.splitting(target: c, with: d, axis: .horizontal)
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        #expect(decoded == tree)
    }
}
