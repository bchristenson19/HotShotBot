# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Project Overview

HotShotBot is a PS5 DualSense-driven PTZ camera controller with AI person tracking, packaged as a native macOS app (Apple Silicon) via Electron. It controls Panasonic PTZ cameras (AW-UE70, AW-UE160, AW-HE130) over HTTP, reads a DualSense gamepad at 60fps, and runs on-device person detection to auto-track subjects.

## Commands

```bash
npm install              # first run also triggers electron-builder install-app-deps (native node-hid)
npm run electron:dev     # Next.js dev server + Electron window together (dev workflow)
npm run dev              # Next.js only, browser at localhost:3000 (no HID light bar / HUD)
npm run lint             # eslint (flat config, next core-web-vitals + typescript)
npm run electron:build   # production .dmg + .zip to release/ for arm64
npm run electron:compile # tsc-compile electron/*.ts → electron-dist/ only
```

There is no test suite. Lint is the only automated check.

## Architecture

Three cooperating layers:

1. **Next.js app** (`app/`) — React 19 UI plus API routes that proxy all camera traffic. The browser never talks to a camera directly (avoids CORS, canvas taint, and mixed-content). Everything funnels through `/api/*`.
2. **Electron shell** (`electron/`) — spawns `next start` in production (`startNextServer`), owns the window, the tray, the `⌘⇧H` HUD toggle, and DualSense light-bar control over USB HID. Compiled separately to `electron-dist/` via `electron/tsconfig.json`.
3. **Tracking workers** (`public/tracking.worker.js`) — one Web Worker per camera runs TF.js + COCO-SSD off the main thread and emits PTZ commands.

### Control loop (the heart of the app)

`app/page.tsx` is the single stateful container. `useGamepad` runs a `requestAnimationFrame` loop, reads the DualSense every frame, and calls `onFrame(state)`. `onFrame` does everything: edge-detects button presses (`pressed()` compares against `prevButtons` ref), applies the current `ControlMapping`, computes pan/tilt/zoom/focus with momentum, and dispatches CGI commands.

Command dispatch has two paths, both in `page.tsx`:
- `sendCmd` — fire-and-forget POST to `/api/camera`, with a per-`channel` in-flight guard so a slow request can't stack.
- `sendContinuous` — same, but rate-limited to `CMD_INTERVAL_MS` (66ms) per channel. Used for held-axis streams (pan/tilt, zoom, focus, iris). Channels keep independent command streams from throttling each other.

### CGI command layer (`lib/ptz.ts`)

Pure functions mapping intent → raw AW-UE70 CGI strings. Two camera endpoints:
- `aw_ptz` — motion/lens (`#PTS`, `#Z`, `#F`, presets `#R`/`#M`). Default endpoint for bare-string commands.
- `aw_cam` — camera params (auto-focus `OSE:69`, iris `LIO`/`LIC`/`LIT`, gain `OGU`). Commands targeting this endpoint are passed as `{cmd, endpoint}` objects.

Non-obvious encodings, all centered on 50 = stop: pan/tilt/zoom/focus use a `50±speed` byte scheme. **Iris nudges require a follow-up `LIT` commit command** — see `IRIS_COMMIT_CMD` and how `page.tsx` fires it on the `iris-commit` channel alongside every open/close. Gain is hex where `0x08`=0dB and `0x80`=auto.

### Input mapping & persistence (`lib/mapping.ts`)

`ControlMapping` is the full remappable config: button→action table, axis assignments, and tuning (momentum, sensitivity, dual-stick mode, speed brake, etc.). Everything persists to `localStorage`:
- `ptz-mapping` — active mapping. `loadMapping()` **deep-merges** stored config over `DEFAULT_MAPPING` and coerces every scalar through a NaN guard, so adding a new field to `DEFAULT_MAPPING` won't break users with old stored configs. Follow this pattern when adding config fields.
- `ptz-profiles` — named saved mappings (operator profiles).
- `ptz-cameras` — camera list (backfills `model` for pre-model-field entries).

### AI tracking (multi-camera)

`useMultiCameraTracking` owns a `Map<cameraId, Worker>`. Each worker (`public/tracking.worker.js`) loads TF.js from **CDN via `importScripts`** (workers can't use the webpack bundle) and prefers the **WebGPU backend (Metal on Apple Silicon)**, falling back to CPU. `hooks/useTracking.ts` is an older single-camera main-thread implementation kept for reference; the worker is authoritative for the shipping multi-cam path.

Frame flow: `CameraFeed` (active cam) or `FrameCapture` (hidden, background cams) grabs frames off the MJPEG `<img>` onto a canvas at ~10fps, ships `ImageData` to the worker (transferred, zero-copy). The worker detects people, tracks the locked box by center-proximity, and returns `{pan, tilt, zoom}` which `page.tsx` sends to the camera. **When tracking is enabled, gamepad pan/tilt is suppressed** (`trackingEnabledRef`) — tracking drives the camera.

Shot presets differ between the two implementations — the worker's `SHOT_PRESETS`/`TILT_TARGETS` (head-anchored framing, `full`=0.80 box height, `mid`=1.80) are the live values.

### API routes (`app/api/`)

- `POST /api/camera` — proxy one CGI command. Validates command format, 2s timeout.
- `GET /api/camera/status` — polls `#GI`/`#GZ`/`#GF` + gain/AF in parallel (400ms each) and parses raw hex into iris f-stops, zoom/focus %, gain dB. Parsers are deliberately flexible across firmware (2–4 hex digits).
- `GET /api/stream?url=` — proxies the MJPEG stream; **SSRF-guarded to local network + http only**.
- `GET /api/discover` — scans the first local /24 subnet, probing every host with `#O` and reading `QID` for the model.

`useCameraStatus` polls status and, on the **first** successful poll after a camera switch, syncs AF/iris mode into UI state; after that the controller is authoritative (`hasSyncedRef`).

### Electron ↔ renderer bridge

`electron/preload.ts` exposes `window.electronAPI` (light bar, HUD toggle/query, HUD-mode subscription). `useElectronLightBar` pushes the active camera's color to the DualSense over HID (USB only). The app detects Electron by presence of `window.electronAPI` and renders a compact **HUD layout** (a separate return branch in `page.tsx`) when the window is in always-on-top mini mode.

## Conventions

- **Read `node_modules/next/dist/docs/` before writing Next.js code** (see AGENTS.md) — this is Next.js 16 and may diverge from training data.
- Hot-path callbacks (`onFrame`, `processFrame`) read mutable state through refs, not deps, to stay stable and avoid re-subscribing the RAF loop. Keep new per-frame reads on refs.
- The camera is stateless about intent — the app tracks AF/iris/gain/WB state locally and pushes deltas. Don't assume the camera will report back changes you made.
