# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## What this is

HotShotBot: a PS5 DualSense PTZ camera controller with on-device AI person tracking, for Panasonic AW-UE70 / AW-UE160 / AW-HE130 cameras. Ships as a native unsigned Mac app (Electron 42 + Next.js 16, Apple Silicon only). A built-in **virtual 3D camera** (Three.js) lets the whole gamepad/preset/tracking pipeline run with no physical camera on the network, for demos and dev.

## Commands

```bash
npm install               # first run also triggers electron-builder install-app-deps (native node-hid)
npm run electron:dev      # Next.js dev server + Electron together, HMR (primary dev loop)
npm run dev               # Next.js only, at localhost:3000 (no Electron chrome/HID/light-bar)
npm run lint               # ESLint over .ts/.tsx
npm run electron:compile   # tsc build of electron/ main+preload → electron-dist/
npm run download:models    # fetch/copy TF.js + COCO-SSD weights into public/tfjs/ (run once, or after clean)
npm run electron:build     # download:models + next build + electron:compile + electron-builder --mac --arm64 → release/
```

There is no test suite. Verify changes by running `npm run electron:dev` and exercising the feature in the app — the virtual camera (add one via **Cameras → Add → model: Virtual**) covers the whole gamepad/tracking pipeline without needing a physical Panasonic camera or a DualSense controller's USB-HID light bar.

## Architecture

Three cooperating layers, same repo:

1. **`app/`** (Next.js App Router) — `app/page.tsx` is the entire UI as one large stateful client component (camera list, mapping state, gamepad polling loop, tracking orchestration, HUD-mode layout switch). `app/api/*/route.ts` are thin server-side proxies that exist solely to dodge the browser's CORS/SSRF restrictions when talking to cameras on the LAN — they are not a general backend.
2. **`lib/`** — pure, framework-free logic: `ptz.ts` (Panasonic CGI command encoding — pan/tilt/zoom/focus/iris/gain/preset/WB as raw `#PTSxxyy`-style strings, plus `isVirtual()`), `mapping.ts` (`ControlMapping`/`Profile` types, defaults, localStorage load/save), `presets.ts` (localStorage preset-name cache, separate from the camera's own on-device preset memory), `virtualPtz.ts`/`virtualScene.ts`/`virtualActor.ts` (the virtual camera — see below).
3. **`electron/`** — `main.ts` (window/tray/HID/IPC) and `preload.ts` (contextBridge → `window.electronAPI`), compiled separately via `electron/tsconfig.json` to `electron-dist/`. Renderer code must never assume `window.electronAPI` exists — always guard (`typeof window !== "undefined" && !!window.electronAPI`) since the same UI runs in a plain browser during `npm run dev`.

### Camera protocol (`lib/ptz.ts`, `app/api/camera*`)

Cameras speak Panasonic's HTTP CGI dialect: GET requests to `/cgi-bin/aw_ptz?cmd=...` or `/cgi-bin/aw_cam?cmd=...`. Commands are ASCII strings like `#PTS5050` (pan/tilt stop) or hex-encoded state (`byte 50` = stop, `01–49`/`51–99` = speed+direction either side of center). Status polling (`app/api/camera/status/route.ts`) parses the camera's hex replies back into human units (f-stop table, 0–100 position, dB gain) — if you touch either side, keep the encode/decode symmetric.

All camera HTTP calls are proxied through Next.js API routes (`/api/camera`, `/api/camera/status`, `/api/discover`, `/api/proxy-image`, `/api/stream`) rather than fetched directly from the browser, to avoid CORS. Each proxy that takes a client-supplied URL enforces an RFC1918/localhost allowlist regex — preserve that check if you modify those routes, it's the SSRF guard. **Electron is the exception**: `webSecurity: false` is set deliberately in `electron/main.ts` (comment explains it's for cross-origin canvas reads during tracking), so in Electron the app streams directly from the camera IP and skips the `/api/stream` proxy (`CameraFeed.tsx` branches on `isElectron`).

### Virtual camera (`lib/virtualPtz.ts`, `lib/virtualScene.ts`, `lib/virtualActor.ts`)

