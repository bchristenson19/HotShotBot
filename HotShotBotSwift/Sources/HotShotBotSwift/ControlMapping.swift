import Foundation

/// Buttons that can be assigned an action — matches `ButtonId` in `lib/mapping.ts`. Notably
/// L2/R2 are NOT here (same as the TS version): they're trigger axes, used only for brake/iris/
/// zoom-trigger-mode, never for a discrete "hold to activate" button binding — see
/// `PTZControlLoop`'s speed-modifier doc comment for why L2 is still special-cased there.
enum ButtonId: String, Codable, CaseIterable, Hashable {
    case cross, circle, square, triangle
    case l1, r1, l3, r3
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case options, touchpad

    var label: String {
        switch self {
        case .cross: return "✕"
        case .circle: return "○"
        case .square: return "□"
        case .triangle: return "△"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l3: return "L3"
        case .r3: return "R3"
        case .dpadUp: return "D-Pad ↑"
        case .dpadDown: return "D-Pad ↓"
        case .dpadLeft: return "D-Pad ←"
        case .dpadRight: return "D-Pad →"
        case .options: return "Options"
        case .touchpad: return "Touchpad"
        }
    }
}

/// Actions assignable to a button — subset of `ActionId`/`BUTTON_ACTIONS` in `lib/mapping.ts`,
/// limited to what this milestone's control loop actually implements. Preset recall, macros,
/// cycleWB, focus-near/far, gain, iris actions all exist in the TS version but aren't ported yet
/// (no presets/macros/focus-iris-gain-WB support here at all). `cycleCamera` IS included even
/// though this app is single-camera only — see `PTZControlLoop`'s dispatch for why it's a
/// deliberate no-op rather than omitted (so a full button layout carries over once multi-camera
/// support lands, without needing to be reconfigured).
///
/// `ptSpeedModifier` is deliberately NOT a case here — speed-modifier is trigger-based
/// (`ControlMapping.speedModifierButton`, a `TriggerId`), not button-based, per explicit
/// request; a button-action case for it would be dead (never read by `PTZControlLoop`).
enum ButtonActionId: String, Codable, CaseIterable, Hashable {
    case none
    case toggleAutoFocus
    case oneTouchFocus
    case toggleYield
    case finePanTilt
    case cycleCamera

    var label: String {
        switch self {
        case .none: return "None"
        case .toggleAutoFocus: return "Toggle Auto Focus"
        case .oneTouchFocus: return "One-Touch Focus"
        case .toggleYield: return "Toggle Yield to RP-200"
        case .finePanTilt: return "Fine Pan/Tilt"
        case .cycleCamera: return "Cycle Camera"
        }
    }
}

/// Pulse vs. hold behavior for the `oneTouchFocus` action — matches `oneTouchFocusMode` in
/// `lib/mapping.ts` (TS default: `"pulse"`).
enum OneTouchFocusMode: String, Codable, CaseIterable {
    case pulse, hold
    var label: String { rawValue.capitalized }
}

/// Which trigger (if any) acts as the pan/tilt brake, or L2 for the speed-modifier special case.
/// Matches the "l2"/"r2" values of `AxisId` in `lib/mapping.ts`.
enum TriggerId: String, Codable, CaseIterable {
    case l2, r2
    var label: String { rawValue.uppercased() }
}

/// Subset of `ControlMapping` from `lib/mapping.ts` — only the fields this milestone's
/// `PTZControlLoop` actually reads. Persisted the same way as `CameraSettings` (UserDefaults,
/// JSON-encoded) rather than localStorage, since this is a native app.
///
/// Defaults below are NOT `lib/mapping.ts`'s `DEFAULT_MAPPING` — they're the user's own saved
/// values from the Electron app's Remap modal (screenshotted 2026-08-10), since the ask was
/// specifically "same as what I've set", not "same as the TS app's shipped defaults". Two
/// deltas from the Electron config by explicit request: `sticksSwapped` defaults to `true` here
/// (TS default: `false`), and the speed-modifier button is `l2` here (Electron: `l1`, so `l1` is
/// unbound below rather than carrying over Electron's `saveModifier`/speed-modifier binding —
/// this app has no preset-save feature yet for `saveModifier` to gate anyway).
struct ControlMapping: Codable, Equatable {
    /// Matches the user's real Electron button layout (screenshotted 2026-08-10), translated
    /// for the two deltas above. cross/circle/square/l1/r1 are intentionally absent (unbound) —
    /// a missing key reads as `.none` via `buttons[button] ?? .none` wherever this is consulted.
    var buttons: [ButtonId: ButtonActionId] = [
        .triangle: .toggleYield,
        .l3: .oneTouchFocus,
        .r3: .toggleAutoFocus,
        .dpadUp: .finePanTilt,
        .dpadDown: .finePanTilt,
        .dpadLeft: .finePanTilt,
        .dpadRight: .finePanTilt,
        .options: .cycleCamera,
        .touchpad: .toggleAutoFocus,
    ]

    var oneTouchFocusMode: OneTouchFocusMode = .pulse

