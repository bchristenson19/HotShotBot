import Testing
import Foundation
@testable import HotShotBotSwift

/// Verifies `VirtualPtzController` — the virtual camera's pose integrator — against the exact
/// behaviour of `lib/virtualPtz.ts` in the Electron version, and against its symmetry with
/// `PTZCommands` (the controller decodes the same `50`-centered speed bytes those encoders
/// produce). Uses Swift Testing to match the rest of the suite (no full Xcode → no XCTest).
struct VirtualPtzControllerTests {

    private let epsilon = 1e-9

    // MARK: - byteToNormalized (inverse of PTZCommands.axisToSpeedByte / axisToZoomCmd)

    @Test func byteToNormalizedCenterIsZero() {
        #expect(VirtualPtzController.byteToNormalized(50, maxSpeed: 30) == 0)
    }

    @Test func byteToNormalizedFullPositive() {
        // Pan byte 80 = offset +30 = full right.
        #expect(abs(VirtualPtzController.byteToNormalized(80, maxSpeed: 30) - 1.0) < epsilon)
    }

    @Test func byteToNormalizedHalfNegative() {
        // Byte 35 = offset -15 = -0.5 at maxSpeed 30.
        #expect(abs(VirtualPtzController.byteToNormalized(35, maxSpeed: 30) - (-0.5)) < epsilon)
    }

    @Test func byteToNormalizedClampsBeyondMax() {
        // An out-of-range byte still clamps to ±1.
        #expect(VirtualPtzController.byteToNormalized(99, maxSpeed: 30) == 1.0)
        #expect(VirtualPtzController.byteToNormalized(1, maxSpeed: 30) == -1.0)
    }

    /// Round-trips a full-speed pan command through PTZCommands' encoder and back — a mismatch
    /// means the virtual decoder diverged from the real command encoding.
    @Test func roundTripsFullSpeedPanFromEncoder() {
        // Full positive pan axis (invert:true) → byte "80" per PTZCommands.
        let byteStr = PTZCommands.axisToSpeedByte(1.0, invert: true)
        #expect(byteStr == "80")
        #expect(abs(VirtualPtzController.byteToNormalized(Int(byteStr)!, maxSpeed: 30) - 1.0) < epsilon)
    }

    // MARK: - Command parsing

    @Test func parsesPanTilt() {
        let parsed = VirtualPtzController.parsePanTilt("#PTS8020")
        #expect(parsed?.pan == 80)
        #expect(parsed?.tilt == 20)
    }

    @Test func parsesZoom() {
        #expect(VirtualPtzController.parseZoom("#Z99") == 99)
    }

    @Test func rejectsNonMatchingCommands() {
        #expect(VirtualPtzController.parsePanTilt("#Z50") == nil)
        #expect(VirtualPtzController.parseZoom("#PTS5050") == nil)
        #expect(VirtualPtzController.parsePanTilt("#PTSxxyy") == nil)
    }

    // MARK: - Integration

    @Test func fullRightPanIntegratesYawAtMaxRate() {
        let c = VirtualPtzController()
        c.execCommand("#PTS8050") // full right pan, tilt stopped
        c.tick(dt: 1.0)
        // yawVel = 1.0 * PAN_MAX_RAD_PER_SEC (1.4); after 1s yaw ≈ 1.4 rad, pitch unchanged.
        #expect(abs(c.pose.yaw - 1.4) < 1e-6)
        #expect(abs(c.pose.pitch) < epsilon)
    }

    @Test func teleZoomShrinksFov() {
        let c = VirtualPtzController()
        let startFov = c.pose.fov
        c.execCommand("#Z99") // full tele → fov decreases
        c.tick(dt: 0.5)
        #expect(c.pose.fov < startFov)
    }

    @Test func stopCommandZeroesVelocities() {
        let c = VirtualPtzController()
        c.execCommand("#PTS8020")
        c.tick(dt: 0.1)
        let yawAfterMove = c.pose.yaw
        c.execCommand("#PTS5050") // stop
        c.tick(dt: 1.0)
        // Pose holds steady after stop — no further drift.
        #expect(abs(c.pose.yaw - yawAfterMove) < epsilon)
    }

    @Test func awCamCommandsAreNoOps() {
        let c = VirtualPtzController()
        let before = c.pose
        c.execCommand("OSE:69:1", endpoint: "aw_cam")
        c.tick(dt: 1.0)
        #expect(c.pose.yaw == before.yaw)
        #expect(c.pose.pitch == before.pitch)
        #expect(c.pose.fov == before.fov)
    }

    @Test func pitchClampsToLimit() {
        let c = VirtualPtzController()
        c.execCommand("#PTS5080") // full tilt in one direction
        c.tick(dt: 100) // way past the limit
        #expect(c.pose.pitch <= VirtualPtzController.pitchLimit + epsilon)
        #expect(c.pose.pitch >= -VirtualPtzController.pitchLimit - epsilon)
    }

    @Test func fovClampsToRange() {
        let c = VirtualPtzController()
        c.execCommand("#Z99") // tele, shrinking fov
        c.tick(dt: 100)
        #expect(c.pose.fov >= VirtualPtzController.fovMin - epsilon)
        c.execCommand("#Z01") // wide, growing fov
        c.tick(dt: 100)
        #expect(c.pose.fov <= VirtualPtzController.fovMax + epsilon)
    }

    @Test func yawWrapsWithinTwoPi() {
        // The wrap subtracts 2π at most once per tick (it assumes small per-frame increments, as
        // in the rAF-driven TS original), so drive it with realistic small steps: 200×0.1s at
        // 1.4 rad/s ≈ 28 rad total, well past 2π and multiple full turns.
        let c = VirtualPtzController()
        c.execCommand("#PTS8050") // pan right continuously
        for _ in 0..<200 { c.tick(dt: 0.1) }
        #expect(c.pose.yaw <= 2 * .pi + epsilon)
        #expect(c.pose.yaw >= -2 * .pi - epsilon)
    }
}
