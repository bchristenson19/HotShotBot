"use client";
import { useState, useEffect, useRef, useCallback } from "react";
import { useGamepad, findGamepad, type GamepadState } from "@/hooks/useGamepad";
import { useElectronLightBar } from "@/hooks/useElectronLightBar";
import CameraConfig from "@/components/CameraConfig";
import RemapModal from "@/components/RemapModal";
import ProfilesModal from "@/components/ProfilesModal";
import PresetManager from "@/components/PresetManager";
import ControllerVisualizer from "@/components/ControllerVisualizer";
import CameraFeed from "@/components/CameraFeed";
import FrameCapture from "@/components/FrameCapture";
import { useMultiCameraTracking } from "@/hooks/useMultiCameraTracking";
import { useCameraStatus } from "@/hooks/useCameraStatus";
import { useVirtualPtz } from "@/hooks/useVirtualPtz";
import type { Camera } from "@/lib/ptz";
import { isVirtual } from "@/lib/ptz";
import type { ControlMapping } from "@/lib/mapping";
import {
  axisToPanTiltCmd, axisToZoomCmd, axisToFocusCmd,
  autoFocusCmd, ONE_TOUCH_FOCUS_CMD, ONE_TOUCH_FOCUS_OFF,
  irisAutoCmd, IRIS_OPEN_CMD, IRIS_CLOSE_CMD, IRIS_COMMIT_CMD,
  gainCmd, gainToDb, GAIN_AUTO_HEX, GAIN_MIN_HEX, GAIN_MAX_HEX,
  FOCUS_NEAR_CMD, FOCUS_NEAR_STOP, FOCUS_FAR_CMD, FOCUS_FAR_STOP,
  recallPresetCmd, savePresetCmd, wbCmd, WB_MODES,
} from "@/lib/ptz";
import { DEFAULT_MAPPING, loadMapping, saveMapping } from "@/lib/mapping";

const DPAD_SPEED = 0.4;
const IRIS_TRIGGER_THRESHOLD = 0.15;
const CMD_INTERVAL_MS = 66;

const DEFAULT_CAMERAS: Camera[] = [{ id: "1", name: "Camera 1", ip: "", port: 80, model: "aw-ue70" }];

function loadCameras(): Camera[] {
  if (typeof window === "undefined") return DEFAULT_CAMERAS;
  try {
    const raw = localStorage.getItem("ptz-cameras");
    if (raw) {
      const parsed: Camera[] = JSON.parse(raw);
      // Backfill model for cameras saved before model field was added
      return parsed.map((c) => ({ ...c, model: c.model ?? "aw-ue70" }));
    }
  } catch {}
  return DEFAULT_CAMERAS;
}

