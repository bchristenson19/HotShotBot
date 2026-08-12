import Testing
@testable import HotShotBotSwift

/// Verifies the small pure helpers `PTZControlLoop` leans on for the speed-modifier easing
/// (Feature 4) and the gyro fine-adjust clamp (Feature 2).
struct PTZMathTests {

    // MARK: - eased

    @Test func easedAtRateOneSnapsInstantly() {
        // rate == 1.0 reproduces the old instant-step behavior exactly.
        #expect(PTZMath.eased(current: 0, target: 1, rate: 1.0) == 1.0)
        #expect(PTZMath.eased(current: 0.55, target: 1.0, rate: 1.0) == 1.0)
    }

    @Test func easedAtRateZeroFreezesCurrentValue() {
        #expect(PTZMath.eased(current: 0.3, target: 1.0, rate: 0) == 0.3)
    }

    @Test func easedAtMidRateMovesPartway() {
        // current + (target - current) * rate = 0 + (1 - 0) * 0.2 = 0.2.
        #expect(PTZMath.eased(current: 0, target: 1.0, rate: 0.2) == 0.2)
    }

    @Test func easedConvergesToTargetOverRepeatedSteps() {
        // Exponential convergence: after n steps at rate r, the remaining gap is (1-r)^n of the
        // original. 50 steps at rate 0.2 leaves (0.8)^50 ≈ 1.4e-5 — comfortably under 0.0001.
        var current = 0.0
        for _ in 0..<50 {
            current = PTZMath.eased(current: current, target: 1.0, rate: 0.2)
        }
        #expect(abs(current - 1.0) < 0.0001)
    }

    @Test func easedApproachesFromAboveWhenTargetIsLower() {
        var current = 1.0
        for _ in 0..<50 {
            current = PTZMath.eased(current: current, target: 0.55, rate: 0.2)
        }
        #expect(abs(current - 0.55) < 0.0001)
    }

    // MARK: - clamped

    @Test func clampedWithinRangeIsUnchanged() {
        #expect(PTZMath.clamped(0.2, to: 0.35) == 0.2)
        #expect(PTZMath.clamped(-0.2, to: 0.35) == -0.2)
    }

    @Test func clampedAboveRangeIsCeilinged() {
        #expect(PTZMath.clamped(5.0, to: 0.35) == 0.35)
    }

    @Test func clampedBelowNegativeRangeIsFloored() {
        #expect(PTZMath.clamped(-5.0, to: 0.35) == -0.35)
    }

    @Test func clampedAtBoundaryIsUnchanged() {
        #expect(PTZMath.clamped(0.35, to: 0.35) == 0.35)
        #expect(PTZMath.clamped(-0.35, to: 0.35) == -0.35)
    }
}