    // Pan/tilt
    var sticksSwapped: Bool = true
    var ptSensitivity: Double = 0.60          // Electron: 60%
    var tiltInverted: Bool = false            // Electron: off
    var momentumEnabled: Bool = true          // Electron: on
    var momentumGlideMs: Double = 400         // Electron: 400ms
    var momentumAccel: Double = 0.24          // Electron: 24%

    // D-pad "fine pan/tilt" step size (see the override in PTZControlLoop.handle(_:)) — was a
    // bare 0.4 literal with no easing; 0.4 read as too coarse for fine framing nudges, so this is
    // now a named, user-tunable field instead.
    var dpadFineSpeed: Double = 0.18

    // Speed modifier — hold `speedModifierButton` to scale PT (and optionally zoom) by
    // `speedModifierValue`. Electron has this on L1 in "slow" mode at 55%; ported to L2 here
    // per explicit request (Electron's ButtonId can't target L2 — a trigger — at all, so this
    // is a native-app-only extension of the button-action model, not a TS behavior gap).
    var speedModifierButton: TriggerId = .l2
    var speedModifierValue: Double = 0.55     // Electron: 55% ("slow" mode)
    var speedModifierAffectsZoom: Bool = true // Electron: on

    // How quickly the EFFECTIVE modifier multiplier itself eases toward speedModifierValue (or
    // back to 1.0 on release), each tick — same eased(current:target:rate:) shape as
    // momentumAccel, but a dedicated field rather than reusing it: this smooths the modifier
    // engage/release transition specifically, without changing how momentum handles an ordinary
    // stick flick. 1.0 reproduces the old instant-step behavior; see PTZMath.eased.
    var modifierEaseRate: Double = 0.20

    // Brake — trigger that scales pan/tilt AND zoom speed down continuously (not a hold-
    // modifier; proportional to how far the trigger is pressed). Electron: R2, min speed 8% at
    // full press, pan/tilt only — this native app extends the brake to zoom too, per explicit
    // request (a deviation from app/page.tsx, where the brake never touches zoom).
    var brakeTrigger: TriggerId? = .r2
    var brakeMinSpeed: Double = 0.08

    // Gyro "fine adjust" — hold BOTH fineAdjustButtonA and fineAdjustButtonB simultaneously to
    // drive pan/tilt directly off the DualSense's gyro rotation rate instead of the stick, for
    // very fine framing nudges (see PTZControlLoop.handle(_:)). Deliberately a pair of dedicated
    // ButtonId fields, like speedModifierButton/brakeTrigger above, rather than a ButtonActionId
    // case — a two-button chord for a mode switch doesn't fit the one-button-to-one-action shape
    // of `buttons`. .l1/.r1 are unbound in the default `buttons` dict above, so this doesn't
    // collide with anything.
    var fineAdjustEnabled: Bool = true
    var fineAdjustButtonA: ButtonId = .l1
    var fineAdjustButtonB: ButtonId = .r1
    var fineAdjustSensitivity: Double = 0.15   // rotationRate (rad/s) -> pan/tilt target scale
    var fineAdjustMaxOutput: Double = 0.35     // hard ceiling regardless of how fast the twist is

    // Zoom
    var zoomInverted: Bool = true             // Electron: on (push up = zoom in/tele)
    var zoomSensitivity: Double = 0.80        // Electron: 80%
    var zoomMomentumEnabled: Bool = true      // Electron: on
    var zoomMomentumGlideMs: Double = 400     // Electron: 400ms

    /// Plain `init()` restoring the zero-argument construction (e.g. `ControlMapping()` in
    /// `load()`'s fallback) that a struct normally gets for free from its compiler-synthesized
    /// memberwise initializer — declaring `init(from:)` below suppresses that synthesis, so this
    /// has to be spelled out explicitly. Every property already has a `= default` above, so an
    /// empty body is sufficient.
    init() {}

    private enum CodingKeys: String, CodingKey {
        case buttons, oneTouchFocusMode
        case sticksSwapped, ptSensitivity, tiltInverted, momentumEnabled, momentumGlideMs, momentumAccel
        case dpadFineSpeed
        case speedModifierButton, speedModifierValue, speedModifierAffectsZoom, modifierEaseRate
        case brakeTrigger, brakeMinSpeed
        case fineAdjustEnabled, fineAdjustButtonA, fineAdjustButtonB, fineAdjustSensitivity, fineAdjustMaxOutput
        case zoomInverted, zoomSensitivity, zoomMomentumEnabled, zoomMomentumGlideMs
    }

