// Controller button/axis mapping configuration

export type ActionId =
  | "panTilt"
  | "zoom"
  | "focus"
  | "irisOpen"
  | "irisClose"
  | "finePanTilt"
  | "recallPreset1"
  | "recallPreset2"
  | "recallPreset3"
  | "recallPreset4"
  | "saveModifier"
  | "toggleAutoFocus"
  | "oneTouchFocus"
  | "cycleCamera"
  | "cycleWB"
  | "macro1"
  | "macro2"
  | "macro3"
  | "macro4"
  | "irisOpenBtn"
  | "irisCloseBtn"
  | "irisAutoToggle"
  | "gainUp"
  | "gainDown"
  | "focusNear"
  | "focusFar"
  | "ptSpeedModifier";

export type ButtonId =
  | "cross" | "circle" | "square" | "triangle"
  | "l1" | "r1" | "l3" | "r3"
  | "dpadUp" | "dpadDown" | "dpadLeft" | "dpadRight"
  | "options" | "touchpad";

export type AxisId = "leftX" | "leftY" | "rightX" | "rightY" | "l2" | "r2";

export interface MacroConfig {
  label: string;
  cmd: string; // raw AW-UE70 CGI command, e.g. "#R05"
  toggle: boolean; // if true, alternates between cmd and offCmd
  offCmd: string;
}

export interface ButtonMapping {
  button: ButtonId;
  action: ActionId;
}

export interface AxisMapping {
  axis: AxisId;
  action: "panTilt" | "zoom" | "focus" | "irisOpen" | "irisClose";
}

export interface ControlMapping {
  buttons: Record<ButtonId, ActionId>;
  panTiltAxis: { x: AxisId; y: AxisId };
  zoomAxis: AxisId;
  focusAxis: AxisId;
  irisOpenAxis: AxisId;
  irisCloseAxis: AxisId;
  // When set, this trigger axis acts as a speed brake for pan/tilt.
  // 0 = full speed, 1 = minBrakeSpeed (precision crawl).
  oneTouchFocusMode: "pulse" | "hold";
  ptSpeedModifierValue: number;  // multiplier applied while button is held (e.g. 0.3 = slow, 2.0 = fast)
  ptSpeedModifierMode: "slow" | "fast";
  ptSpeedModifierAffectsZoom: boolean;
  ptBrakeAxis: AxisId | null;
  ptBrakeMinSpeed: number;
  zoomInverted: boolean;
  zoomSensitivity: number;   // 0.1–1.0 multiplier on zoom axis
  zoomMomentumEnabled: boolean;
  zoomMomentumGlideMs: number;
  // "stick" = right stick Y (default), "triggers" = L2 out / R2 in
  zoomMode: "stick" | "triggers";
  // "single" = left stick only, "dual" = both sticks added (left=coarse, right=fine trim)
  ptMode: "single" | "dual";
  ptFineScale: number;
  ptSensitivity: number; // 0.1–1.0 multiplier on the left stick output
  tiltInverted: boolean; // flips tilt direction (push up = tilt down)
  momentumEnabled: boolean;
  momentumGlideMs: number;  // how long (ms) velocity takes to reach ~0 after release
  momentumAccel: number;    // 0–1, how quickly velocity tracks the stick (1 = instant)
  macros: [MacroConfig, MacroConfig, MacroConfig, MacroConfig];
  // Camera preset slot index each face button recalls [cross, circle, square, triangle]
  presetBindings: [number, number, number, number];
}

export const ACTION_LABELS: Record<ActionId, string> = {
  panTilt: "Pan / Tilt",
  zoom: "Zoom",
  focus: "Focus",
  irisOpen: "Iris Open",
  irisClose: "Iris Close",
  finePanTilt: "Fine Pan/Tilt",
  recallPreset1: "Recall Preset 1",
  recallPreset2: "Recall Preset 2",
  recallPreset3: "Recall Preset 3",
  recallPreset4: "Recall Preset 4",
  saveModifier: "Save Modifier (hold)",
  toggleAutoFocus: "Toggle Auto Focus",
  oneTouchFocus: "One-Touch Focus",
  cycleCamera: "Cycle Camera",
  cycleWB: "Cycle White Balance",
  macro1: "Macro 1",
  macro2: "Macro 2",
  macro3: "Macro 3",
  macro4: "Macro 4",
  irisOpenBtn: "Iris Open",
  irisCloseBtn: "Iris Close",
  irisAutoToggle: "Iris Auto Toggle",
  gainUp: "Gain Up",
  gainDown: "Gain Down",
  focusNear: "Focus Near",
  focusFar: "Focus Far",
  ptSpeedModifier: "PT Speed Modifier (hold)",
};

