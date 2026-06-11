import Testing
import Foundation
@testable import Buildwright

struct WheelScrollTests {
    @Test func smallDeltasAccumulateWithoutFiring() {
        let d = TmuxTerminalView.drainWheel(accumulator: 2)
        #expect(d.events == 0)
        #expect(d.remainder == 2)
    }

    @Test func bigSwipeFiresMultipleEvents() {
        let d = TmuxTerminalView.drainWheel(accumulator: 10)
        #expect(d.events == 3)
        #expect(d.up)
        #expect(abs(d.remainder - 1) < 0.0001)
    }

    @Test func downwardScrollFiresDownEvents() {
        let d = TmuxTerminalView.drainWheel(accumulator: -7)
        #expect(d.events == 2)
        #expect(!d.up)
        #expect(abs(d.remainder - (-1)) < 0.0001)
    }

    @Test func directionReversalCancelsLeftover() {
        // +2 leftover then a -4 swipe → net -2: no events yet, remainder carries.
        let d = TmuxTerminalView.drainWheel(accumulator: 2 - 4)
        #expect(d.events == 0)
        #expect(d.remainder == -2)
    }

    @Test func exactStepFiresExactlyOnce() {
        let d = TmuxTerminalView.drainWheel(accumulator: 3)
        #expect(d.events == 1)
        #expect(d.remainder == 0)
    }
}
