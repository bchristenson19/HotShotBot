import Combine
import Foundation

/// Wires `GamepadInput`'s polled state into throttled PTZ commands sent through a
/// `CameraClient`, mirroring the `onFrame` callback in `app/page.tsx`: every gamepad poll tick,
/// read one stick for pan/tilt and the other stick's Y axis for zoom, apply sensitivity / tilt
/// invert / speed modifier / brake (pan-tilt) or sensitivity / invert / speed-modifier (zoom) in
/// the same order `app/page.tsx` does, run both through their momentum/glide models, encode via
/// `PTZCommands`, and dispatch on the "pt" / "zoom" channels so `CameraClient`'s throttle
/// collapses same-channel sends to ~66ms apart.
///
/// Reads a `ControlMapping` (see that file for exactly which fields are ported and why the
/// defaults are the user's own Electron-app values rather than `lib/mapping.ts`'s
/// `DEFAULT_MAPPING`). Full button remapping beyond what `ControlMapping.buttons` already
/// covers, plus focus/iris/gain/white-balance/presets/macros/multi-camera, are still out of
/// scope for this milestone.
@MainActor
final class PTZControlLoop: ObservableObject {
    private let gamepad: GamepadInput
    private let client: CameraClient
    @Published var mapping: ControlMapping

    private var cancellable: AnyCancellable?

    private let stickDeadzone = 0.05

    /// Current pan/tilt velocity — the value actually sent to the camera, which lags/glides
    /// behind the raw stick target rather than snapping to it. Persists across poll ticks so the
    /// camera keeps coasting after the stick returns to center, matching `velocity.current` in
    /// app/page.tsx.
    private var panVelocity: Double = 0
    private var tiltVelocity: Double = 0

    /// Current zoom velocity — same idea as pan/tilt's, but only actually glides when
    /// `mapping.zoomMomentumEnabled` is on; otherwise tracks the target instantly, matching
    /// `zoomVelocity.current` in app/page.tsx.
    private var zoomVelocity: Double = 0

    /// Wall-clock time of the previous poll tick, used to compute `dt` for the glide's
    /// exponential decay — mirrors `lastFrameTime` in app/page.tsx (there driven by
    /// `performance.now()` each `requestAnimationFrame`; here by each gamepad poll tick, which
    /// GamepadInput drives at the same ~60Hz cadence).
    private var lastFrameTime = Date()

    // Discrete (press-edge) button-action state — mirrors `autoFocus`/`oneTouchActive` state in
    // app/page.tsx. `autoFocus` defaults to true, matching the TS default.
    @Published private(set) var autoFocus = true
    @Published private(set) var oneTouchActive = false
    private var oneTouchTimer: DispatchWorkItem?

    /// Gamepad state as of the previous poll tick — used for press/release edge detection.
    /// Mirrors `prevButtons.current` in app/page.tsx, including where it's updated: only when
    /// `state.connected` is true (see the disconnected early-return below), so a disconnected
    /// controller's stale buttons don't register as "released" the moment it reconnects.
    private var previousState = GamepadState()

    private func pressed(_ button: ButtonId, in state: GamepadState) -> Bool {
        state.isPressed(button) && !previousState.isPressed(button)
    }

    private func released(_ button: ButtonId, in state: GamepadState) -> Bool {
        !state.isPressed(button) && previousState.isPressed(button)
    }

    init(gamepad: GamepadInput, client: CameraClient, mapping: ControlMapping) {
        self.gamepad = gamepad
        self.client = client
        self.mapping = mapping
        cancellable = gamepad.$state.sink { [weak self] state in
            self?.handle(state)
        }
    }

