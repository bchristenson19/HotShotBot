import Combine
import Foundation

/// Wires `GamepadInput`'s polled state into throttled PTZ commands sent through whichever
/// camera is currently active in `CameraSessionStore`, mirroring the `onFrame` callback in
/// `app/page.tsx`: every gamepad poll tick, read one stick for pan/tilt and the other stick's Y
/// axis for zoom, apply sensitivity / tilt invert / speed modifier / brake (pan-tilt) or
/// sensitivity / invert / speed-modifier (zoom) in the same order `app/page.tsx` does, run both
/// through their momentum/glide models, encode via `PTZCommands`, and dispatch on the "pt" /
/// "zoom" channels so `CameraClient`'s throttle collapses same-channel sends to ~66ms apart.
///
/// Only one camera receives gamepad input at a time — AF state and momentum/modifier velocities
/// are per-camera (`CameraSession`), while gamepad-relative state (button edge detection, poll
/// timing) stays here since it doesn't belong to any one camera.
///
/// Reads a `ControlMapping` (see that file for exactly which fields are ported and why the
/// defaults are the user's own Electron-app values rather than `lib/mapping.ts`'s
/// `DEFAULT_MAPPING`). Full button remapping beyond what `ControlMapping.buttons` already
/// covers, plus focus/iris/gain/white-balance/presets/macros, are still out of scope for this
/// milestone.
@MainActor
final class PTZControlLoop: ObservableObject {
    private let gamepad: GamepadInput
    private let sessionStore: CameraSessionStore
    @Published var mapping: ControlMapping

    private var cancellable: AnyCancellable?

    private let stickDeadzone = 0.05

    /// Wall-clock time of the previous poll tick, used to compute `dt` for the glide's
    /// exponential decay — mirrors `lastFrameTime` in app/page.tsx (there driven by
    /// `performance.now()` each `requestAnimationFrame`; here by each gamepad poll tick, which
    /// GamepadInput drives at the same ~60Hz cadence). Gamepad-relative, not per-camera, so it
    /// stays here rather than on `CameraSession`.
    private var lastFrameTime = Date()

    /// Gamepad state as of the previous poll tick — used for press/release edge detection.
    /// Mirrors `prevButtons.current` in app/page.tsx, including where it's updated: only when
    /// `state.connected` is true (see the disconnected early-return below), so a disconnected
    /// controller's stale buttons don't register as "released" the moment it reconnects.
    /// Gamepad-relative, not per-camera, so it stays here rather than on `CameraSession`.
    private var previousState = GamepadState()

    private func pressed(_ button: ButtonId, in state: GamepadState) -> Bool {
        state.isPressed(button) && !previousState.isPressed(button)
    }

    private func released(_ button: ButtonId, in state: GamepadState) -> Bool {
        !state.isPressed(button) && previousState.isPressed(button)
    }

    init(gamepad: GamepadInput, sessionStore: CameraSessionStore, mapping: ControlMapping) {
        self.gamepad = gamepad
        self.sessionStore = sessionStore
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
            // camera panning indefinitely. Only the active session can have nonzero velocity —
            // switching cameras already zeros the outgoing one (CameraSessionStore.setActive).
            if let session = sessionStore.activeSession,
               session.panVelocity != 0 || session.tiltVelocity != 0 || session.zoomVelocity != 0 {
                session.stopPanTilt()
                session.client.send(PTZCommands.axisToZoomCmd(0), channel: "zoom")
                session.zoomVelocity = 0
            }
            return
        }

