// VirtualPtzController — parses AW-UE70 CGI commands and integrates a
// virtual PTZ camera pose (yaw / pitch / fov) over time.
//
// Uses the same 50±speed byte scheme that lib/ptz.ts emits, in reverse:
//   #PTSxxyy   xx = pan byte (50 = stop, 01–49 = left, 51–99 = right)
//              yy = tilt byte (50 = stop, 01–49 = down, 51–99 = up)
//              pan speed max = 30, tilt speed max = 30
//   #Zxx       zoom byte (50 = stop, 01–49 = wide, 51–99 = tele), max = 49
//   #Fxx       focus (no-op — we don't visually simulate focus)
//   #Rxx       recall preset xx (00–99)
//   #Mxx       save preset xx
// aw_cam commands (LIO / LIC / OSE / OGU …) are accepted and ignored —
// no visual iris/AF/gain to change in a virtual scene.

import type { PerspectiveCamera } from "three";

export interface VirtualPtzState {
  yaw: number;   // radians, positive = camera rotates right
  pitch: number; // radians, positive = camera rotates up (clamped)
  fov: number;   // degrees; Three.js PerspectiveCamera.fov
}

// Angular speed at full stick (radians per second).
// Tuned so a full-stick pan crosses the frame in ~2s at default FOV.
const PAN_MAX_RAD_PER_SEC  = 1.4;
const TILT_MAX_RAD_PER_SEC = 1.0;
// FOV changes per second at full stick (degrees). Negative = zoom in (tele).
const FOV_MAX_DEG_PER_SEC = 30;

const PAN_BYTE_MAX  = 30;
const TILT_BYTE_MAX = 30;
const ZOOM_BYTE_MAX = 49;

const FOV_MIN = 10;   // very tight zoom
const FOV_MAX = 75;   // wide
const PITCH_LIMIT = Math.PI / 2 - 0.05;

const DEFAULT_STATE: VirtualPtzState = { yaw: 0, pitch: 0, fov: 60 };

function clamp(v: number, min: number, max: number): number {
  return v < min ? min : v > max ? max : v;
}

// Inverse of lib/ptz.ts axisToSpeedByte(): byte → normalized [-1, 1].
// invert=true means byte 51+ maps to +1 (matches how the pan encoder handles
// axis-not-inverted). For tilt, invert=false: byte 51+ still maps to +1 in
// our output because we're going axis→byte→velocity and pitch-up is +.
function byteToNormalized(byte: number, maxSpeed: number): number {
  if (byte === 50) return 0;
  const offset = byte - 50;
  return clamp(offset / maxSpeed, -1, 1);
}

export class VirtualPtzController {
  readonly cameraId: string;
  private state: VirtualPtzState = { ...DEFAULT_STATE };
  private yawVel = 0;
  private pitchVel = 0;
  private fovVel = 0;
  private presets: Record<number, VirtualPtzState> = {};
  private saveTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(cameraId: string) {
    this.cameraId = cameraId;
    this.presets = this.loadPresets();
  }

  getState(): Readonly<VirtualPtzState> {
    return this.state;
  }