export default function Home() {
  const [cameras, setCameras] = useState<Camera[]>(DEFAULT_CAMERAS);
  const [activeCamIndex, setActiveCamIndex] = useState(0);
  const [mapping, setMapping] = useState<ControlMapping>(DEFAULT_MAPPING);
  const [showConfig, setShowConfig] = useState(false);
  const [showRemap, setShowRemap] = useState(false);
  const [autoFocus, setAutoFocus] = useState(true);
  const [autoIris, setAutoIris] = useState(true);
  const [wbIndex, setWbIndex] = useState(0);
  const [lastCmd, setLastCmd] = useState("");
  const [lastResponse, setLastResponse] = useState("");
  const [connected, setConnected] = useState(false);
  const [savingPreset, setSavingPreset] = useState(false);
  const [oneTouchActive, setOneTouchActive] = useState(false);
  const [showControlsOverlay, setShowControlsOverlay] = useState(false);
  // Per-camera tracking config
  const [cameraTracking, setCameraTracking] = useState<Record<string, { enabled: boolean; shotPreset: import("@/hooks/useTracking").ShotPreset; speed: number; deadZone: number }>>({});
  const trackingEnabledRef = useRef(false);
  const [showProfiles, setShowProfiles] = useState(false);
  const [showPresets, setShowPresets] = useState(false);
  const [isHud, setIsHud] = useState(false);
  const [isElectron, setIsElectron] = useState(false);

  useEffect(() => {
    // Detect Electron and sync HUD state — runs client-only, avoids hydration mismatch
    const api = window.electronAPI;
    if (!api) return;
    setIsElectron(true);
    api.isHud().then(setIsHud);
    api.onHudMode(setIsHud);
  }, []);
  const [activeProfileName, setActiveProfileName] = useState<string | null>(null);
  const [gainHex, setGainHex] = useState(GAIN_AUTO_HEX);
  const gainHexRef = useRef(GAIN_AUTO_HEX);
  const [throttleDisplay, setThrottleDisplay] = useState({ pan: 0, tilt: 0 });
  // macro toggle states [on/off per macro slot]
  const [macroStates, setMacroStates] = useState<[boolean, boolean, boolean, boolean]>([false, false, false, false]);
  // live gamepad state for visualizer
  const [padState, setPadState] = useState<GamepadState>({
    leftX: 0, leftY: 0, rightX: 0, rightY: 0,
    cross: false, circle: false, square: false, triangle: false,
    l1: false, r1: false, l2: 0, r2: 0, l3: false, r3: false,
    dpadUp: false, dpadDown: false, dpadLeft: false, dpadRight: false,
    options: false, touchpad: false, connected: false,
  });

  const prevButtons = useRef<Partial<GamepadState>>({});
  const inFlight = useRef<Record<string, boolean>>({});
  const lastSent = useRef<Record<string, number>>({});
  const velocity = useRef({ pan: 0, tilt: 0 });
  const zoomVelocity = useRef(0);
  const lastFrameTime = useRef<number>(performance.now());
  // Refs so onFrame never needs autoFocus/autoIris in its deps
  const autoFocusRef = useRef(autoFocus);
  const autoIrisRef = useRef(autoIris);
  useEffect(() => { autoFocusRef.current = autoFocus; }, [autoFocus]);
  useEffect(() => { autoIrisRef.current = autoIris; }, [autoIris]);
  // Prevent one-touch pulse from re-firing if the timer is already running
  const oneTouchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    setCameras(loadCameras());
    setMapping(loadMapping());
  }, []);

  const activeCam = cameras[activeCamIndex] ?? cameras[0];
  useElectronLightBar(activeCam?.color);

  const multiTracking = useMultiCameraTracking();
  const virtualPtz = useVirtualPtz();

  // Helper: get config for a camera (with defaults)
  function getCamTracking(camId: string) {
    return cameraTracking[camId] ?? { enabled: false, shotPreset: "none" as const, speed: 0.5, deadZone: 0.04 };
  }

  const activeCamTracking = activeCam ? getCamTracking(activeCam.id) : { enabled: false, shotPreset: "none" as const, speed: 1.0, deadZone: 0.03 };
  trackingEnabledRef.current = activeCamTracking.enabled;

  function toggleTracking(cam: typeof activeCam) {
    if (!cam) return;
    const current = getCamTracking(cam.id);
    if (!current.enabled) {
      // Enable — spawn worker for this camera
      multiTracking.enableTracking(cam.id, {
        sendPT: (pan, tilt) => sendCmd(axisToPanTiltCmd(pan, tilt), `pt-track-${cam.id}`),
        sendZoom: (zoom) => sendContinuous(axisToZoomCmd(zoom), `zoom-track-${cam.id}`),
      });
      setCameraTracking((prev) => ({ ...prev, [cam.id]: { ...current, enabled: true } }));
    } else {
      multiTracking.disableTracking(cam.id);
      setCameraTracking((prev) => ({ ...prev, [cam.id]: { ...current, enabled: false } }));
    }
  }

  const { status: cameraStatus, error: cameraStatusError } = useCameraStatus(activeCam?.ip ? activeCam : null);
  // Only sync focus/iris mode on first successful poll — after that the controller is authoritative
  const hasSyncedRef = useRef(false);
  useEffect(() => { hasSyncedRef.current = false; }, [activeCamIndex]);
  useEffect(() => {
    if (!cameraStatus || hasSyncedRef.current) return;
    hasSyncedRef.current = true;
    setAutoFocus(cameraStatus.autoFocus);
    autoFocusRef.current = cameraStatus.autoFocus;
    setAutoIris(cameraStatus.autoIris);
    autoIrisRef.current = cameraStatus.autoIris;
  }, [cameraStatus]);

  const sendCmd = useCallback(
    async (cmd: string | { cmd: string; endpoint: string }, channel = "default") => {
      if (!activeCam) return;
      const cmdStr = typeof cmd === "string" ? cmd : cmd.cmd;
      const endpoint: "aw_ptz" | "aw_cam" = typeof cmd === "string" ? "aw_ptz" : (cmd.endpoint as "aw_ptz" | "aw_cam");

      // Virtual camera — route to the in-app 3D controller, skip HTTP entirely.
      if (isVirtual(activeCam)) {
        virtualPtz.execCommand(activeCam.id, cmdStr, endpoint);
        setLastCmd(cmdStr);
        setLastResponse("ok (virtual)");
        return;
      }

      if (!activeCam.ip) return;
      if (inFlight.current[channel]) return;
      inFlight.current[channel] = true;
      setLastCmd(cmdStr);
      try {
        const res = await fetch("/api/camera", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ip: activeCam.ip, port: activeCam.port, cmd: cmdStr, endpoint }),
        });
        const data = await res.json();
        setLastResponse(data.response ?? data.error ?? "");
      } catch {
        setLastResponse("Network error");
      } finally {
        inFlight.current[channel] = false;
      }
    },
    [activeCam, virtualPtz]
  );

  const sendContinuous = useCallback(
    (cmd: string | { cmd: string; endpoint: string }, channel: string) => {
      const now = Date.now();
      if ((now - (lastSent.current[channel] ?? 0)) < CMD_INTERVAL_MS) return;
      lastSent.current[channel] = now;
      sendCmd(cmd, channel);
    },
    [sendCmd]
  );

  function rumble(strong: number, weak: number, duration: number) {
    const gp = findGamepad();
    gp?.vibrationActuator?.playEffect("dual-rumble", {
      startDelay: 0, duration, weakMagnitude: weak, strongMagnitude: strong,
    });
  }

  const mappingRef = useRef(mapping);
  mappingRef.current = mapping;

  const onFrame = useCallback(
    (state: GamepadState) => {
      const prev = prevButtons.current;
      setConnected(state.connected);
      setPadState(state);

      if (!state.connected) return;

      const m = mappingRef.current;
      const pressed = (key: keyof GamepadState) => state[key] && !prev[key];

      // Helper: what action is assigned to this button?
      const btnAction = (key: keyof typeof m.buttons) => m.buttons[key];

      // Process a pressed button through its assigned action
      function handleButtonPress(key: keyof typeof m.buttons) {
        if (!pressed(key as keyof GamepadState)) return;
        const action = btnAction(key);
        const isSaveHeld = state[m.buttons.l1 === "saveModifier" ? "l1" : "r1"] ||
          Object.entries(m.buttons).some(([k, v]) => v === "saveModifier" && state[k as keyof GamepadState]);

        switch (action) {
          case "cycleCamera":
            setActiveCamIndex((i) => (i + 1) % cameras.length);
            break;
          case "cycleWB":
            setWbIndex((i) => {
              const next = (i + 1) % WB_MODES.length;
              sendCmd(wbCmd(WB_MODES[next]));
              return next;
            });
            break;
          case "toggleAutoFocus":
            setAutoFocus((af) => { sendCmd(autoFocusCmd(!af)); return !af; });
            break;
          case "oneTouchFocus":
            if (m.oneTouchFocusMode === "pulse") {
              if (oneTouchTimer.current) break; // already running, ignore re-press
              // Cancel any pending state that could interfere
              sendCmd(ONE_TOUCH_FOCUS_CMD);
              setAutoFocus(true);
              setOneTouchActive(true);
              autoFocusRef.current = true;
              rumble(0.5, 0.3, 80);
              oneTouchTimer.current = setTimeout(() => {
                oneTouchTimer.current = null;
                sendCmd(ONE_TOUCH_FOCUS_OFF);
                setAutoFocus(false);
                setOneTouchActive(false);
                autoFocusRef.current = false;
                rumble(0.3, 0.2, 60);
              }, 2000);
            } else {
              // hold mode — only turn on here, release handler turns it off
              if (autoFocusRef.current) break; // already on
              sendCmd(ONE_TOUCH_FOCUS_CMD);
              setAutoFocus(true);
              setOneTouchActive(true);
              autoFocusRef.current = true;
              rumble(0.5, 0.3, 80);
            }
            break;
          case "irisOpenBtn":
          case "irisCloseBtn":
            // Switch to manual on first press; continuous loop handles the nudges
            if (autoIrisRef.current) {
              sendCmd(irisAutoCmd(false));
              setAutoIris(false);
              autoIrisRef.current = false;
            }
            break;
          case "irisAutoToggle":
            sendCmd(irisAutoCmd(!autoIrisRef.current));
            setAutoIris(!autoIrisRef.current);
            autoIrisRef.current = !autoIrisRef.current;
            break;
          case "gainUp": {
            const next = gainHexRef.current === GAIN_AUTO_HEX
              ? GAIN_MIN_HEX
              : Math.min(GAIN_MAX_HEX, gainHexRef.current + 1);
            gainHexRef.current = next;
            setGainHex(next);
            sendCmd(gainCmd(next));
            break;
          }
          case "gainDown": {
            const next = gainHexRef.current === GAIN_AUTO_HEX
              ? GAIN_MAX_HEX
              : Math.max(GAIN_MIN_HEX, gainHexRef.current - 1);
            gainHexRef.current = next;
            setGainHex(next);
            sendCmd(gainCmd(next));
            break;
          }
          case "focusNear":
            sendCmd(FOCUS_NEAR_CMD);
            setTimeout(() => sendCmd(FOCUS_NEAR_STOP), 120);
            break;
          case "focusFar":
            sendCmd(FOCUS_FAR_CMD);
            setTimeout(() => sendCmd(FOCUS_FAR_STOP), 120);
            break;
          case "recallPreset1": {
            const idx = m.presetBindings[0];
            isSaveHeld ? (sendCmd(savePresetCmd(idx)), setSavingPreset(true), setTimeout(() => setSavingPreset(false), 600)) : sendCmd(recallPresetCmd(idx));
            break;
          }
          case "recallPreset2": {
            const idx = m.presetBindings[1];
            isSaveHeld ? (sendCmd(savePresetCmd(idx)), setSavingPreset(true), setTimeout(() => setSavingPreset(false), 600)) : sendCmd(recallPresetCmd(idx));
            break;
          }
          case "recallPreset3": {
            const idx = m.presetBindings[2];
            isSaveHeld ? (sendCmd(savePresetCmd(idx)), setSavingPreset(true), setTimeout(() => setSavingPreset(false), 600)) : sendCmd(recallPresetCmd(idx));
            break;
          }
          case "recallPreset4": {
            const idx = m.presetBindings[3];
            isSaveHeld ? (sendCmd(savePresetCmd(idx)), setSavingPreset(true), setTimeout(() => setSavingPreset(false), 600)) : sendCmd(recallPresetCmd(idx));
            break;
          }
          case "macro1": fireMacro(0); break;
          case "macro2": fireMacro(1); break;
          case "macro3": fireMacro(2); break;
          case "macro4": fireMacro(3); break;
        }
      }

      function fireMacro(i: number) {
        const macro = m.macros[i];
        if (!macro.cmd) return;
        if (macro.toggle) {
          setMacroStates((ms) => {
            const next = [...ms] as typeof ms;
            next[i] = !next[i];
            sendCmd(next[i] ? macro.cmd : macro.offCmd);
            return next;
          });
        } else {
          sendCmd(macro.cmd);
        }
      }

      // Process all buttons
      const allButtons: Array<keyof typeof m.buttons> = [
        "cross", "circle", "square", "triangle",
        "l1", "r1", "l3", "r3",
        "dpadUp", "dpadDown", "dpadLeft", "dpadRight",
        "options", "touchpad",
      ];
      for (const btn of allButtons) handleButtonPress(btn);

      // Hold-mode release: if button mapped to oneTouchFocus is released, turn AF off
      if (m.oneTouchFocusMode === "hold") {
        const released = (key: keyof GamepadState) => !state[key] && prev[key as keyof typeof prev];
        const afBtn = (Object.entries(m.buttons) as [keyof typeof m.buttons, string][])
          .find(([, v]) => v === "oneTouchFocus")?.[0];
        if (afBtn && released(afBtn as keyof GamepadState)) {
          sendCmd(ONE_TOUCH_FOCUS_OFF);
          setAutoFocus(false);
          setOneTouchActive(false);
          autoFocusRef.current = false;
          rumble(0.3, 0.2, 60);
        }
      }

      // Continuous: pan/tilt
      let panTarget: number;
      let tiltTarget: number;

      if (m.ptMode === "dual") {
        panTarget = state.leftX * m.ptSensitivity + state.rightX * m.ptFineScale;
        tiltTarget = state.leftY * m.ptSensitivity + state.rightY * m.ptFineScale;
        panTarget = Math.max(-1, Math.min(1, panTarget));
        tiltTarget = Math.max(-1, Math.min(1, tiltTarget));
        // Show combined magnitude as throttle display
        const pct = { pan: Math.round(panTarget * 100), tilt: Math.round(tiltTarget * 100) };
        setThrottleDisplay(pct);
      } else {
        panTarget = (state[m.panTiltAxis.x] as number) * m.ptSensitivity;
        tiltTarget = (state[m.panTiltAxis.y] as number) * m.ptSensitivity;
      }

      // D-pad overrides
      if (m.buttons.dpadLeft === "finePanTilt" && state.dpadLeft) panTarget = -DPAD_SPEED;
      if (m.buttons.dpadRight === "finePanTilt" && state.dpadRight) panTarget = DPAD_SPEED;
      if (m.buttons.dpadUp === "finePanTilt" && state.dpadUp) tiltTarget = -DPAD_SPEED;
      if (m.buttons.dpadDown === "finePanTilt" && state.dpadDown) tiltTarget = DPAD_SPEED;

      // Tilt invert — applied uniformly across single/dual/d-pad inputs
      if (m.tiltInverted) tiltTarget = -tiltTarget;

      // Speed modifier button — slow down or speed up while held
      const modifierBtn = (Object.entries(m.buttons) as [keyof typeof m.buttons, string][])
        .find(([, v]) => v === "ptSpeedModifier")?.[0];
      const modifierHeld = !!(modifierBtn && state[modifierBtn as keyof GamepadState]);
      if (modifierHeld) {
        panTarget *= m.ptSpeedModifierValue;
        tiltTarget *= m.ptSpeedModifierValue;
      }

      // R2 brake — disabled when triggers are used for zoom
      if (m.ptBrakeAxis && m.zoomMode !== "triggers") {
        const brake = state[m.ptBrakeAxis] as number;
        if (brake > 0.01) {
          const multiplier = 1 - brake * (1 - m.ptBrakeMinSpeed);
          panTarget *= multiplier;
          tiltTarget *= multiplier;
        }
      }

      // Momentum: lerp velocity toward stick target, decay toward 0 when stick centered
      const now = performance.now();
      const dt = Math.min(now - lastFrameTime.current, 100); // cap at 100ms
      lastFrameTime.current = now;

      let panVel = velocity.current.pan;
      let tiltVel = velocity.current.tilt;

      if (m.momentumEnabled) {
        const stickDeadzone = 0.05;
        const panMoving = Math.abs(panTarget) > stickDeadzone;
        const tiltMoving = Math.abs(tiltTarget) > stickDeadzone;

        // Accel toward target; decay factor based on glideMs (half-life formula)
        const glide = m.momentumGlideMs > 0 ? m.momentumGlideMs : DEFAULT_MAPPING.momentumGlideMs;
        const decayPerMs = Math.log(2) / glide;
        const decayFactor = Math.exp(-decayPerMs * dt);

        panVel = panMoving
          ? panVel + (panTarget - panVel) * m.momentumAccel
          : panVel * decayFactor;
        tiltVel = tiltMoving
          ? tiltVel + (tiltTarget - tiltVel) * m.momentumAccel
          : tiltVel * decayFactor;

        // Snap to zero below noise floor
        if (Math.abs(panVel) < 0.01) panVel = 0;
        if (Math.abs(tiltVel) < 0.01) tiltVel = 0;

        velocity.current = { pan: panVel, tilt: tiltVel };
      } else {
        panVel = panTarget;
        tiltVel = tiltTarget;
        velocity.current = { pan: 0, tilt: 0 };
      }

      // Suppress gamepad PT when tracking is active — tracking drives the camera
      if (!trackingEnabledRef.current) {
        sendContinuous(axisToPanTiltCmd(panVel, tiltVel), "pt");
      }

      // Zoom — right stick is taken by PT in dual mode; only triggers work then
      let rawZoom = 0;
      if (m.ptMode === "dual" && m.zoomMode !== "triggers") {
        rawZoom = 0;
      } else if (m.zoomMode === "triggers") {
        rawZoom = (state.l2 - state.r2) * (m.zoomInverted ? -1 : 1);
      } else {
        rawZoom = (state[m.zoomAxis] as number) * (m.zoomInverted ? -1 : 1);
      }

      // Apply sensitivity + optional speed modifier
      const zoomModifier = (modifierHeld && m.ptSpeedModifierAffectsZoom) ? m.ptSpeedModifierValue : 1;
      const zoomTarget = Math.max(-1, Math.min(1, rawZoom * m.zoomSensitivity * zoomModifier));

      // Zoom momentum
      let finalZoom: number;
      if (m.zoomMomentumEnabled) {
        const zoomDeadzone = 0.05;
        const zoomMoving = Math.abs(zoomTarget) > zoomDeadzone;
        const glide = m.zoomMomentumGlideMs > 0 ? m.zoomMomentumGlideMs : 400;
        const decayFactor = Math.exp(-(Math.log(2) / glide) * dt);
        zoomVelocity.current = zoomMoving
          ? zoomVelocity.current + (zoomTarget - zoomVelocity.current) * m.momentumAccel
          : zoomVelocity.current * decayFactor;
        if (Math.abs(zoomVelocity.current) < 0.01) zoomVelocity.current = 0;
        finalZoom = zoomVelocity.current;
      } else {
        zoomVelocity.current = 0;
        finalZoom = zoomTarget;
      }
      sendContinuous(axisToZoomCmd(finalZoom), "zoom");

      // Focus — right stick unavailable in dual PT mode
      if (!autoFocusRef.current && m.ptMode !== "dual") {
        sendContinuous(axisToFocusCmd(state[m.focusAxis] as number), "focus");
      }

      // Iris — skip if auto iris on, or triggers claimed by zoom/brake
      if (!autoIrisRef.current) {
        // Trigger-based
        const irisOpen = state[m.irisOpenAxis] as number;
        const irisClose = state[m.irisCloseAxis] as number;
        const r2Claimed = m.ptBrakeAxis === "r2" || m.zoomMode === "triggers";
        const l2Claimed = m.ptBrakeAxis === "l2" || m.zoomMode === "triggers";

        // Button-based (hold = continuous nudge)
        const irisOpenBtn = (Object.entries(m.buttons) as [keyof typeof m.buttons, string][])
          .find(([, v]) => v === "irisOpenBtn")?.[0];
        const irisCloseBtn = (Object.entries(m.buttons) as [keyof typeof m.buttons, string][])
          .find(([, v]) => v === "irisCloseBtn")?.[0];
        const btnOpenHeld = irisOpenBtn ? !!state[irisOpenBtn as keyof GamepadState] : false;
        const btnCloseHeld = irisCloseBtn ? !!state[irisCloseBtn as keyof GamepadState] : false;

        if ((!l2Claimed && irisClose > IRIS_TRIGGER_THRESHOLD) || btnCloseHeld) {
          sendContinuous(IRIS_CLOSE_CMD, "iris");
          sendContinuous(IRIS_COMMIT_CMD, "iris-commit");
        } else if ((!r2Claimed && irisOpen > IRIS_TRIGGER_THRESHOLD) || btnOpenHeld) {
          sendContinuous(IRIS_OPEN_CMD, "iris");
          sendContinuous(IRIS_COMMIT_CMD, "iris-commit");
        }
      }

      prevButtons.current = { ...state };
    },
    [cameras.length, sendCmd, sendContinuous]
  );

  const { waitingForPress } = useGamepad(onFrame);

  function handleCamerasChange(updated: Camera[]) {
    setCameras(updated);
    localStorage.setItem("ptz-cameras", JSON.stringify(updated));
    setActiveCamIndex(0);
  }

  function handleMappingChange(m: ControlMapping) {
    setMapping(m);
    saveMapping(m);
    setActiveProfileName(null); // unsaved changes
  }

  // Compact HUD — shown when Electron window is in always-on-top mini mode
  if (isHud) {
    return (
      <main className="h-screen bg-zinc-950/95 text-white flex flex-col overflow-hidden select-none">
        <div className="flex items-center justify-between px-3 py-2 border-b border-zinc-800">
          <div className="flex items-center gap-2">
            <div className="w-1.5 h-1.5 rounded-full" style={{ background: activeCam?.color ?? "#1d4ed8" }} />
            <span className="text-xs font-semibold">{activeCam?.name ?? "—"}</span>
            {activeProfileName && <span className="text-[10px] text-blue-400">{activeProfileName}</span>}
          </div>
          <div className="flex items-center gap-2">
            <span className={`w-1.5 h-1.5 rounded-full ${connected ? "bg-green-400" : "bg-zinc-600"}`} />
            <button onClick={() => window.electronAPI?.toggleHud()} className="text-zinc-500 hover:text-white text-xs">Expand</button>
          </div>
        </div>
        <div className="flex-1 flex items-center justify-center gap-6 px-4">
          <div className="text-center">
            <div className="text-zinc-500 text-[9px] uppercase tracking-widest">Iris</div>
            <div className="text-white text-sm font-mono">{cameraStatus?.iris ?? "—"}</div>
          </div>
          <div className="text-center">
            <div className="text-zinc-500 text-[9px] uppercase tracking-widest">Focus</div>
            <div className="text-white text-sm font-mono">{autoFocus ? "AF" : "MF"}</div>
          </div>
          <div className="text-center">
            <div className="text-zinc-500 text-[9px] uppercase tracking-widest">Gain</div>
            <div className="text-white text-sm font-mono">{gainToDb(gainHex)}</div>
          </div>
          <div className="text-center">
            <div className="text-zinc-500 text-[9px] uppercase tracking-widest">Zoom</div>
            <div className="text-white text-sm font-mono">{cameraStatus?.zoom ?? 0}%</div>
          </div>
        </div>
        {/* Mini camera switcher */}
        <div className="flex border-t border-zinc-800">
          {cameras.map((cam, i) => (
            <button key={cam.id} onClick={() => setActiveCamIndex(i)}
              className={`flex-1 py-1.5 text-[10px] transition-colors ${i === activeCamIndex ? "text-white font-semibold" : "text-zinc-500 hover:text-zinc-300"}`}
              style={i === activeCamIndex ? { borderBottom: `2px solid ${cam.color ?? "#1d4ed8"}` } : {}}
            >
              {cam.name}
            </button>
          ))}
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white flex flex-col">
      <header className="flex items-center justify-between px-6 py-4 border-b border-zinc-800">
        <div className="flex items-center gap-3">
          <div className="w-2 h-2 rounded-full bg-red-500 animate-pulse" />
          <h1 className="text-lg font-bold tracking-wide">HotShotBot</h1>
          {activeProfileName && (
            <span className="text-xs text-blue-400 bg-blue-600/15 border border-blue-500/30 px-2 py-0.5 rounded-full">
              {activeProfileName}
            </span>
          )}
        </div>
        <div className="flex gap-2">
          {isElectron && (
            <button
              onClick={() => window.electronAPI?.toggleHud()}
              title="Toggle HUD mode (⌘⇧H)"
              className={`px-3 py-1.5 rounded-lg text-sm transition-colors ${isHud ? "bg-blue-600 text-white" : "bg-zinc-800 hover:bg-zinc-700 text-white"}`}
            >
              {isHud ? "⊠ HUD" : "⊡ HUD"}
            </button>
          )}
          <button
            onClick={() => toggleTracking(activeCam)}
            className={`px-4 py-1.5 rounded-lg text-sm transition-colors ${activeCamTracking.enabled ? "bg-green-600 text-white" : "bg-zinc-800 hover:bg-zinc-700 text-white"}`}
            title="Click-to-track mode"
          >
            Track <span className="opacity-60 text-xs">(β)</span>
          </button>
          {activeCamTracking.enabled && (
            <>
              <div className="flex rounded-lg overflow-hidden border border-zinc-600 text-xs">
                {(["none", "mid", "full"] as const).map((p) => (
                  <button
                    key={p}
                    onClick={() => activeCam && setCameraTracking((prev) => ({ ...prev, [activeCam.id]: { ...getCamTracking(activeCam.id), shotPreset: p } }))}
                    className={`px-3 py-1.5 capitalize transition-colors ${
                      activeCamTracking.shotPreset === p ? "bg-green-600 text-white" : "bg-zinc-700 text-zinc-400 hover:text-white"
                    }`}
                  >
                    {p === "none" ? "Free" : p === "mid" ? "Mid" : "Full"}
                  </button>
                ))}
              </div>
              <div className="flex items-center gap-2">
                <span className="text-zinc-500 text-xs whitespace-nowrap">Dead zone</span>
                <input
                  type="range" min="1" max="10" step="1"
                  value={Math.round((activeCamTracking.deadZone ?? 0.03) * 100)}
                  onChange={(e) => activeCam && setCameraTracking((prev) => ({
                    ...prev,
                    [activeCam.id]: { ...getCamTracking(activeCam.id), deadZone: parseInt(e.target.value) / 100 }
                  }))}
                  className="w-20 accent-green-500"
                />
                <span className="text-zinc-400 text-xs font-mono w-6">{Math.round((activeCamTracking.deadZone ?? 0.03) * 100)}%</span>
              </div>
            </>
          )}
          <button
            onClick={() => setShowControlsOverlay((v) => !v)}
            className={`px-4 py-1.5 rounded-lg text-sm transition-colors ${showControlsOverlay ? "bg-blue-600 text-white" : "bg-zinc-800 hover:bg-zinc-700 text-white"}`}
          >
            Controls
          </button>
          <button
            onClick={() => setShowPresets(true)}
            className="bg-zinc-800 hover:bg-zinc-700 px-4 py-1.5 rounded-lg text-sm transition-colors"
          >
            Presets
          </button>
          <button
            onClick={() => setShowProfiles(true)}
            className="bg-zinc-800 hover:bg-zinc-700 px-4 py-1.5 rounded-lg text-sm transition-colors"
          >
            Profiles
          </button>
          <button
            onClick={() => setShowRemap(true)}
            className="bg-zinc-800 hover:bg-zinc-700 px-4 py-1.5 rounded-lg text-sm transition-colors"
          >
            Remap
          </button>
          <button
            onClick={() => setShowConfig(true)}
            className="bg-zinc-800 hover:bg-zinc-700 px-4 py-1.5 rounded-lg text-sm transition-colors"
          >
            Cameras
          </button>
        </div>
      </header>

      <div className="flex flex-1 gap-0 overflow-hidden">
        {/* Camera sidebar */}
        <aside className="w-48 border-r border-zinc-800 p-3 space-y-2 shrink-0">
          <p className="text-zinc-500 text-xs uppercase tracking-widest px-1 pb-1">Cameras</p>
          {cameras.map((cam, i) => (
            <button
              key={cam.id}
              onClick={() => setActiveCamIndex(i)}
              className={`w-full text-left px-3 py-2 rounded-lg text-sm transition-colors ${
                i === activeCamIndex
                  ? "bg-blue-600 text-white font-semibold"
                  : "bg-zinc-800 hover:bg-zinc-700 text-zinc-300"
              }`}
            >
              <div>{cam.name}</div>
              <div className="text-xs mt-0.5 opacity-60 truncate">{cam.ip || "No IP"}</div>
            </button>
          ))}
        </aside>

        {/* Main */}
        <div className="flex-1 p-6 flex flex-col gap-5 overflow-y-auto">
          {/* Camera header + connection status */}
          <div className="flex items-start justify-between">
            <div>
              <h2 className="text-2xl font-bold">{activeCam?.name ?? "—"}</h2>
              <p className="text-zinc-400 text-sm mt-0.5">{activeCam?.ip || "No IP configured"}</p>
            </div>
            <div className="flex items-center gap-2">
              <span className={`w-2.5 h-2.5 rounded-full ${
                connected ? "bg-green-400" : waitingForPress ? "bg-yellow-400 animate-pulse" : "bg-zinc-600"
              }`} />
              <span className="text-sm text-zinc-400">
                {connected ? "Controller connected" : waitingForPress ? "Press any button on controller" : "No controller"}
              </span>
            </div>
          </div>

          {/* Status pills */}
          <div className="flex flex-wrap gap-2">
            <Pill label="PT" value={mapping.ptMode === "dual" ? "DUAL" : "SINGLE"} active={mapping.ptMode === "dual"} />
            {mapping.ptMode === "dual" && (throttleDisplay.pan !== 0 || throttleDisplay.tilt !== 0) && (
              <Pill label="VEL" value={`P${throttleDisplay.pan > 0 ? "+" : ""}${throttleDisplay.pan} T${throttleDisplay.tilt > 0 ? "+" : ""}${throttleDisplay.tilt}`} active />
            )}
            <Pill label="ZOOM" value={mapping.zoomMode === "triggers" ? "TRIGGERS" : "STICK"} active={mapping.zoomMode === "triggers"} />
            <Pill label="Focus" value={autoFocus ? "AUTO" : "MANUAL"} active={!autoFocus} />
            {oneTouchActive && <Pill label="1-TAP AF" value={mapping.oneTouchFocusMode === "pulse" ? "FOCUSING…" : "HELD"} active />}
            <Pill label="AF MODE" value={mapping.oneTouchFocusMode.toUpperCase()} />
            <Pill label="Iris" value={autoIris ? "AUTO" : "MANUAL"} active={!autoIris} />
            <Pill label="Gain" value={gainToDb(gainHex)} />
            <Pill label="WB" value={WB_MODES[wbIndex].toUpperCase()} />
            {mapping.ptBrakeAxis && mapping.zoomMode !== "triggers" && padState[mapping.ptBrakeAxis] as number > 0.05 && (
              <Pill
                label="BRAKE"
                value={`${Math.round((1 - (padState[mapping.ptBrakeAxis] as number) * (1 - mapping.ptBrakeMinSpeed)) * 100)}%`}
                active
              />
            )}
            {savingPreset && <Pill label="PRESET" value="SAVING…" active />}
            {mapping.macros.map((macro, i) =>
              macro.cmd && macro.toggle ? (
                <Pill
                  key={i}
                  label={macro.label || `Macro ${i + 1}`}
                  value={macroStates[i] ? "ON" : "OFF"}
                  active={macroStates[i]}
                />
              ) : null
            )}
          </div>

          {/* Live feed */}
          <CameraFeed
            camera={activeCam}
            autoFocus={autoFocus}
            gain={gainToDb(gainHex)}
            status={cameraStatus ?? null}
            statusError={cameraStatusError}
            showControls={showControlsOverlay}
            padState={padState}
            mapping={mapping}
            profileName={activeProfileName}
            virtualController={activeCam && isVirtual(activeCam) ? virtualPtz.getController(activeCam.id) : null}
            trackingEnabled={activeCamTracking.enabled}
            workerReady={activeCam ? (multiTracking.getState(activeCam.id).workerReady) : false}
            detections={activeCam ? (multiTracking.getState(activeCam.id).detections) : []}
            trackingState={activeCam ? (multiTracking.getState(activeCam.id).trackingState) : "idle"}
            lockedBox={activeCam ? (multiTracking.getState(activeCam.id).lockedBox) : null}
            onSendFrame={(imageData, w, h) => activeCam && multiTracking.sendFrame(activeCam.id, imageData, w, h, activeCamTracking.speed, activeCamTracking.shotPreset, activeCamTracking.deadZone)}
            onLockTarget={(box) => activeCam && multiTracking.lockTarget(activeCam.id, box)}
            onClearLock={() => activeCam && multiTracking.clearLock(activeCam.id)}
          />

          {/* Controller visualizer */}
          <ControllerVisualizer
            state={padState}
            mapping={mapping}
            onRemap={() => setShowRemap(true)}
            lightBarColor={activeCam?.color ?? "#1d4ed8"}
          />

          {/* Macro buttons */}
          {mapping.macros.some((m) => m.cmd) && (
            <div className="bg-zinc-900 border border-zinc-800 rounded-2xl p-5">
              <h3 className="text-zinc-400 text-xs uppercase tracking-widest mb-3">Macros</h3>
              <div className="grid grid-cols-4 gap-3">
                {mapping.macros.map((macro, i) =>
                  macro.cmd ? (
                    <button
                      key={i}
                      onClick={() => {
                        if (macro.toggle) {
                          setMacroStates((ms) => {
                            const next = [...ms] as typeof ms;
                            next[i] = !next[i];
                            sendCmd(next[i] ? macro.cmd : macro.offCmd);
                            return next;
                          });
                        } else {
                          sendCmd(macro.cmd);
                        }
                      }}
                      className={`py-3 rounded-xl text-sm font-medium transition-colors ${
                        macro.toggle && macroStates[i]
                          ? "bg-blue-600 text-white"
                          : "bg-zinc-800 hover:bg-zinc-700 text-zinc-300"
                      }`}
                    >
                      {macro.label || `Macro ${i + 1}`}
                    </button>
                  ) : (
                    <div key={i} className="py-3 rounded-xl bg-zinc-800/30 border border-dashed border-zinc-700 text-center text-xs text-zinc-600">
                      Empty
                    </div>
                  )
                )}
              </div>
            </div>
          )}

          {/* Debug */}
          <div className="bg-zinc-900 border border-zinc-800 rounded-2xl p-4 font-mono text-xs text-zinc-400 space-y-2">
            <div><span className="text-zinc-600">CMD </span><span className="text-green-400">{lastCmd || "—"}</span></div>
            <div><span className="text-zinc-600">RES </span><span className="text-zinc-300">{lastResponse || "—"}</span></div>
            {cameraStatus && (
              <div className="pt-1 border-t border-zinc-800 space-y-0.5">
                <div><span className="text-zinc-600">IRIS </span><span className="text-zinc-300">{cameraStatus.raw?.irisRaw || "—"}</span></div>
                <div><span className="text-zinc-600">ZOOM </span><span className="text-zinc-300">{cameraStatus.raw?.zoomRaw || "—"}</span></div>
                <div><span className="text-zinc-600">FOCUS </span><span className="text-zinc-300">{cameraStatus.raw?.focusRaw || "—"}</span></div>
              </div>
            )}
            <div className="pt-1 border-t border-zinc-800">
              <p className="text-zinc-600 mb-1.5">Haptic test</p>
              <div className="flex flex-wrap gap-2">
                {[
                  { label: "Short", strong: 0.5, weak: 0.3, ms: 80 },
                  { label: "Medium", strong: 0.7, weak: 0.5, ms: 300 },
                  { label: "Long", strong: 1.0, weak: 0.8, ms: 800 },
                  { label: "Soft", strong: 0.2, weak: 0.1, ms: 200 },
                ].map(({ label, strong, weak, ms }) => (
                  <button
                    key={label}
                    onClick={() => {
                      const gp = findGamepad();
                      const actuator = gp?.vibrationActuator;
                      if (!actuator) { alert(`No vibrationActuator found. Gamepad: ${gp?.id ?? "none"}`); return; }
                      actuator.playEffect("dual-rumble", { startDelay: 0, duration: ms, weakMagnitude: weak, strongMagnitude: strong });
                    }}
                    className="px-2 py-1 bg-zinc-700 hover:bg-zinc-600 rounded text-zinc-300 text-[10px] transition-colors"
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Background camera frame capture for workers not on the active feed */}
      {cameras.map((cam) => {
        const cfg = getCamTracking(cam.id);
        const state = multiTracking.getState(cam.id);
        if (!cfg.enabled || cam.id === activeCam?.id) return null;
        // Virtual cameras only render when active — no background frame capture.
        if (isVirtual(cam)) return null;
        const rawUrl = cam.streamUrl || (cam.ip ? `/api/stream?url=${encodeURIComponent(require("@/lib/ptz").defaultStreamUrl(cam))}` : "");
        if (!rawUrl) return null;
        return (
          <FrameCapture
            key={cam.id}
            streamUrl={`/api/stream?url=${encodeURIComponent(cam.streamUrl || require("@/lib/ptz").defaultStreamUrl(cam))}`}
            cameraId={cam.id}
            speed={cfg.speed}
            shotPreset={cfg.shotPreset}
            workerReady={state.workerReady}
            onSendFrame={(imageData, w, h) => multiTracking.sendFrame(cam.id, imageData, w, h, cfg.speed, cfg.shotPreset, cfg.deadZone)}
          />
        );
      })}

      {showConfig && (
        <CameraConfig cameras={cameras} onChange={handleCamerasChange} onClose={() => setShowConfig(false)} />
      )}
      {showRemap && (
        <RemapModal mapping={mapping} onChange={handleMappingChange} onClose={() => setShowRemap(false)} />
      )}
      {showPresets && activeCam && (
        <PresetManager
          camera={activeCam}
          mapping={mapping}
          onMappingChange={handleMappingChange}
          onSendCmd={(cmd) => sendCmd(cmd)}
          onClose={() => setShowPresets(false)}
        />
      )}
      {showProfiles && (
        <ProfilesModal
          currentMapping={mapping}
          onLoad={(m, name) => { setMapping(m); saveMapping(m); setActiveProfileName(name); }}
          onClose={() => setShowProfiles(false)}
        />
      )}
    </main>
  );
}

function Pill({ label, value, active }: { label: string; value: string; active?: boolean }) {
  return (
    <div className={`flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium border ${
      active ? "bg-blue-600/20 border-blue-500 text-blue-300" : "bg-zinc-800 border-zinc-700 text-zinc-400"
    }`}>
      <span className="text-zinc-500">{label}</span>
      <span>{value}</span>
    </div>
  );
}
