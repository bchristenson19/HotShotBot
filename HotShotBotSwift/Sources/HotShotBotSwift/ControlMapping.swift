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

    // Speed modifier — hold `speedModifierButton` to scale PT (and optionally zoom) by
    // `speedModifierValue`. Electron has this on L1 in "slow" mode at 55%; ported to L2 here
    // per explicit request (Electron's ButtonId can't target L2 — a trigger — at all, so this
    // is a native-app-only extension of the button-action model, not a TS behavior gap).
    var speedModifierButton: TriggerId = .l2
    var speedModifierValue: Double = 0.55     // Electron: 55% ("slow" mode)
    var speedModifierAffectsZoom: Bool = true // Electron: on

    // Brake — trigger that scales pan/tilt AND zoom speed down continuously (not a hold-
    // modifier; proportional to how far the trigger is pressed). Electron: R2, min speed 8% at
    // full press, pan/tilt only — this native app extends the brake to zoom too, per explicit
    // request (a deviation from app/page.tsx, where the brake never touches zoom).
    var brakeTrigger: TriggerId? = .r2
    var brakeMinSpeed: Double = 0.08

    // Zoom
    var zoomInverted: Bool = true             // Electron: on (push up = zoom in/tele)
    var zoomSensitivity: Double = 0.80        // Electron: 80%
    var zoomMomentumEnabled: Bool = true      // Electron: on
    var zoomMomentumGlideMs: Double = 400     // Electron: 400ms

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
