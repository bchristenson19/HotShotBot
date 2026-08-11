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

    var connected = false
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
            options: pad.buttonOptions?.isPressed ?? false,
            touchpad: (controller.extendedGamepad as? GCDualSenseGamepad)?.touchpadButton.isPressed ?? false,
            connected: true
        )
    }
}