A `Camera` with `model: "virtual"` (`isVirtual()` in `lib/ptz.ts`) never hits the network. `app/page.tsx`'s command dispatch branches on `isVirtual(activeCam)`: real cameras POST to `/api/camera`, virtual ones call straight into a per-camera `VirtualPtzController` (owned by `useVirtualPtz.ts`, mirroring the `Map<cameraId, …>` pattern `useMultiCameraTracking` uses for workers). The controller parses the exact same CGI strings `lib/ptz.ts` emits (`#PTSxxyy`, `#Zxx`, `#Rxx`/`#Mxx`) and integrates a yaw/pitch/fov camera pose over time instead of sending HTTP. `VirtualCameraCanvas.tsx` renders a Three.js scene (`virtualScene.ts`) with a procedurally-animated walking human figure (`virtualActor.ts`, human-proportioned so COCO-SSD's person detector picks it up) into a `<canvas>`, and `CameraFeed.tsx` swaps that canvas in for the MJPEG `<img>` when the active camera is virtual — `TrackingCanvas`'s frame-source ref accepts either, so the AI tracking pipeline runs unmodified against it.

### Gamepad → camera control pipeline

`useGamepad.ts` polls `navigator.getGamepads()` every rAF frame and normalizes DualSense's raw button/axis indices into a stable `GamepadState`. `app/page.tsx` reads that state each frame, applies the user's `ControlMapping` (`lib/mapping.ts`) to decide what each button/axis currently does, and calls into `lib/ptz.ts` encoders to build CGI commands, dispatched per the virtual/real branch above. Remapping (`RemapModal.tsx`) and profiles (`ProfilesModal.tsx`) only ever rewrite the `ControlMapping` object — they don't touch the gamepad-reading or command-encoding code paths. `zoomInverted` defaults to `true` (stick up = zoom in/tele) and `tiltInverted` (default `false`) is a separate, independently-toggleable axis flip — both live on `ControlMapping` and apply after the single/dual-stick/d-pad branches, uniformly across input modes.

### AI tracking pipeline

Tracking runs **off the main thread**: one Web Worker (`public/tracking.worker.js`) per camera, spawned/owned by `useMultiCameraTracking.ts` (the hook actually wired into `app/page.tsx` — `useTracking.ts` is an earlier single-camera version, still present but not the active path; check call sites before assuming either is "the" tracking hook). Each worker loads TF.js + COCO-SSD from `public/tfjs/` (populated by `npm run download:models`, gitignored), tries the WebGPU (Metal) backend and falls back to WebGL, and receives `ImageData` frames posted from the main thread (`TrackingCanvas.tsx` / `FrameCapture.tsx` extract frames from the live feed — MJPEG `<img>` or virtual-camera `<canvas>` — at a throttled rate and post them across). The worker returns detections plus pan/tilt/zoom nudges computed from an EMA-smoothed locked-target position, keyed to a `ShotPreset` (`full`/`mid`/`none`) that sets a target box-height ratio and a head-anchor vertical target. `FrameCapture.tsx` exists specifically to keep feeding frames to a camera's worker even when that camera isn't the visually active one (multi-camera parallel tracking).

If you change the message shape between `useMultiCameraTracking.ts` and `public/tracking.worker.js`, update both — there's no shared type between them since one is a plain JS worker file, not compiled TS.

### Electron main process gotchas

- `isDev = !app.isPackaged` (not `NODE_ENV`) — this is a prior bug fix; don't regress it.
- In production, `main.ts` runs Next.js **in-process** — `next({dev: false, dir: app.getAppPath()}).getRequestHandler()` wired into a plain `http.createServer`, inside Electron's own Node runtime — rather than spawning a `next start` child process. A spawned child breaks in a packaged app: the `next` bin lives inside the asar archive and can't be exec'd (`ENOTDIR`), and it depends on a `node` on `PATH` end users don't have. `package.json`'s `build.asar` is set to `false` so `.next/`/`node_modules` are real on-disk files the in-process server can actually read. Don't reintroduce a spawned child or re-enable asar packing without re-solving both problems.
- DualSense light bar control talks directly to HID (vendor `0x054c`, product `0x0ce6`) via `node-hid`, dynamically imported (Electron main only, not bundled into the renderer). USB only — Bluetooth doesn't expose the HID output report needed for the light bar.
- The app icon (`build/icon.icns`/`build/icon.png`, referenced by `build.icon` in `package.json`) only reaches the Dock from the packaged bundle's `Info.plist`; in dev there's no bundle yet, so `main.ts` sets it explicitly via `app.dock.setIcon()` when `isDev`.

## Path aliases

Only one: `@/*` → repo root (`tsconfig.json`), used everywhere as `@/lib/...`, `@/hooks/...`, `@/components/...`. There's no `@shared`/`@renderer` split like the other Electron apps in this workspace — this is a single Next.js codebase with an Electron shell bolted on, not the main/preload/renderer three-target layout used in `hot-atem`/`HoT-Companion`/`HoT-Buddy`.
