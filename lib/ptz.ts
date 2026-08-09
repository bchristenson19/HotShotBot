// Panasonic AW-UE70 HTTP CGI command library
// Docs: AW-UE70 Operating Instructions / External Control Specifications

export type CameraModel = "aw-ue70" | "aw-ue160" | "aw-he130" | "virtual";

export interface Camera {
  id: string;
  name: string;
  ip: string;
  port: number;
  model: CameraModel;
  streamUrl?: string;
  color?: string; // hex color for the light bar, e.g. "#1d4ed8"
}

export function isVirtual(cam: Camera | null | undefined): boolean {
  return cam?.model === "virtual";
}

const DEFAULT_CAMERA_COLORS = ["#1d4ed8", "#059669", "#dc2626", "#7c3aed"];
export function defaultCameraColor(index: number): string {
  return DEFAULT_CAMERA_COLORS[index % DEFAULT_CAMERA_COLORS.length];
}

// Model-specific default MJPEG endpoints
const STREAM_PATHS: Record<CameraModel, string> = {
  "aw-ue70":   "/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30",
  "aw-ue160":  "/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30",
  "aw-he130":  "/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30",
  "virtual":   "",
};

export function defaultStreamUrl(cam: Camera): string {
  if (cam.model === "virtual") return "";
  if (!cam.ip) return "";
  const path = STREAM_PATHS[cam.model] ?? STREAM_PATHS["aw-ue70"];
  return `http://${cam.ip}${path}`;
}

export type PanTiltSpeed = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 | 26 | 27 | 28 | 29 | 30;
export type ZoomSpeed = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 | 26 | 27 | 28 | 29 | 30;

// Converts a joystick axis value (-1..1) to a pan/tilt speed hex pair
// The AW-UE70 uses a combined PTS command: #PTSXX YY
// XX = pan speed+direction (01-31 left, 50 stop, 51-99 right)
// YY = tilt speed+direction (01-31 down, 50 stop, 51-99 up)
export function axisToPanTiltCmd(panAxis: number, tiltAxis: number): string {
  const panVal = axisToSpeedByte(panAxis, true);
  const tiltVal = axisToSpeedByte(tiltAxis, false);
  return `#PTS${panVal}${tiltVal}`;
}

function axisToSpeedByte(axis: number, invert: boolean): string {
  const v = invert ? axis : -axis;
  if (Math.abs(v) < 0.05) return "50"; // deadzone → stop
  const speed = Math.round(Math.abs(v) * 30); // 1-30
  const clamped = Math.max(1, Math.min(30, speed));
  const byte = v > 0 ? 50 + clamped : 50 - clamped;
  return byte.toString().padStart(2, "0");
}

// Zoom: #Z0 (stop) to #Z99 wide, or #OZSX where X = speed
// AW-UE70 uses #ZXX where 01-49 = wide, 50 = stop, 51-99 = tele
export function axisToZoomCmd(axis: number): string {
  if (Math.abs(axis) < 0.05) return "#Z50";
  const speed = Math.round(Math.abs(axis) * 49);
  const clamped = Math.max(1, Math.min(49, speed));
  const byte = axis > 0 ? 50 + clamped : 50 - clamped;
  return `#Z${byte.toString().padStart(2, "0")}`;
}

// Focus: #F01-#F49 = near, #F50 = stop, #F51-#F99 = far
export function axisToFocusCmd(axis: number): string {
  if (Math.abs(axis) < 0.08) return "#F50";
  const speed = Math.round(Math.abs(axis) * 49);
  const clamped = Math.max(1, Math.min(49, speed));
  const byte = axis > 0 ? 50 + clamped : 50 - clamped;
  return `#F${byte.toString().padStart(2, "0")}`;
}

// Auto focus on/off — aw_cam endpoint
export function autoFocusCmd(on: boolean): { cmd: string; endpoint: string } {
  return { cmd: on ? "OSE:69:1" : "OSE:69:0", endpoint: "aw_cam" };
}

// One-touch focus — pulse AF on then off after a short delay
export const ONE_TOUCH_FOCUS_CMD = { cmd: "OSE:69:1", endpoint: "aw_cam" } as const;
export const ONE_TOUCH_FOCUS_OFF = { cmd: "OSE:69:0", endpoint: "aw_cam" } as const;

// Iris nudge — aw_cam endpoint
// LIO = open one step, LIC = close one step, LIT = commit (must follow every nudge)
export const IRIS_OPEN_CMD   = { cmd: "LIO", endpoint: "aw_cam" } as const;
export const IRIS_CLOSE_CMD  = { cmd: "LIC", endpoint: "aw_cam" } as const;
export const IRIS_COMMIT_CMD = { cmd: "LIT", endpoint: "aw_cam" } as const;

// Legacy shim so existing callers don't break — returns open/close objects
export function irisCmd(direction: "open" | "close" | "stop") {
  if (direction === "open") return IRIS_OPEN_CMD;
  if (direction === "close") return IRIS_CLOSE_CMD;
  return null;
}

// Iris auto mode — aw_cam endpoint
export function irisAutoCmd(auto: boolean) {
  return { cmd: auto ? "ORS:1" : "ORS:0", endpoint: "aw_cam" };
}

// Iris auto on/off toggle (single command, camera flips internally)
export const IRIS_AUTO_TOGGLE_CMD = "#D3T";

// Gain — aw_cam endpoint, absolute value in hex
// 0x08 = 0dB, each step = 1dB, 0x80 = auto
export const GAIN_AUTO_HEX = 0x80;
export const GAIN_MIN_HEX  = 0x08;
export const GAIN_MAX_HEX  = 0x38; // 48dB
export function gainCmd(hexVal: number) {
  return { cmd: `OGU:${hexVal.toString(16).padStart(2, "0").toUpperCase()}`, endpoint: "aw_cam" };
}
export function gainToDb(hexVal: number): string {
  if (hexVal === GAIN_AUTO_HEX) return "AUTO";
  return `${hexVal - GAIN_MIN_HEX}dB`;
}

// Focus nudge — send speed then stop
export const FOCUS_FAR_CMD  = "#F70";
export const FOCUS_FAR_STOP = "#F50";
export const FOCUS_NEAR_CMD = "#F30";
export const FOCUS_NEAR_STOP = "#F50";

// Presets: recall #R00-#R99, save #M00-#M99
export function recallPresetCmd(index: number): string {
  return `#R${index.toString().padStart(2, "0")}`;
}

export function savePresetCmd(index: number): string {
  return `#M${index.toString().padStart(2, "0")}`;
}

// White balance modes
export type WBMode = "auto" | "3200k" | "5600k" | "manual";
const WB_CMDS: Record<WBMode, string> = {
  auto: "#AWB",
  "3200k": "#WB0",
  "5600k": "#WB1",
  manual: "#WBM",
};
export function wbCmd(mode: WBMode): string {
  return WB_CMDS[mode];
}
export const WB_MODES: WBMode[] = ["auto", "3200k", "5600k", "manual"];

// Stop all movement
export const STOP_CMD = "#PTS5050";