        guard let session = sessionStore.activeSession else {
            previousState = state
            return
        }
        let client = session.client

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
                session.toggleAutoFocus()
            case .oneTouchFocus:
                session.handleOneTouchFocusPress(mode: m.oneTouchFocusMode)
            case .toggleYield:
                client.toggleYield()
            case .cycleCamera:
                sessionStore.cycleActive()
            }
        }

        // Hold-mode release: mirrors app/page.tsx's separate post-loop check, run once per tick
        // independent of which button triggered the press above — finds whichever button is
        // CURRENTLY bound to oneTouchFocus (not necessarily the one that started the hold) and
        // checks whether it was just released.
        if m.oneTouchFocusMode == .hold, let afButton = m.button(for: .oneTouchFocus), released(afButton, in: state) {
            session.releaseOneTouchFocusHold()
        }

        // The rest of this tick — stick/D-pad/gyro/momentum computation AND the pan/tilt/zoom
        // sends — is suppressed entirely while this camera's AI tracker owns it.
        // `PersonTrackerSession` sends its own pan/tilt/zoom independently, straight through
        // this same session's `client`, on the same "pt"/"zoom" channels; leaving the gamepad
        // pipeline's computation running (even if only its sends were gated) would mean
        // `session.panVelocity`/`tiltVelocity`/`zoomVelocity` kept silently drifting from
        // whatever the stick was doing, producing a jump once tracking is turned back off.
        guard !session.tracker.isEnabled else {
            previousState = state
            return
        }

        // Speed modifier — hold the assigned button to scale PT (and optionally zoom) down.
        // Ported as a trigger (`TriggerId`) rather than a `ButtonId` per explicit request (see
        // ControlMapping's doc comment) — held state is a simple >0.5 threshold on the trigger
        // axis rather than a boolean button, since GameController exposes triggers as 0...1.
        // Computed unconditionally, ahead of the gyro-vs-stick branch below, because zoom's
        // pipeline further down needs session.currentModifierScale regardless of which pan/tilt
        // input source is active this tick — the multiplier itself eases toward its target (1.0
        // released, speedModifierValue held) rather than snapping instantly each tick, which is
        // what actually smooths the slow<->full-speed transition; the momentum stage further
        // below still runs on top of the eased result for ordinary stick-flick responsiveness,
        // untouched by this.
        let modifierHeld = state.value(m.speedModifierButton) > 0.5
        let modifierTargetScale = modifierHeld ? m.speedModifierValue : 1.0
        session.currentModifierScale = PTZMath.eased(current: session.currentModifierScale, target: modifierTargetScale, rate: m.modifierEaseRate)

        // Brake — continuously scales speed down proportional to how far the trigger is pressed
        // (not a hold-modifier threshold like speed modifier above), same formula as
        // app/page.tsx's R2-brake block. Also computed unconditionally, for the same reason as
        // the speed modifier above — zoom's pipeline needs brakeMultiplier regardless of pan/
        // tilt input source. An explicit deviation from app/page.tsx, where the brake only ever
        // touches pan/tilt — the user asked for the Swift version's brake to affect zoom as well.
        // No zoomMode "triggers" check here since that zoom input mode isn't implemented in this
        // milestone — the brake trigger is always available.
        var brakeMultiplier = 1.0
        if let brakeTrigger = m.brakeTrigger {
            let brake = state.value(brakeTrigger)
            if brake > 0.01 {
                brakeMultiplier = 1 - brake * (1 - m.brakeMinSpeed)
            }
        }

        // Gyro fine-adjust: hold both fineAdjustButtonA and fineAdjustButtonB to drive pan/tilt
        // directly from the controller's rotation rate for very fine framing nudges — bypasses
        // the stick, D-pad, speed modifier, brake, AND momentum entirely below (all deliberately:
        // a nudge like this should feel immediate, not glide or get scaled down further). Takes
        // precedence over the stick/D-pad whenever both are somehow active at once. On release,
        // the very next tick falls through to the else branch, whose momentum decay naturally
        // settles whatever small velocity this leaves behind — no separate release handling
        // needed since both branches write the same session.panVelocity/tiltVelocity.
        // GyroAxisMapping's axis/sign choice is a best guess, unverified on real hardware — see
        // GamepadInput.swift and the project README's Known Unknowns.
        let fineAdjustActive = m.fineAdjustEnabled
            && state.isPressed(m.fineAdjustButtonA) && state.isPressed(m.fineAdjustButtonB)

        if fineAdjustActive {
            let rawPan = GyroAxisMapping.pan(state) * GyroAxisMapping.panSign * m.fineAdjustSensitivity
            var rawTilt = GyroAxisMapping.tilt(state) * GyroAxisMapping.tiltSign * m.fineAdjustSensitivity
            if m.tiltInverted { rawTilt = -rawTilt }
            session.panVelocity = PTZMath.clamped(rawPan, to: m.fineAdjustMaxOutput)
            session.tiltVelocity = PTZMath.clamped(rawTilt, to: m.fineAdjustMaxOutput)
        } else {
            // Pan/tilt stick: left by default, right when swapped — matching DEFAULT_MAPPING
            // .panTiltAxis in lib/mapping.ts fed through app/page.tsx's SWAPPED_AXIS remap.
            var panTarget = (m.sticksSwapped ? state.rightX : state.leftX) * m.ptSensitivity
            var tiltTarget = (m.sticksSwapped ? state.rightY : state.leftY) * m.ptSensitivity

            // D-pad "fine pan/tilt" override — checked every tick against current held state
            // (level-based, not press-edge), each of the four directions independent since they
            // needn't all be bound together. Overrides (not adds to) the stick-derived target.
            // app/page.tsx has an equivalent block at the same pipeline position (after the
            // initial stick-target computation but before tilt-invert, so a d-pad-driven value
            // still flows through tilt-invert/speed-modifier/brake/momentum below exactly like a
            // stick one would) but with a fixed DPAD_SPEED = 0.4 — this app uses the tunable,
            // lower-by-default m.dpadFineSpeed instead (0.4 read as too coarse for fine framing
            // nudges).
            if m.buttons[.dpadLeft] == .finePanTilt && state.dpadLeft { panTarget = -m.dpadFineSpeed }
            if m.buttons[.dpadRight] == .finePanTilt && state.dpadRight { panTarget = m.dpadFineSpeed }
            if m.buttons[.dpadUp] == .finePanTilt && state.dpadUp { tiltTarget = -m.dpadFineSpeed }
            if m.buttons[.dpadDown] == .finePanTilt && state.dpadDown { tiltTarget = m.dpadFineSpeed }

            // Tilt invert — applied uniformly, same point in the pipeline as app/page.tsx.
            if m.tiltInverted { tiltTarget = -tiltTarget }

            // Apply the speed-modifier scale and brake multiplier computed above.
            panTarget *= session.currentModifierScale
            tiltTarget *= session.currentModifierScale
            panTarget *= brakeMultiplier
            tiltTarget *= brakeMultiplier

            // Momentum: lerp velocity toward the stick target while pushed past the deadzone, decay
            // toward 0 (half-life = momentumGlideMs) once released — exact port of app/page.tsx's
            // momentum block, including its 0.01 snap-to-zero noise floor.
            if m.momentumEnabled {
                let panMoving = abs(panTarget) > stickDeadzone
                let tiltMoving = abs(tiltTarget) > stickDeadzone
                let decayPerMs = log(2) / m.momentumGlideMs
                let decayFactor = exp(-decayPerMs * dt)

                session.panVelocity = panMoving ? session.panVelocity + (panTarget - session.panVelocity) * m.momentumAccel : session.panVelocity * decayFactor
                session.tiltVelocity = tiltMoving ? session.tiltVelocity + (tiltTarget - session.tiltVelocity) * m.momentumAccel : session.tiltVelocity * decayFactor

                if abs(session.panVelocity) < 0.01 { session.panVelocity = 0 }
                if abs(session.tiltVelocity) < 0.01 { session.tiltVelocity = 0 }
            } else {
                session.panVelocity = panTarget
                session.tiltVelocity = tiltTarget
            }
        }

        // Sent unconditionally every poll tick (like app/page.tsx's `sendContinuous` call) —
        // CameraClient's own per-channel throttle collapses this to ~66ms apart, and
        // axisToPanTiltCmd's own deadzone naturally produces the stop command once velocity
        // decays to ~0, so there's no need to gate the send on an "is moving" flag here (doing
        // so would cut the glide off the instant the raw stick recenters, since the whole point
        // of momentum is that the camera keeps moving briefly after release).
        client.sendContinuous(PTZCommands.axisToPanTiltCmd(pan: session.panVelocity, tilt: session.tiltVelocity), channel: "pt")

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
        // Reuses the already-eased session.currentModifierScale (not a fresh modifierHeld ?
        // value : 1 step) so zoom eases in and out exactly like pan/tilt does above — leaving
        // this one abrupt while pan/tilt eases would have been an inconsistent half-fix.
        let zoomModifier = m.speedModifierAffectsZoom ? session.currentModifierScale : 1
        let zoomTarget = max(-1, min(1, rawZoom * m.zoomSensitivity * zoomModifier * brakeMultiplier))

        // Zoom momentum — same half-life decay model as pan/tilt, gated by its own enable flag
        // and glide time (Electron: on, 400ms, matching the user's saved config).
        if m.zoomMomentumEnabled {
            let zoomMoving = abs(zoomTarget) > stickDeadzone
            let decayPerMs = log(2) / m.zoomMomentumGlideMs
            let decayFactor = exp(-decayPerMs * dt)
            session.zoomVelocity = zoomMoving ? session.zoomVelocity + (zoomTarget - session.zoomVelocity) * m.momentumAccel : session.zoomVelocity * decayFactor
            if abs(session.zoomVelocity) < 0.01 { session.zoomVelocity = 0 }
        } else {
            session.zoomVelocity = zoomTarget
        }

        client.sendContinuous(PTZCommands.axisToZoomCmd(session.zoomVelocity), channel: "zoom")

        // Must happen last, after this tick's edge detection above has used the PREVIOUS state —
        // matches app/page.tsx's `prevButtons.current = state` assignment at the end of onFrame.
        previousState = state
    }
}