    /// Hand-written so adding a field never breaks decoding an older saved mapping. The
    /// compiler-synthesized `Decodable` only falls back to a property's `= default` when the key
    /// is missing AND the property's type is `Optional` — every field here is non-optional (for
    /// plain `Double`/`Bool`/enum storage), so a synthesized init would throw on any key this
    /// version doesn't yet know about, and `load()`'s `try?` would silently discard the user's
    /// entire saved mapping. `decodeIfPresent(...) ?? default` matches `lib/mapping.ts`'s
    /// `loadMapping()`, which solves the identical problem field-by-field for the same reason.
    /// `encode(to:)` is left compiler-synthesized against the `CodingKeys` above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControlMapping()
        buttons = try c.decodeIfPresent([ButtonId: ButtonActionId].self, forKey: .buttons) ?? d.buttons
        oneTouchFocusMode = try c.decodeIfPresent(OneTouchFocusMode.self, forKey: .oneTouchFocusMode) ?? d.oneTouchFocusMode
        sticksSwapped = try c.decodeIfPresent(Bool.self, forKey: .sticksSwapped) ?? d.sticksSwapped
        ptSensitivity = try c.decodeIfPresent(Double.self, forKey: .ptSensitivity) ?? d.ptSensitivity
        tiltInverted = try c.decodeIfPresent(Bool.self, forKey: .tiltInverted) ?? d.tiltInverted
        momentumEnabled = try c.decodeIfPresent(Bool.self, forKey: .momentumEnabled) ?? d.momentumEnabled
        momentumGlideMs = try c.decodeIfPresent(Double.self, forKey: .momentumGlideMs) ?? d.momentumGlideMs
        momentumAccel = try c.decodeIfPresent(Double.self, forKey: .momentumAccel) ?? d.momentumAccel
        dpadFineSpeed = try c.decodeIfPresent(Double.self, forKey: .dpadFineSpeed) ?? d.dpadFineSpeed
        speedModifierButton = try c.decodeIfPresent(TriggerId.self, forKey: .speedModifierButton) ?? d.speedModifierButton
        speedModifierValue = try c.decodeIfPresent(Double.self, forKey: .speedModifierValue) ?? d.speedModifierValue
        speedModifierAffectsZoom = try c.decodeIfPresent(Bool.self, forKey: .speedModifierAffectsZoom) ?? d.speedModifierAffectsZoom
        modifierEaseRate = try c.decodeIfPresent(Double.self, forKey: .modifierEaseRate) ?? d.modifierEaseRate
        brakeTrigger = try c.decodeIfPresent(TriggerId?.self, forKey: .brakeTrigger) ?? d.brakeTrigger
        brakeMinSpeed = try c.decodeIfPresent(Double.self, forKey: .brakeMinSpeed) ?? d.brakeMinSpeed
        fineAdjustEnabled = try c.decodeIfPresent(Bool.self, forKey: .fineAdjustEnabled) ?? d.fineAdjustEnabled
        fineAdjustButtonA = try c.decodeIfPresent(ButtonId.self, forKey: .fineAdjustButtonA) ?? d.fineAdjustButtonA
        fineAdjustButtonB = try c.decodeIfPresent(ButtonId.self, forKey: .fineAdjustButtonB) ?? d.fineAdjustButtonB
        fineAdjustSensitivity = try c.decodeIfPresent(Double.self, forKey: .fineAdjustSensitivity) ?? d.fineAdjustSensitivity
        fineAdjustMaxOutput = try c.decodeIfPresent(Double.self, forKey: .fineAdjustMaxOutput) ?? d.fineAdjustMaxOutput
        zoomInverted = try c.decodeIfPresent(Bool.self, forKey: .zoomInverted) ?? d.zoomInverted
        zoomSensitivity = try c.decodeIfPresent(Double.self, forKey: .zoomSensitivity) ?? d.zoomSensitivity
        zoomMomentumEnabled = try c.decodeIfPresent(Bool.self, forKey: .zoomMomentumEnabled) ?? d.zoomMomentumEnabled
        zoomMomentumGlideMs = try c.decodeIfPresent(Double.self, forKey: .zoomMomentumGlideMs) ?? d.zoomMomentumGlideMs
    }

    private static let defaultsKey = "com.hotshotbot.controlMapping"

    static func load() -> ControlMapping {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ControlMapping.self, from: data)
        else { return ControlMapping() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// The button (if any) currently assigned to a given action — mirrors the
    /// `Object.entries(m.buttons).find(([, v]) => v === action)` lookup pattern used throughout
    /// `app/page.tsx`.
    func button(for action: ButtonActionId) -> ButtonId? {
        buttons.first { $0.value == action }?.key
    }
}

/// Reads a `ButtonId`'s current pressed state off a `GamepadState` — needed because
/// `GamepadState`'s button fields are plain stored properties, not subscriptable by a
/// `ButtonId` value without this bridge (Swift has no dynamic keypath-by-string-name lookup as
/// convenient as the TS version's `state[key as keyof GamepadState]`).
extension GamepadState {
    func isPressed(_ button: ButtonId) -> Bool {
        switch button {
        case .cross: return cross
        case .circle: return circle
        case .square: return square
        case .triangle: return triangle
        case .l1: return l1
        case .r1: return r1
        case .l3: return l3
        case .r3: return r3
        case .dpadUp: return dpadUp
        case .dpadDown: return dpadDown
        case .dpadLeft: return dpadLeft
        case .dpadRight: return dpadRight
        case .options: return options
        case .touchpad: return touchpad
        }
    }

    /// 0...1 trigger value for a `TriggerId`.
    func value(_ trigger: TriggerId) -> Double {
        switch trigger {
        case .l2: return l2
        case .r2: return r2
        }
    }
}