export const BUTTON_LABELS: Record<ButtonId, string> = {
  cross: "✕", circle: "○", square: "□", triangle: "△",
  l1: "L1", r1: "R1", l3: "L3", r3: "R3",
  dpadUp: "↑", dpadDown: "↓", dpadLeft: "←", dpadRight: "→",
  options: "Options", touchpad: "Touchpad",
};

export const BUTTON_IDS: ButtonId[] = [
  "cross", "circle", "square", "triangle",
  "l1", "r1", "l3", "r3",
  "dpadUp", "dpadDown", "dpadLeft", "dpadRight",
  "options", "touchpad",
];

export const BUTTON_ACTIONS: ActionId[] = [
  "recallPreset1", "recallPreset2", "recallPreset3", "recallPreset4",
  "saveModifier", "ptSpeedModifier", "toggleAutoFocus", "oneTouchFocus", "cycleCamera", "cycleWB",
  "finePanTilt",
  "macro1", "macro2", "macro3", "macro4",
  "irisOpenBtn", "irisCloseBtn", "irisAutoToggle",
  "gainUp", "gainDown",
  "focusNear", "focusFar",
];

export const DEFAULT_MAPPING: ControlMapping = {
  buttons: {
    cross: "recallPreset1",
    circle: "recallPreset2",
    square: "recallPreset3",
    triangle: "recallPreset4",
    l1: "saveModifier",
    r1: "saveModifier",
    l3: "toggleAutoFocus",
    r3: "cycleWB",
    dpadUp: "finePanTilt",
    dpadDown: "finePanTilt",
    dpadLeft: "finePanTilt",
    dpadRight: "finePanTilt",
    options: "cycleCamera",
    touchpad: "cycleWB",
  },
  panTiltAxis: { x: "leftX", y: "leftY" },
  zoomAxis: "rightY",
  focusAxis: "rightX",
  irisOpenAxis: "r2",
  irisCloseAxis: "l2",
  oneTouchFocusMode: "pulse",
  ptSpeedModifierValue: 0.3,
  ptSpeedModifierMode: "slow",
  ptSpeedModifierAffectsZoom: false,
  ptBrakeAxis: "r2",
  ptBrakeMinSpeed: 0.08,
  zoomInverted: true, // push stick up = zoom in (tele), pull down = zoom out (wide)
  zoomSensitivity: 1.0,
  zoomMomentumEnabled: false,
  zoomMomentumGlideMs: 400,
  zoomMode: "stick",
  ptMode: "single",
  ptFineScale: 0.5,
  ptSensitivity: 1.0,
  tiltInverted: false,
  momentumEnabled: true,
  momentumGlideMs: 400,
  momentumAccel: 0.18,
  macros: [
    { label: "Macro 1", cmd: "", toggle: false, offCmd: "" },
    { label: "Macro 2", cmd: "", toggle: false, offCmd: "" },
    { label: "Macro 3", cmd: "", toggle: false, offCmd: "" },
    { label: "Macro 4", cmd: "", toggle: false, offCmd: "" },
  ],
  presetBindings: [0, 1, 2, 3],
};

