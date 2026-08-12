import Testing
@testable import HotShotBotSwift

/// Verifies `trackAxis` and `TrackingEngine` against hand-derived expected values, the same way
/// `PTZCommandsTests.swift` verifies `PTZCommands` — both are direct ports of
/// `public/tracking.worker.js`'s math (`trackAxis`, the EMA smoothing, the lock/lost state
/// machine, the shot-preset target tables), so a mismatch here means the port diverged from the
/// original algorithm. Pure logic only — no Vision, no camera, no UI.
struct TrackingEngineTests {

    // MARK: - trackAxis: deadzone / ramp / full-speed boundaries

    @Test func trackAxisWithinDeadzoneIsZero() {
        #expect(trackAxis(0.02, speed: 1.0, deadZone: 0.04) == 0)
        #expect(trackAxis(-0.02, speed: 1.0, deadZone: 0.04) == 0)
    }

    @Test func trackAxisAtDeadzoneBoundaryIsZero() {
        // magnitude == deadZone takes the ramp branch (not the early-zero one), but the ramp
        // formula evaluates to exactly 0 right at this boundary — a real but easy-to-miss edge
        // case, worth pinning down explicitly.
        #expect(trackAxis(0.04, speed: 1.0, deadZone: 0.04) == 0)
    }

    @Test func trackAxisJustAboveDeadzoneRampsUp() {
        // magnitude 0.05, deadZone 0.04, fastZone = 0.04*6 = 0.24 -> ramp = (0.05-0.04)/(0.24-0.04)
        // = 0.05 -> 0.05 * speed.
        let result = trackAxis(0.05, speed: 1.0, deadZone: 0.04)
        #expect(abs(result - 0.05) < 0.0001)
    }

    @Test func trackAxisAtFastZoneBoundaryReachesFullSpeed() {
        // magnitude == fastZone (0.24) still takes the ramp branch (<=), but the ramp formula
        // evaluates to exactly 1.0 at this boundary, matching full speed continuously.
        let result = trackAxis(0.24, speed: 0.6, deadZone: 0.04)
        #expect(abs(result - 0.6) < 0.0001)
    }

    @Test func trackAxisBeyondFastZoneIsFullSpeed() {
        #expect(trackAxis(0.5, speed: 0.6, deadZone: 0.04) == 0.6)
    }

    @Test func trackAxisNegativeOffsetFlipsSign() {
        #expect(trackAxis(-0.5, speed: 0.6, deadZone: 0.04) == -0.6)
    }

    // MARK: - Lock: seeds smoothed state with no initial lurch

    @Test func lockSeedsSmoothedValuesExactly() {
        // Box centered at x=0.70 (not 0.5, so a stale default wouldn't accidentally match), with
        // headY landing exactly on the "full" preset's target (0.15) and height exactly on the
        // "full" preset's target height (0.80) — so if lock() seeds correctly, stepping with this
        // SAME box immediately afterward should report tilt/zoom of exactly 0 (already on
        // target) and pan reflecting the box's true x-offset from center, undamped by any
        // leftover default (0.5/0.5/0) the engine hadn't actually seen yet.
        let box = TrackedBox(x: 0.65, y: 0.13, w: 0.1, h: 0.80)
        var engine = TrackingEngine()
        engine.lock(box)

        let output = engine.step(detections: [box], speed: 1.0, shotPreset: .full, deadZone: 0.04)

        #expect(output.state == .tracking)
        // pan: offset = 0.70 - 0.5 = 0.20 -> ramp = (0.20-0.04)/(0.24-0.04) = 0.8 -> 0.8 * speed.
        #expect(abs(output.pan - 0.8) < 0.0001)
        // tilt: headY (0.13 + 0.80*0.04 = 0.162) vs target 0.15 -> offset 0.012, within the 0.04
        // deadzone -> 0.
        #expect(output.tilt == 0)
        // zoom: height already exactly at the "full" target (0.80) -> error 0, within the 0.06
        // zoom deadzone -> 0.
        #expect(output.zoom == 0)
    }

    // MARK: - EMA smoothing: partial movement then convergence

