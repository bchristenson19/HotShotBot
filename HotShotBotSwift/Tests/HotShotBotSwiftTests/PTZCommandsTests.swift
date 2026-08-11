import Testing
@testable import HotShotBotSwift

/// Verifies `PTZCommands` against known input/output pairs derived directly from the logic in
/// `lib/ptz.ts` (`axisToPanTiltCmd`, `axisToSpeedByte`, `axisToZoomCmd`) in the Electron/Next.js
/// version of HotShotBot. These pairs were hand-computed from that file's exact arithmetic
/// (round-half-away-from-zero, clamp to 1...30 for pan/tilt or 1...49 for zoom, deadzone 0.05)
/// rather than guessed, so a mismatch here means the port diverged from the original encoding.
///
/// Uses Swift Testing (`import Testing`) rather than XCTest: this environment only has the
/// Command Line Tools installed (no full Xcode), and Apple's XCTest.framework for macOS is
/// only shipped with Xcode proper — `swift test` fails with "no such module 'XCTest'" here.
/// Swift Testing ships with the open-source toolchain instead, so it's what actually runs.
struct PTZCommandsTests {

    // MARK: - Pan/Tilt: center / deadzone

    @Test func panTiltCenterIsStop() {
        #expect(PTZCommands.axisToPanTiltCmd(pan: 0, tilt: 0) == "#PTS5050")
    }

    @Test func panTiltWithinDeadzoneIsStop() {
        // 0.03 is below the 0.05 deadzone threshold on both axes.
        #expect(PTZCommands.axisToPanTiltCmd(pan: 0.03, tilt: -0.03) == "#PTS5050")
    }

    @Test func panTiltJustOutsideDeadzoneIsNotStop() {
        // 0.05 is NOT below the deadzone threshold (strict <), so it should produce a nonzero
        // speed byte, not "50".
        let cmd = PTZCommands.axisToPanTiltCmd(pan: 0.05, tilt: 0)
        #expect(cmd != "#PTS5050")
    }

    // MARK: - Pan: full speed and direction

    @Test func panFullRight() {
        // panAxis = 1.0 -> axisToSpeedByte(1.0, invert: true): v = 1.0, speed = round(30) = 30,
        // byte = 50 + 30 = 80.
        #expect(PTZCommands.axisToPanTiltCmd(pan: 1.0, tilt: 0) == "#PTS8050")
    }

    @Test func panFullLeft() {
        // panAxis = -1.0 -> v = -1.0, speed = 30, byte = 50 - 30 = 20.
        #expect(PTZCommands.axisToPanTiltCmd(pan: -1.0, tilt: 0) == "#PTS2050")
    }

    // MARK: - Tilt: full speed and direction (note the sign flip vs. pan)

    @Test func tiltFullUp() {
        // tiltAxis = 1.0 -> axisToSpeedByte(1.0, invert: false): v = -axis = -1.0,
        // speed = 30, byte = 50 - 30 = 20. (Stick up produces the "down" byte range because
        // tilt's `invert` flag is false, mirroring lib/ptz.ts exactly.)
        #expect(PTZCommands.axisToPanTiltCmd(pan: 0, tilt: 1.0) == "#PTS5020")
    }

    @Test func tiltFullDown() {
        // tiltAxis = -1.0 -> v = -(-1.0) = 1.0, speed = 30, byte = 50 + 30 = 80.
        #expect(PTZCommands.axisToPanTiltCmd(pan: 0, tilt: -1.0) == "#PTS5080")
    }

    // MARK: - Speed byte: rounding and clamping

    @Test func speedByteAtDeadzoneBoundary() {
        // axis = 0.05, invert: true -> v = 0.05, speed = round(0.05 * 30) = round(1.5) = 2
        // (round-half-away-from-zero), byte = 50 + 2 = 52.
        #expect(PTZCommands.axisToSpeedByte(0.05, invert: true) == "52")
    }

    @Test func speedByteNegativeAtDeadzoneBoundary() {
        // axis = -0.05, invert: true -> v = -0.05, speed = 2, byte = 50 - 2 = 48.
        #expect(PTZCommands.axisToSpeedByte(-0.05, invert: true) == "48")
    }

    @Test func speedByteMidRange() {
        // axis = 0.5, invert: true -> v = 0.5, speed = round(15) = 15, byte = 50 + 15 = 65.
        #expect(PTZCommands.axisToSpeedByte(0.5, invert: true) == "65")
    }

    @Test func speedByteClampsBeyondUnitRange() {
        // axis = 2.0 (out of the normal -1...1 range) -> v = 2.0, speed = round(60) = 60,
        // clamped to 30, byte = 50 + 30 = 80. Speed must never exceed the 30-step hardware max.
        #expect(PTZCommands.axisToSpeedByte(2.0, invert: true) == "80")
    }

    // MARK: - Zoom: center / deadzone

    @Test func zoomCenterIsStop() {
        #expect(PTZCommands.axisToZoomCmd(0) == "#Z50")
    }

    @Test func zoomWithinDeadzoneIsStop() {
        #expect(PTZCommands.axisToZoomCmd(0.03) == "#Z50")
    }

    // MARK: - Zoom: full speed and direction

    @Test func zoomFullTele() {
        // axis = 1.0 -> speed = round(49) = 49, byte = 50 + 49 = 99.
        #expect(PTZCommands.axisToZoomCmd(1.0) == "#Z99")
    }

    @Test func zoomFullWide() {
        // axis = -1.0 -> speed = 49, byte = 50 - 49 = 1.
        #expect(PTZCommands.axisToZoomCmd(-1.0) == "#Z01")
    }

    @Test func zoomMidRange() {
        // axis = 0.5 -> speed = round(24.5) = 25 (round-half-away-from-zero), byte = 50 + 25 = 75.
        #expect(PTZCommands.axisToZoomCmd(0.5) == "#Z75")
    }

    @Test func zoomNegativeJustOutsideDeadzone() {
        // axis = -0.05 -> speed = round(0.05 * 49) = round(2.45) = 2, byte = 50 - 2 = 48.
        #expect(PTZCommands.axisToZoomCmd(-0.05) == "#Z48")
    }

    // MARK: - Stop command constant

    @Test func stopCmdMatchesPanTiltCenter() {
        #expect(PTZCommands.stopCmd == "#PTS5050")
    }

    // MARK: - Auto focus command

    @Test func autoFocusCmdOn() {
        let result = PTZCommands.autoFocusCmd(true)
        #expect(result.cmd == "OSE:69:1")
        #expect(result.endpoint == "aw_cam")
    }

    @Test func autoFocusCmdOff() {
        let result = PTZCommands.autoFocusCmd(false)
        #expect(result.cmd == "OSE:69:0")
        #expect(result.endpoint == "aw_cam")
    }
}