export function loadMapping(): ControlMapping {
  if (typeof window === "undefined") return DEFAULT_MAPPING;
  try {
    const raw = localStorage.getItem("ptz-mapping");
    if (raw) {
      const parsed = JSON.parse(raw);
      const n = (val: unknown, fallback: number) =>
        typeof val === "number" && isFinite(val) ? val : fallback;
      return {
        ...DEFAULT_MAPPING,
        ...parsed,
        // Always deep-merge nested objects so new keys aren't lost
        panTiltAxis: { ...DEFAULT_MAPPING.panTiltAxis, ...(parsed.panTiltAxis ?? {}) },
        buttons: { ...DEFAULT_MAPPING.buttons, ...(parsed.buttons ?? {}) },
        macros: parsed.macros ?? DEFAULT_MAPPING.macros,
        // Explicit fallbacks for all scalar fields — guards against NaN from old storage
        ptBrakeMinSpeed: n(parsed.ptBrakeMinSpeed, DEFAULT_MAPPING.ptBrakeMinSpeed),
        momentumGlideMs: n(parsed.momentumGlideMs, DEFAULT_MAPPING.momentumGlideMs),
        momentumAccel: n(parsed.momentumAccel, DEFAULT_MAPPING.momentumAccel),
        ptFineScale: n(parsed.ptFineScale, DEFAULT_MAPPING.ptFineScale),
        ptSensitivity: n(parsed.ptSensitivity, DEFAULT_MAPPING.ptSensitivity),
        tiltInverted: parsed.tiltInverted ?? DEFAULT_MAPPING.tiltInverted,
        oneTouchFocusMode: parsed.oneTouchFocusMode ?? DEFAULT_MAPPING.oneTouchFocusMode,
        ptSpeedModifierValue: n(parsed.ptSpeedModifierValue, DEFAULT_MAPPING.ptSpeedModifierValue),
        ptSpeedModifierMode: parsed.ptSpeedModifierMode ?? DEFAULT_MAPPING.ptSpeedModifierMode,
        ptSpeedModifierAffectsZoom: parsed.ptSpeedModifierAffectsZoom ?? DEFAULT_MAPPING.ptSpeedModifierAffectsZoom,
        zoomSensitivity: n(parsed.zoomSensitivity, DEFAULT_MAPPING.zoomSensitivity),
        zoomMomentumEnabled: parsed.zoomMomentumEnabled ?? DEFAULT_MAPPING.zoomMomentumEnabled,
        zoomMomentumGlideMs: n(parsed.zoomMomentumGlideMs, DEFAULT_MAPPING.zoomMomentumGlideMs),
        ptBrakeAxis: parsed.ptBrakeAxis ?? DEFAULT_MAPPING.ptBrakeAxis,
        zoomAxis: parsed.zoomAxis ?? DEFAULT_MAPPING.zoomAxis,
        focusAxis: parsed.focusAxis ?? DEFAULT_MAPPING.focusAxis,
        irisOpenAxis: parsed.irisOpenAxis ?? DEFAULT_MAPPING.irisOpenAxis,
        irisCloseAxis: parsed.irisCloseAxis ?? DEFAULT_MAPPING.irisCloseAxis,
        zoomMode: parsed.zoomMode ?? DEFAULT_MAPPING.zoomMode,
        ptMode: parsed.ptMode ?? DEFAULT_MAPPING.ptMode,
        zoomInverted: parsed.zoomInverted ?? DEFAULT_MAPPING.zoomInverted,
        momentumEnabled: parsed.momentumEnabled ?? DEFAULT_MAPPING.momentumEnabled,
        presetBindings: Array.isArray(parsed.presetBindings) && parsed.presetBindings.length === 4
          ? parsed.presetBindings as [number, number, number, number]
          : DEFAULT_MAPPING.presetBindings,
      };
    }
  } catch {}
  return DEFAULT_MAPPING;
}

export function saveMapping(m: ControlMapping) {
  localStorage.setItem("ptz-mapping", JSON.stringify(m));
}

// ── Profiles ─────────────────────────────────────────────────────────────────

export interface Profile {
  id: string;
  name: string;
  createdAt: number;
  mapping: ControlMapping;
}

export function loadProfiles(): Profile[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = localStorage.getItem("ptz-profiles");
    if (raw) return JSON.parse(raw);
  } catch {}
  return [];
}

export function saveProfiles(profiles: Profile[]) {
  localStorage.setItem("ptz-profiles", JSON.stringify(profiles));
}
