import Foundation
import GameController

/// Normalized snapshot of a DualSense controller's relevant inputs for PTZ control.
///
/// Mirrors the shape of `GamepadState` in `hooks/useGamepad.ts` from the Electron/Next.js
/// version of HotShotBot, so the button/axis semantics stay consistent across the rewrite.
/// Axes are normalized -1...1; triggers are 0...1 (same ranges as the browser Gamepad API
/// the TS version reads via `navigator.getGamepads()`).
struct GamepadState: Equatable {
    var leftX: Double = 0
    var leftY: Double = 0
    var rightX: Double = 0
    var rightY: Double = 0

    var cross = false
    var circle = false
    var square = false
    var triangle = false

    var l1 = false
    var r1 = false
    var l2: Double = 0
    var r2: Double = 0
    var l3 = false
    var r3 = false

    var dpadUp = false
    var dpadDown = false
    var dpadLeft = false
    var dpadRight = false

    var options = false
    var touchpad = false

    /// DualSense gyro rotation rate (rad/s per axis), for the gyro fine-adjust feature — read
    /// from `GCController.motion`, a separate nullable property from `extendedGamepad` (see
    /// `GamepadInput.pollOnce()`). Zero when no controller motion is available (older controller,
    /// or `.motion` is nil) rather than optional, so callers don't need to unwrap — a controller
    /// that can't report gyro data is indistinguishable from one that's perfectly still.
    var rotationRateX: Double = 0
    var rotationRateY: Double = 0
    var rotationRateZ: Double = 0

    var connected = false
}

/// Best-guess mapping from the DualSense's gyro rotation rate to the gyro fine-adjust feature's
/// pan/tilt targets — UNVERIFIED on real hardware (see the project README's Known Unknowns).
/// `GCRotationRate`'s header only documents a right-hand-rule sign per abstract axis, not which
/// physical twist on a DualSense's housing corresponds to which axis, so this mapping is
/// isolated here for a quick one-line fix once it's actually been tested against a controller.
enum GyroAxisMapping {
    static func pan(_ state: GamepadState) -> Double { state.rotationRateY }
    static func tilt(_ state: GamepadState) -> Double { state.rotationRateX }
    static let panSign: Double = 1
    static let tiltSign: Double = 1
}

/// Polls a connected `GCController`'s extended gamepad profile every frame and publishes a
/// `GamepadState`, mirroring the polling model of `useGamepad.ts` (which drives its loop off
/// `requestAnimationFrame` rather than the button-changed-handler callbacks GameController also
/// offers) — polling keeps the PTZ command loop's timing independent of controller event timing.
@MainActor
final class GamepadInput: ObservableObject {
    @Published private(set) var state = GamepadState()

    /// True once we've seen a `GCControllerDidConnect` notification but the controller hasn't
    /// exposed an `extendedGamepad` profile yet (mirrors the TS `waitingForPress` state — on
    /// Bluetooth, some platforms only fully expose input after the first button press).
    @Published private(set) var waitingForPress = false

    private var displayLink: Timer?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    /// DualSense USB/Bluetooth vendor+product IDs — used only for informational/logging
    /// purposes here; GameController.framework abstracts the actual HID access.
    static let dualSenseVendorID = 0x054c
    static let dualSenseProductID = 0x0ce6

    init() {
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConnectionState() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConnectionState() }
        }
        refreshConnectionState()
        startPolling()
    }

    deinit {
        displayLink?.invalidate()
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }

    private func startPolling() {
        // ~60Hz, matching the rAF-driven poll rate of the TS version's useGamepad hook.
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
    }

    private func findGamepad() -> GCController? {
        GCController.controllers().first { $0.extendedGamepad != nil }
    }

    private func refreshConnectionState() {
        waitingForPress = findGamepad() == nil && !GCController.controllers().isEmpty
    }

    private func pollOnce() {
        guard let controller = findGamepad(), let pad = controller.extendedGamepad else {
            state = GamepadState(connected: false)
            return
        }
        waitingForPress = false

        // Gyro rotation rate, for the gyro fine-adjust feature. `GCMotion` is a separate,
        // nullable sibling property to `extendedGamepad` — not nested under it. Per
        // GameController.framework's headers, `sensorsActive` must be explicitly set `true` to
        // start receiving data when `sensorsRequireManualActivation` is true, so that's done here
        // once motion becomes available rather than assuming it streams by default. Whether a
        // physical DualSense actually reports non-nil `.motion` with live values is unverified —
        // this degrades safely to all-zero below if `.motion` is nil.
        var rrX = 0.0, rrY = 0.0, rrZ = 0.0
        if let motion = controller.motion {
            if !motion.sensorsActive { motion.sensorsActive = true }
            let r = motion.rotationRate
            rrX = r.x; rrY = r.y; rrZ = r.z
        }

        state = GamepadState(
            leftX: Double(pad.leftThumbstick.xAxis.value),
            // Negated: GameController reports +1 for "stick pushed up" on the Y axes, while the
            // browser Gamepad API the TS version reads (and every downstream invert flag in
            // PTZCommands/PTZControlLoop was written against) reports -1 for the same push.
            // Without this, tilt and zoom would both be inverted from the TS version's behavior.
            leftY: -Double(pad.leftThumbstick.yAxis.value),
            rightX: Double(pad.rightThumbstick.xAxis.value),
            rightY: -Double(pad.rightThumbstick.yAxis.value),
            cross: pad.buttonA.isPressed,
            circle: pad.buttonB.isPressed,
            square: pad.buttonX.isPressed,
            triangle: pad.buttonY.isPressed,
            l1: pad.leftShoulder.isPressed,
            r1: pad.rightShoulder.isPressed,
            l2: Double(pad.leftTrigger.value),
            r2: Double(pad.rightTrigger.value),
            l3: pad.leftThumbstickButton?.isPressed ?? false,
            r3: pad.rightThumbstickButton?.isPressed ?? false,
            dpadUp: pad.dpad.up.isPressed,
            dpadDown: pad.dpad.down.isPressed,
            dpadLeft: pad.dpad.left.isPressed,
            dpadRight: pad.dpad.right.isPressed,
            // GameController's naming is Xbox-derived, not PlayStation-derived: `buttonMenu` (the
            // "pause/start" role, top-right on an Xbox pad) is what a DualSense's physical
            // "Options" button (also top-right) reports through, while `buttonOptions` (the
            // "view/back" role) corresponds to the DualSense's separate "Create" button on the
            // left. Reading `buttonOptions` here for the Options button was the likely cause of
            // "cycle camera does nothing" — that binding's press edge never fired because this
            // was watching the wrong physical button.
            options: pad.buttonMenu.isPressed,
            touchpad: (controller.extendedGamepad as? GCDualSenseGamepad)?.touchpadButton.isPressed ?? false,
            rotationRateX: rrX,
            rotationRateY: rrY,
            rotationRateZ: rrZ,
            connected: true
        )
    }
}
