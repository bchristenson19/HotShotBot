import Foundation

/// Small, pure numeric helpers shared by `PTZControlLoop`'s per-tick pipeline — kept framework-
/// free and separate from `PTZCommands` (which only encodes final CGI strings) so the easing/
/// clamping math driving intermediate pan/tilt/zoom targets stays independently unit-testable.
enum PTZMath {
    /// One step of exponential easing toward `target`: moves `current` a `rate` fraction of the
    /// remaining distance. `rate == 1` reproduces an instant snap-to-target (the old speed-
    /// modifier behavior); `rate == 0` freezes `current` in place; anything in between converges
    /// monotonically without overshoot, tick-rate-dependent in the same way `momentumAccel`
    /// already is elsewhere in `PTZControlLoop` (a fixed fraction per tick, not scaled by `dt`).
    static func eased(current: Double, target: Double, rate: Double) -> Double {
        current + (target - current) * rate
    }

    /// Clamps `value` to `-limit...limit` — `limit` is expected non-negative.
    static func clamped(_ value: Double, to limit: Double) -> Double {
        max(-limit, min(limit, value))
    }
}
