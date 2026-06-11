import Testing
import Foundation
@testable import Buildwright

struct SpatialNavTests {
    let a = UUID(), b = UUID(), c = UUID()

    /// Layout: [ a | b ] over c   (a,b side by side on top, c full-width below)
    var tree: LayoutNode {
        .split(axis: .vertical, children: [
            .split(axis: .horizontal, children: [.pane(a), .pane(b)], fractions: [0.5, 0.5]),
            .pane(c)
        ], fractions: [0.5, 0.5])
    }

    @Test func framesPartitionUnitSquare() {
        let frames = tree.paneFrames()
        #expect(frames.count == 3)
        #expect(frames[a] == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(frames[b] == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(frames[c] == CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
    }

    @Test func horizontalNeighbors() {
        #expect(tree.neighbor(of: a, direction: .right) == b)
        #expect(tree.neighbor(of: b, direction: .left) == a)
        #expect(tree.neighbor(of: a, direction: .left) == nil, "nothing to the left of a")
    }

    @Test func verticalNeighbors() {
        #expect(tree.neighbor(of: a, direction: .down) == c)
        #expect(tree.neighbor(of: b, direction: .down) == c)
        #expect(tree.neighbor(of: c, direction: .down) == nil)
    }

    @Test func upFromBottomPrefersAligned() {
        // c is centered; a and b are equidistant above — alignment tiebreak
        // must pick one deterministically (the closer-centered of the two).
        let up = tree.neighbor(of: c, direction: .up)
        #expect(up == a || up == b)
    }

    @Test func singlePaneHasNoNeighbors() {
        let single = LayoutNode.pane(a)
        #expect(single.neighbor(of: a, direction: .right) == nil)
    }
}
