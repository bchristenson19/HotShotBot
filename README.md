# HotShotBot

PS5 DualSense PTZ camera controller with AI person tracking. Built for Panasonic AW-UE70, UE160, and HE130 cameras. Runs as a native Mac app via Electron.

## Changelog

### v1.1.0
- **Preset Manager** — full 100-slot grid with live thumbnails from the camera, names read/written directly to the camera, click-to-recall, Shift+click to save, face button rebinding by clicking button → slot
- **Tracking (β)** — smoother movement via EMA position smoothing, WebGPU (Metal) backend, TF.js served locally (no internet required), fixed cross-origin canvas access in Electron
- **Electron fixes** — fixed app launch crash, fixed stream disappearing when tracking enabled

### v1.0.0
- Initial release

---

## Features

**Camera Control**
- Full PS5 DualSense gamepad control — pan, tilt, zoom, focus, iris, gain
- Fully remappable buttons and axes via **Remap → Advanced**
- Multiple control modes: momentum, dual-stick (additive), trigger zoom
- R2 speed brake for precision shots, PT speed modifier button (slow/fast)
- Zoom sensitivity and momentum control

**Preset Manager**
- 100-slot preset grid with live thumbnails pulled from the camera
- Preset names read from and written back to the camera
- Click to recall, Shift+click to save current position to a slot
- Rebind face buttons to any slot: click a button badge → click a slot
- Thumbnail auto-refreshes after saving

**AI Tracking (β)**
- Click-to-track person detection via COCO-SSD + WebGPU (Metal on Apple Silicon)
- Multi-camera parallel tracking — each camera runs its own Web Worker
- **Full Shot** — keeps whole body in frame with auto-zoom
- **Mid Shot** — keeps head-to-waist in frame with auto-zoom
- Adjustable tracking speed and dead zone

**Virtual Camera**
- Built-in 3D camera — drive a rendered scene when no physical camera is present
- Exercises the full stack: gamepad control, presets, and AI tracking all work with no hardware
- A walking figure in the scene gives person tracking something to lock onto
- Great for demos, development, and testing

**Live Feed**
- MJPEG stream per camera with overlay (iris, zoom, focus, AF/MF state)
- Controls overlay showing D-pad and face buttons on the feed
- Full screen mode
- Always-on-top HUD mode for use alongside other software (`⌘⇧H`)

**Profiles & Settings**
- Per-operator profiles — save and load full controller configs
- Camera auto-discovery via network scan
- DualSense light bar color per camera (USB)

## Requirements

- Apple Silicon Mac (M1/M2/M3)
- macOS 13+
- PS5 DualSense controller (USB or Bluetooth)
- Panasonic PTZ camera on the same local network (AW-UE70, AW-UE160, AW-HE130) — optional; the built-in virtual camera works with no hardware

## Installation

Download the latest release from [Releases](../../releases).

1. Open `HotShotBot-x.x.x-arm64.dmg`
2. Drag **HotShotBot** to Applications
3. First launch: right-click → **Open** (bypasses Gatekeeper — app is unsigned)

## Development

```bash
npm install
npm run electron:dev
```

Runs Next.js + Electron together. The app opens at `localhost:3000` inside an Electron window.

## Build

```bash
npm run electron:build
```

Downloads TF.js model weights locally, builds Next.js, compiles Electron, and outputs `.dmg` + `.zip` to `release/` for Apple Silicon.

## Camera Setup

1. Open the app → click **Cameras**
2. Click **Discover** to auto-scan your network for Panasonic PTZ cameras
3. Or add manually: enter IP, port (default 80), and select the model
4. Each camera gets a color — the DualSense light bar changes to match the active camera (USB only)

No camera on hand? Add one and pick the **Virtual (3D)** model — no IP needed. It renders a 3D scene you can control and track just like a real camera.

## Controller Setup

Connect the DualSense via USB or Bluetooth. Press any button once to activate — the status dot turns green.

**Default mapping:**

| Input | Action |
|---|---|
| Left stick | Pan / Tilt |
| Right stick Y | Zoom |
| Right stick X | Focus (manual) |
| R2 | Speed brake (hold for precision) |
| L2 | Iris close |
| ✕ / ○ / □ / △ | Recall presets 1–4 |
| L1/R1 + face button | Save preset |
| L3 | Toggle auto focus |
| Options | Cycle camera |
| Touchpad | Cycle white balance |

All buttons and axes are remappable via **Remap → Advanced**.

## Tech Stack

- **Next.js 16** — UI and API routes (PTZ proxy, camera status, network discovery, image proxy)
- **Electron 42** — native Mac app wrapper, HID light bar control
- **TensorFlow.js + COCO-SSD** — on-device person detection via WebGPU (Metal)
- **Three.js** — renders the virtual camera's 3D scene
- **Web Workers** — one inference worker per camera for parallel tracking
- **Gamepad API** — DualSense input at 60fps
