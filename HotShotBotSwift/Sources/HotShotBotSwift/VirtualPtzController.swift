import Foundation

/// Drives the in-app virtual camera's pose from the exact same Panasonic CGI command strings
/// `PTZCommands` emits for real cameras — the native port of `lib/virtualPtz.ts`.
///
/// A real AW-UE70 receives `#PTSxxyy`/`#Zxx` over HTTP and physically moves; the virtual camera
/// instead parses those strings here and integrates a `(yaw, pitch, fov)` pose over time.
/// `CameraClient.send` routes to `execCommand` instead of `URLSession` when a camera is virtual,
/// so gamepad-, tracker-, and AF-driven commands all reach this one integrator unchanged.
///
/// Scope note: the Swift `PTZCommands` only emits pan/tilt (`#PTSxxyy`), zoom (`#Zxx`), the stop
/// alias (`#PTS5050`), and AF (`OSE:69:x` on the `aw_cam` endpoint). The TS original also parsed
/// preset (`#R`/`#M`) and focus (`#F`) commands, but nothing in this app sends those yet, so they
/// are deliberately not ported (they'd be dead branches). AF/`aw_cam` commands are accepted and
/// ignored, matching the TS behaviour.
///
/// Not an `ObservableObject`: nothing in the UI binds to the pose directly — `VirtualCameraRenderer`
/// reads it each frame off the render queue. Marked `@unchecked Sendable` and guarded by a lock so
/// the render queue can `tick`/read while the main actor `execCommand`s from `CameraClient.send`.
final class VirtualPtzController: @unchecked Sendable {

    /// Camera pose. `yaw` positive = pan RIGHT, `pitch` positive = tilt UP, both radians;
    /// `fov` is the vertical field of view in degrees (matches Three.js `PerspectiveCamera.fov`).
    struct Pose {
        var yaw: Double = 0
        var pitch: Double = 0
        var fov: Double = 60
    }

    // MARK: Tuning constants — copied verbatim from lib/virtualPtz.ts.

    /// Angular pan/tilt speed at full stick, and FOV change per second at full stick.
    private static let panMaxRadPerSec = 1.4
    private static let tiltMaxRadPerSec = 1.0
    private static let fovMaxDegPerSec = 30.0

    /// Max speed byte offsets from the `50`-centered Panasonic scheme — the inverse of the
    /// `axisToSpeedByte`/`axisToZoomCmd` clamps in `PTZCommands`.
    private static let panByteMax = 30.0
    private static let tiltByteMax = 30.0
    private static let zoomByteMax = 49.0

    /// FOV clamp (tightest tele … widest) and pitch clamp (±~87.1°, just shy of straight up/down).
    static let fovMin = 10.0
    static let fovMax = 75.0
    static let pitchLimit = Double.pi / 2 - 0.05

    // MARK: State (lock-guarded — see class doc).

    private let lock = NSLock()
    private var _pose = Pose()
    /// Standing velocities: set by `execCommand`, held until the next command changes them, and
    /// integrated by `tick` — exactly like a real PTZ head that keeps moving until told to stop.
    private var yawVel = 0.0
    private var pitchVel = 0.0
    private var fovVel = 0.0

    /// A thread-safe snapshot of the current pose for the renderer to apply.
    var pose: Pose {
        lock.lock(); defer { lock.unlock() }
        return _pose
    }

    // MARK: Command parsing

    /// Converts a `50`-centered Panasonic speed byte back to a normalized `-1...1` velocity —
    /// the exact inverse of `PTZCommands.axisToSpeedByte`/`axisToZoomCmd`. `50` = stop.
    static func byteToNormalized(_ byte: Int, maxSpeed: Double) -> Double {
        if byte == 50 { return 0 }
        let offset = Double(byte - 50)
        return max(-1, min(1, offset / maxSpeed))
    }

    /// Parses one CGI command string and updates the standing velocities (or, for a stop, zeros
    /// them). Mirrors `VirtualPtzController.execCommand` in lib/virtualPtz.ts. Safe to call from
    /// the main actor while the render queue is ticking.
    func execCommand(_ cmd: String, endpoint: String = "aw_ptz") {
        // aw_cam carries AF/iris/gain (`OSE:...`) — accepted and ignored, same as the TS no-op.
        guard endpoint != "aw_cam" else { return }

        if let (pan, tilt) = Self.parsePanTilt(cmd) {
            let yv = Self.byteToNormalized(pan, maxSpeed: Self.panByteMax) * Self.panMaxRadPerSec
            let pv = Self.byteToNormalized(tilt, maxSpeed: Self.tiltByteMax) * Self.tiltMaxRadPerSec
            lock.lock(); yawVel = yv; pitchVel = pv; lock.unlock()
        } else if let zoom = Self.parseZoom(cmd) {
            // Positive zoom byte = tele = FOV shrinks, hence the negation.
            let fv = -Self.byteToNormalized(zoom, maxSpeed: Self.zoomByteMax) * Self.fovMaxDegPerSec
            lock.lock(); fovVel = fv; lock.unlock()
        }
        // Anything else (white balance, etc.) is ignored, as in the TS version.
    }

    /// `#PTSxxyy` → (panByte, tiltByte). Returns nil if the string isn't a pan/tilt command.
    static func parsePanTilt(_ cmd: String) -> (pan: Int, tilt: Int)? {
        guard cmd.hasPrefix("#PTS") else { return nil }
        let digits = cmd.dropFirst(4)
        guard digits.count == 4, digits.allSatisfy(\.isNumber) else { return nil }
        let pan = Int(digits.prefix(2))!
        let tilt = Int(digits.suffix(2))!
        return (pan, tilt)
    }

    /// `#Zxx` → zoomByte. Returns nil if the string isn't a zoom command.
    static func parseZoom(_ cmd: String) -> Int? {
        guard cmd.hasPrefix("#Z") else { return nil }
        let digits = cmd.dropFirst(2)
        guard digits.count == 2, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    // MARK: Integration

    /// Advances the pose by `dt` seconds using the held velocities. Euler integration with the
    /// same clamps/wrap as `tick` in lib/virtualPtz.ts: pitch clamped to ±`pitchLimit`, fov to
    /// `[fovMin, fovMax]`, yaw unclamped but wrapped to ±2π so it can't grow without bound.
    func tick(dt: Double) {
        lock.lock(); defer { lock.unlock() }
        _pose.yaw += yawVel * dt
        _pose.pitch += pitchVel * dt
        _pose.fov = max(Self.fovMin, min(Self.fovMax, _pose.fov + fovVel * dt))
        _pose.pitch = max(-Self.pitchLimit, min(Self.pitchLimit, _pose.pitch))
        if _pose.yaw > 2 * .pi { _pose.yaw -= 2 * .pi }
        if _pose.yaw < -2 * .pi { _pose.yaw += 2 * .pi }
    }
}
