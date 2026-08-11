import Foundation

/// Panasonic AW-UE70/UE160/HE130 HTTP CGI command encoding.
///
/// Faithful Swift port of `lib/ptz.ts` from the Electron/Next.js version of HotShotBot.
/// Only the pan/tilt/zoom encoders needed for the first native milestone are ported here —
/// focus/iris/gain/preset/white-balance encoders exist in the TS original but are out of
/// scope until a later milestone.
enum PTZCommands {

    /// Converts joystick axis values (-1...1) to a combined pan/tilt CGI command: `#PTSxxyy`
    /// where xx = pan speed+direction byte and yy = tilt speed+direction byte.
    /// Mirrors `axisToPanTiltCmd(panAxis, tiltAxis)` in lib/ptz.ts exactly.
    static func axisToPanTiltCmd(pan panAxis: Double, tilt tiltAxis: Double) -> String {
        let panVal = axisToSpeedByte(panAxis, invert: true)
        let tiltVal = axisToSpeedByte(tiltAxis, invert: false)
        return "#PTS\(panVal)\(tiltVal)"
    }

    /// Byte encoding shared by pan and tilt axes:
    /// - |v| < 0.05 deadzone -> "50" (stop)
    /// - otherwise speed = round(|v| * 30) clamped to 1...30
    /// - byte = 50 + speed if v > 0, else 50 - speed, zero-padded to 2 digits
    /// Mirrors `axisToSpeedByte(axis, invert)` in lib/ptz.ts exactly, including the sign flip
    /// convention: pan passes `invert: true` (v = axis), tilt passes `invert: false` (v = -axis).
    static func axisToSpeedByte(_ axis: Double, invert: Bool) -> String {
        let v = invert ? axis : -axis
        if abs(v) < 0.05 { return "50" }
        let speed = (abs(v) * 30).rounded()
        let clamped = max(1, min(30, speed))
        let byte = v > 0 ? 50 + Int(clamped) : 50 - Int(clamped)
        return String(format: "%02d", byte)
    }

    /// Converts a single joystick/trigger axis (-1...1) to a zoom CGI command: `#Zxx`
    /// where 01-49 = wide, 50 = stop, 51-99 = tele.
    /// Mirrors `axisToZoomCmd(axis)` in lib/ptz.ts exactly.
    static func axisToZoomCmd(_ axis: Double) -> String {
        if abs(axis) < 0.05 { return "#Z50" }
        let speed = (abs(axis) * 49).rounded()
        let clamped = max(1, min(49, speed))
        let byte = axis > 0 ? 50 + Int(clamped) : 50 - Int(clamped)
        return "#Z" + String(format: "%02d", byte)
    }

    /// Pan/tilt stop command — sent on release / disconnect, same as `STOP_CMD` in lib/ptz.ts.
    static let stopCmd = "#PTS5050"

    /// Auto-focus on/off — `aw_cam` endpoint. Mirrors `autoFocusCmd(on)` in lib/ptz.ts exactly;
    /// also the same underlying command as lib/ptz.ts's `ONE_TOUCH_FOCUS_CMD`/`ONE_TOUCH_FOCUS_OFF`
    /// constants (TS just names the same two values twice for two different call sites).
    static func autoFocusCmd(_ on: Bool) -> (cmd: String, endpoint: String) {
        (cmd: on ? "OSE:69:1" : "OSE:69:0", endpoint: "aw_cam")
    }
}