    @Test func smoothingMovesPartwayOnFirstStepAfterATargetJump() {
        // Lock a centered box (pan offset 0), then feed a DIFFERENT box (center 0.70) on the very
        // next step. If smoothing is applied, smoothX should land partway between 0.5 and 0.70 —
        // NOT jump straight to 0.70 — so the resulting pan should be well below the "fully
        // converged" value (0.8, per the boundary test above) but still nonzero.
        var engine = TrackingEngine()
        engine.lock(TrackedBox(x: 0.45, y: 0.4, w: 0.1, h: 0.2))

        let movedBox = TrackedBox(x: 0.65, y: 0.4, w: 0.1, h: 0.2)
        let output = engine.step(detections: [movedBox], speed: 1.0, shotPreset: .none, deadZone: 0.04)

        #expect(output.state == .tracking)
        #expect(output.pan > 0)
        #expect(output.pan < 0.8)
    }

    @Test func smoothingConvergesToTargetOverRepeatedSteps() {
        var engine = TrackingEngine()
        engine.lock(TrackedBox(x: 0.45, y: 0.4, w: 0.1, h: 0.2))

        let movedBox = TrackedBox(x: 0.65, y: 0.4, w: 0.1, h: 0.2)
        var lastOutput = TrackingEngine.Output(state: .idle, detections: [], lockedBox: nil, pan: 0, tilt: 0, zoom: 0)
        for _ in 0..<20 {
            lastOutput = engine.step(detections: [movedBox], speed: 1.0, shotPreset: .none, deadZone: 0.04)
        }

        // Fully converged: offset 0.70-0.5=0.20 -> ramp (0.20-0.04)/(0.24-0.04) = 0.8.
        #expect(abs(lastOutput.pan - 0.8) < 0.01)
    }

    // MARK: - Lost: beyond the match-distance threshold

    @Test func detectionBeyondLostDistanceReportsLost() {
        let locked = TrackedBox(x: 0.05, y: 0.05, w: 0.1, h: 0.1) // center (0.10, 0.10)
        let farAway = TrackedBox(x: 0.80, y: 0.80, w: 0.1, h: 0.1) // center (0.85, 0.85)
        var engine = TrackingEngine()
        engine.lock(locked)

        let output = engine.step(detections: [farAway], speed: 1.0, shotPreset: .none, deadZone: 0.04)

        #expect(output.state == .lost)
        // lockedBox is deliberately left untouched (not nil, not the far-away box) so a later
        // frame can re-acquire the same target without a fresh tap-to-lock.
        #expect(output.lockedBox == locked)
        #expect(output.pan == 0 && output.tilt == 0 && output.zoom == 0)
    }

    @Test func detectionWellWithinLostDistanceStillMatches() {
        // Deliberately not placed exactly at the 0.6 boundary — floating-point arithmetic on the
        // computed center distance can land a hair above or below an exact literal boundary, so
        // this uses a distance (0.5) that's unambiguously on the "still matches" side.
        let locked = TrackedBox(x: 0.05, y: 0.05, w: 0.1, h: 0.1) // center (0.10, 0.10)
        let nearby = TrackedBox(x: 0.55, y: 0.05, w: 0.1, h: 0.1) // center (0.60, 0.10) -> distance 0.50
        var engine = TrackingEngine()
        engine.lock(locked)

        let output = engine.step(detections: [nearby], speed: 1.0, shotPreset: .none, deadZone: 0.04)

        #expect(output.state == .tracking)
        #expect(output.lockedBox == nearby)
    }

    // MARK: - No lock yet: idle / detecting, never touches smoothing

    @Test func noDetectionsWithoutLockIsIdle() {
        var engine = TrackingEngine()
        let output = engine.step(detections: [], speed: 1.0, shotPreset: .none, deadZone: 0.04)
        #expect(output.state == .idle)
        #expect(output.lockedBox == nil)
    }

    @Test func detectionsWithoutLockIsDetecting() {
        var engine = TrackingEngine()
        let box = TrackedBox(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        let output = engine.step(detections: [box], speed: 1.0, shotPreset: .none, deadZone: 0.04)
        #expect(output.state == .detecting)
        #expect(output.lockedBox == nil)
        #expect(output.detections == [box])
    }

    // MARK: - unlock

    @Test func unlockClearsLockedBox() {
        var engine = TrackingEngine()
        engine.lock(TrackedBox(x: 0.5, y: 0.5, w: 0.1, h: 0.1))
        #expect(engine.lockedBox != nil)
        engine.unlock()
        #expect(engine.lockedBox == nil)
    }
}