  // Parse and apply a single CGI command. Called from page.tsx sendCmd
  // interception when the active camera is virtual.
  execCommand(cmd: string, endpoint: "aw_ptz" | "aw_cam" = "aw_ptz"): void {
    if (endpoint === "aw_cam") return; // AF/iris/gain — silently accept

    // #PTSxxyy
    const pts = cmd.match(/^#PTS(\d{2})(\d{2})$/);
    if (pts) {
      const panByte  = parseInt(pts[1], 10);
      const tiltByte = parseInt(pts[2], 10);
      const panNorm  = byteToNormalized(panByte,  PAN_BYTE_MAX);
      const tiltNorm = byteToNormalized(tiltByte, TILT_BYTE_MAX);
      this.yawVel   = panNorm  * PAN_MAX_RAD_PER_SEC;
      this.pitchVel = tiltNorm * TILT_MAX_RAD_PER_SEC;
      return;
    }

    // #Zxx — zoom: positive byte = tele = FOV shrinks
    const z = cmd.match(/^#Z(\d{2})$/);
    if (z) {
      const zoomByte = parseInt(z[1], 10);
      const zoomNorm = byteToNormalized(zoomByte, ZOOM_BYTE_MAX);
      this.fovVel = -zoomNorm * FOV_MAX_DEG_PER_SEC;
      return;
    }

    // #Fxx — focus (no-op in virtual, but eat it so it's not treated as unknown)
    if (/^#F\d{2}$/.test(cmd)) return;

    // #Rxx — recall preset
    const r = cmd.match(/^#R(\d{2})$/);
    if (r) {
      const idx = parseInt(r[1], 10);
      const preset = this.presets[idx];
      if (preset) {
        this.state = { ...preset };
        this.yawVel = 0;
        this.pitchVel = 0;
        this.fovVel = 0;
      }
      return;
    }

    // #Mxx — save preset
    const m = cmd.match(/^#M(\d{2})$/);
    if (m) {
      const idx = parseInt(m[1], 10);
      this.presets[idx] = { ...this.state };
      this.schedulePresetSave();
      return;
    }

    // Unknown / other commands (e.g. #AWB, #WBx, #D3T) — safely ignore.
  }

  // Integrate velocity → pose. Called every rAF frame with dt in ms.
  tick(dtMs: number): void {
    const dt = dtMs / 1000;
    this.state.yaw   += this.yawVel   * dt;
    this.state.pitch += this.pitchVel * dt;
    this.state.fov    = clamp(this.state.fov + this.fovVel * dt, FOV_MIN, FOV_MAX);
    this.state.pitch  = clamp(this.state.pitch, -PITCH_LIMIT, PITCH_LIMIT);
    // Wrap yaw to keep the number bounded over long sessions
    if (this.state.yaw >  Math.PI * 2) this.state.yaw -= Math.PI * 2;
    if (this.state.yaw < -Math.PI * 2) this.state.yaw += Math.PI * 2;
  }

  // Apply current pose to a Three.js perspective camera.
  apply(camera: PerspectiveCamera): void {
    // rotation.order defaults to "XYZ" — set yaw on Y, pitch on X. No roll.
    camera.rotation.order = "YXZ";
    // State yaw is "positive = pan right", but a positive Three.js rotation.y
    // turns the camera's forward vector toward -X (screen-left), so negate.
    camera.rotation.y = -this.state.yaw;
    camera.rotation.x = this.state.pitch;
    if (camera.fov !== this.state.fov) {
      camera.fov = this.state.fov;
      camera.updateProjectionMatrix();
    }
  }

  // Called on unmount / camera swap — persist any dirty preset save immediately.
  flush(): void {
    if (this.saveTimer !== null) {
      clearTimeout(this.saveTimer);
      this.saveTimer = null;
      this.persistPresets();
    }
  }

  // ── Preset persistence (localStorage) ──────────────────────────────────

  private presetKey(): string {
    return `virtual-presets-${this.cameraId}`;
  }

  private loadPresets(): Record<number, VirtualPtzState> {
    if (typeof window === "undefined") return {};
    try {
      const raw = localStorage.getItem(this.presetKey());
      if (!raw) return {};
      const parsed = JSON.parse(raw) as Record<string, VirtualPtzState>;
      const out: Record<number, VirtualPtzState> = {};
      for (const [k, v] of Object.entries(parsed)) {
        const n = parseInt(k, 10);
        if (Number.isFinite(n) && v && typeof v.yaw === "number" && typeof v.pitch === "number" && typeof v.fov === "number") {
          out[n] = v;
        }
      }
      return out;
    } catch {
      return {};
    }
  }

  private schedulePresetSave(): void {
    if (this.saveTimer !== null) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null;
      this.persistPresets();
    }, 100);
  }

  private persistPresets(): void {
    if (typeof window === "undefined") return;
    try {
      localStorage.setItem(this.presetKey(), JSON.stringify(this.presets));
    } catch {
      // Full storage or unavailable — nothing to do.
    }
  }
}