    private func handle(_ state: GamepadState) {
        let now = Date()
        // Cap dt at 100ms, matching app/page.tsx — guards against a huge decay jump after e.g.
        // the app being backgrounded, which would otherwise let velocity decay to zero in one step.
        let dt = min(now.timeIntervalSince(lastFrameTime) * 1000, 100)
        lastFrameTime = now

        guard state.connected else {
            // No TS equivalent (its onFrame just returns early on disconnect, leaving the last
            // sent speed as whatever the camera last received) — sending an explicit stop here
            // is a deliberate safety improvement so an unplugged controller can't leave the
            // camera panning indefinitely.
            if panVelocity != 0 || tiltVelocity != 0 || zoomVelocity != 0 {
                panVelocity = 0
                tiltVelocity = 0
                zoomVelocity = 0
                client.send(PTZCommands.stopCmd, channel: "pt")
            }
            return
        }

        let m = mapping

        // Discrete (press-edge) button actions — dispatched first each tick, matching
        // app/page.tsx's overall structure (all button handling happens before the continuous
        // stick/zoom computation below). Mirrors the `handleButtonPress`/`allButtons` loop.
        for (button, action) in m.buttons {
            guard pressed(button, in: state) else { continue }
            switch action {
            case .none, .finePanTilt:
                break // finePanTilt is level-based, handled inline below, not a press action
            case .toggleAutoFocus:
                autoFocus.toggle()
                let (cmd, endpoint) = PTZCommands.autoFocusCmd(autoFocus)
                client.send(cmd, endpoint: endpoint)
            case .oneTouchFocus:
                handleOneTouchFocusPress()
            case .toggleYield:
                client.toggleYield()
            case .cycleCamera:
                break // inert — this app is single-camera only; see ButtonActionId's doc comment
            }
        }

        // Hold-mode release: mirrors app/page.tsx's separate post-loop check, run once per tick
        // independent of which button triggered the press above — finds whichever button is
        // CURRENTLY bound to oneTouchFocus (not necessarily the one that started the hold) and
        // checks whether it was just released.
        if m.oneTouchFocusMode == .hold, let afButton = m.button(for: .oneTouchFocus), released(afButton, in: state) {
            client.send(PTZCommands.autoFocusCmd(false).cmd, endpoint: PTZCommands.autoFocusCmd(false).endpoint)
            autoFocus = false
            oneTouchActive = false
        }

        // Pan/tilt stick: left by default, right when swapped — matching DEFAULT_MAPPING
        // .panTiltAxis in lib/mapping.ts fed through app/page.tsx's SWAPPED_AXIS remap.
        var panTarget = (m.sticksSwapped ? state.rightX : state.leftX) * m.ptSensitivity
        var tiltTarget = (m.sticksSwapped ? state.rightY : state.leftY) * m.ptSensitivity

        // D-pad "fine pan/tilt" override — checked every tick against current held state (level-
        // based, not press-edge), each of the four directions independent since they needn't all
        // be bound together. Overrides (not adds to) the stick-derived target, matching
        // app/page.tsx's DPAD_SPEED = 0.4 block, which sits exactly here: after the initial
        // stick-target computation but before tilt-invert, so a d-pad-driven value still flows
        // through tilt-invert/speed-modifier/brake/momentum below exactly like a stick one would.
        if m.buttons[.dpadLeft] == .finePanTilt && state.dpadLeft { panTarget = -0.4 }
        if m.buttons[.dpadRight] == .finePanTilt && state.dpadRight { panTarget = 0.4 }
        if m.buttons[.dpadUp] == .finePanTilt && state.dpadUp { tiltTarget = -0.4 }
        if m.buttons[.dpadDown] == .finePanTilt && state.dpadDown { tiltTarget = 0.4 }

        // Tilt invert — applied uniformly, same point in the pipeline as app/page.tsx.
        if m.tiltInverted { tiltTarget = -tiltTarget }

        // Speed modifier — hold the assigned button to scale PT (and optionally zoom) down.
        // Ported as a trigger (`TriggerId`) rather than a `ButtonId` per explicit request (see
        // ControlMapping's doc comment) — held state is a simple >0.5 threshold on the trigger
        // axis rather than a boolean button, since GameController exposes triggers as 0...1.
        let modifierHeld = state.value(m.speedModifierButton) > 0.5
        if modifierHeld {
            panTarget *= m.speedModifierValue
            tiltTarget *= m.speedModifierValue
        }

        // Brake — continuously scales speed down proportional to how far the trigger is pressed
        // (not a hold-modifier threshold like speed modifier above), same formula as
        // app/page.tsx's R2-brake block. Computed once here and reused for zoom below too (an
        // explicit deviation from app/page.tsx, where the brake only ever touches pan/tilt — the
        // user asked for the Swift version's brake to affect zoom as well). No zoomMode
        // "triggers" check here since that zoom input mode isn't implemented in this milestone —
        // the brake trigger is always available.
        var brakeMultiplier = 1.0
        if let brakeTrigger = m.brakeTrigger {
            let brake = state.value(brakeTrigger)
            if brake > 0.01 {
                brakeMultiplier = 1 - brake * (1 - m.brakeMinSpeed)
                panTarget *= brakeMultiplier
                tiltTarget *= brakeMultiplier
            }
        }

        // Momentum: lerp velocity toward the stick target while pushed past the deadzone, decay
        // toward 0 (half-life = momentumGlideMs) once released — exact port of app/page.tsx's
        // momentum block, including its 0.01 snap-to-zero noise floor.
        if m.momentumEnabled {
            let panMoving = abs(panTarget) > stickDeadzone
            let tiltMoving = abs(tiltTarget) > stickDeadzone
            let decayPerMs = log(2) / m.momentumGlideMs
            let decayFactor = exp(-decayPerMs * dt)

            panVelocity = panMoving ? panVelocity + (panTarget - panVelocity) * m.momentumAccel : panVelocity * decayFactor
            tiltVelocity = tiltMoving ? tiltVelocity + (tiltTarget - tiltVelocity) * m.momentumAccel : tiltVelocity * decayFactor

            if abs(panVelocity) < 0.01 { panVelocity = 0 }
            if abs(tiltVelocity) < 0.01 { tiltVelocity = 0 }
        } else {
            panVelocity = panTarget
            tiltVelocity = tiltTarget
        }

        // Sent unconditionally every poll tick (like app/page.tsx's `sendContinuous` call) —
        // CameraClient's own per-channel throttle collapses this to ~66ms apart, and
        // axisToPanTiltCmd's own deadzone naturally produces the stop command once velocity
        // decays to ~0, so there's no need to gate the send on an "is moving" flag here (doing
        // so would cut the glide off the instant the raw stick recenters, since the whole point
        // of momentum is that the camera keeps moving briefly after release).
        client.sendContinuous(PTZCommands.axisToPanTiltCmd(pan: panVelocity, tilt: tiltVelocity), channel: "pt")

        // Zoom stick: right's Y axis by default, left's when swapped — matching
        // DEFAULT_MAPPING.zoomAxis ("rightY") in lib/mapping.ts fed through the same
        // SWAPPED_AXIS remap. `zoomInverted` is the ONLY sign flip here (matching app/page.tsx's
        // `rawZoom = axisValue(zoomAxis) * (zoomInverted ? -1 : 1)` exactly) — do not add a
        // second hardcoded negation on top, or a `zoomInverted` toggle silently becomes a no-op.
        // Speed modifier also scales zoom when `speedModifierAffectsZoom` is on, matching
        // app/page.tsx's `zoomModifier`, and the brake (see above) always scales zoom too. L2/R2
        // trigger-based zoom (the mapping's "triggers" zoomMode) is not wired up in this
        // milestone's minimal control loop.
        let rawZoom = (m.sticksSwapped ? state.leftY : state.rightY) * (m.zoomInverted ? -1 : 1)
        let zoomModifier = (modifierHeld && m.speedModifierAffectsZoom) ? m.speedModifierValue : 1
        let zoomTarget = max(-1, min(1, rawZoom * m.zoomSensitivity * zoomModifier * brakeMultiplier))

        // Zoom momentum — same half-life decay model as pan/tilt, gated by its own enable flag
        // and glide time (Electron: on, 400ms, matching the user's saved config).
        if m.zoomMomentumEnabled {
            let zoomMoving = abs(zoomTarget) > stickDeadzone
            let decayPerMs = log(2) / m.zoomMomentumGlideMs
            let decayFactor = exp(-decayPerMs * dt)
            zoomVelocity = zoomMoving ? zoomVelocity + (zoomTarget - zoomVelocity) * m.momentumAccel : zoomVelocity * decayFactor
            if abs(zoomVelocity) < 0.01 { zoomVelocity = 0 }
        } else {
            zoomVelocity = zoomTarget
        }

        client.sendContinuous(PTZCommands.axisToZoomCmd(zoomVelocity), channel: "zoom")

        // Must happen last, after this tick's edge detection above has used the PREVIOUS state —
        // matches app/page.tsx's `prevButtons.current = state` assignment at the end of onFrame.
        previousState = state
    }

    /// Handles a press of whichever button is bound to `oneTouchFocus`, in whichever mode is
    /// currently configured — mirrors app/page.tsx's `oneTouchFocus` case in `handleButtonPress`.
    /// TS also rumbles the controller here (`rumble(0.5, 0.3, 80)` etc.) — deliberately not
    /// ported: GameController's haptics API (CHHapticEngine-based) is materially more involved
    /// to wire up than the browser Gamepad API's dual-rumble, and out of scope for this pass.
    private func handleOneTouchFocusPress() {
        switch mapping.oneTouchFocusMode {
        case .pulse:
            guard oneTouchTimer == nil else { return } // already running — ignore re-press
            let onCmd = PTZCommands.autoFocusCmd(true)
            client.send(onCmd.cmd, endpoint: onCmd.endpoint)
            autoFocus = true
            oneTouchActive = true

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.oneTouchTimer = nil
                let offCmd = PTZCommands.autoFocusCmd(false)
                self.client.send(offCmd.cmd, endpoint: offCmd.endpoint)
                self.autoFocus = false
                self.oneTouchActive = false
            }
            oneTouchTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)

        case .hold:
            guard !autoFocus else { return } // already on — release handler turns it off
            let onCmd = PTZCommands.autoFocusCmd(true)
            client.send(onCmd.cmd, endpoint: onCmd.endpoint)
            autoFocus = true
            oneTouchActive = true
        }
    }
}
