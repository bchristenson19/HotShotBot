# HotShotBotSwift

Native macOS Swift/SwiftUI rewrite of HotShotBot, starting from scratch. **Milestone 1** was
DualSense stick input → Panasonic CGI commands → live MJPEG feed, for a single real camera.
**Milestone 2** (this update) added AI person tracking, a DualSense gyro-driven fine-adjust
mode, tuned D-pad/speed-modifier control feel, and multi-camera support with a multiview grid.
It lives alongside the existing Electron/Next.js app (`app/`, `electron/`, `lib/`, etc. at the
repo root) on the `swift` branch — the Electron app is untouched and stays as reference while
this native version grows.

## What's implemented

**Core control pipeline** (unchanged in shape since milestone 1, tuned since):
1. **Gamepad input** (`Sources/HotShotBotSwift/GamepadInput.swift`) — polls a connected
   `GCController`'s `extendedGamepad` profile via Apple's `GameController` framework at ~60Hz
   and publishes a `GamepadState` struct shaped like `hooks/useGamepad.ts`'s `GamepadState` in
   the TS app (leftX/Y, rightX/Y, face buttons, l1/r1, l2/r2 triggers, l3/r3, d-pad, options,
   touchpad, connected, plus rotation-rate gyro fields — see "Gyro fine-adjust" below).
2. **PTZ command encoding** (`Sources/HotShotBotSwift/PTZCommands.swift`) — a faithful line-by-
   line port of `axisToPanTiltCmd`/`axisToSpeedByte`/`axisToZoomCmd` from `lib/ptz.ts`: same
   `#PTSxxyy` / `#Zxx` string formats, same 0.05 deadzone, same 1–30 (pan/tilt) / 1–49 (zoom)
   speed clamping, same byte math.
3. **Camera HTTP client** (`Sources/HotShotBotSwift/CameraClient.swift`) — sends those commands
   via `GET http://<ip>:<port>/cgi-bin/aw_ptz?cmd=<cmd>&res=1`, matching the request shape
   `app/api/camera/route.ts` builds. Throttled to ~66ms per channel (matching `CMD_INTERVAL_MS`
   in `app/page.tsx`) and drops sends if a request on the same channel is already in flight
   (matching the `inFlight` guard around `sendCmd`). One instance per configured camera — see
   "Multi-camera support" below.
4. **MJPEG live view** (`Sources/HotShotBotSwift/MJPEGStreamDecoder.swift`) — a
   `URLSessionDataDelegate`-based decoder that reads the camera's
   `multipart/x-mixed-replace` MJPEG stream (`/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30`,
   matching `STREAM_PATHS` in `lib/ptz.ts`) by scanning raw bytes for JPEG SOI (`0xFFD8`) / EOI
   (`0xFFD9`) markers rather than parsing the multipart boundary string, and decodes each
   complete frame to an `NSImage` via `CGImageSource`.
5. **Control loop wiring** (`Sources/HotShotBotSwift/PTZControlLoop.swift`) — subscribes to
   `GamepadInput`'s published state and drives whichever camera is currently "active" via
   `CameraSessionStore`, applying `ControlMapping` (button actions, sensitivity, tilt-invert,
   d-pad fine pan/tilt, speed modifier, brake, momentum) in the same order `app/page.tsx` does.

**Gyro fine-adjust** — hold both `fineAdjustButtonA`/`fineAdjustButtonB` (default L1+R1,
configurable in Remap) to drive pan/tilt directly from the DualSense's gyro rotation rate
(`GCController.motion`) instead of the stick, for very fine framing nudges — bypasses the
stick, D-pad, speed modifier, brake, and momentum entirely (a nudge like this should feel
immediate, not glide). New entirely for this milestone; no equivalent in the Electron app. Axis
mapping/sign (`GyroAxisMapping` in `GamepadInput.swift`) is a best guess pending real-hardware
verification — see "Known unknowns."

**Tuned control feel** — D-pad fine pan/tilt now uses a smaller, user-tunable
`ControlMapping.dpadFineSpeed` (default 0.18) instead of a hardcoded 0.4; the speed modifier's
slow↔full-speed transition now eases via `ControlMapping.modifierEaseRate` (`PTZMath.eased`)
instead of snapping instantly. `ControlMapping` gained a hand-written `Decodable` init
(`decodeIfPresent(...) ?? default` per field) specifically so adding these new fields can never
wipe a previously-saved mapping — the compiler-synthesized version would throw on any unknown
key and silently reset to defaults.

**Multi-camera support + multiview** (`Camera.swift`, `CameraSession.swift`,
`CameraSessionStore.swift`) — a `Camera` list (name/ip/port/color) replaces the milestone-1
single `CameraSettings`; each camera gets its own `CameraSession` bundling a `CameraClient` +
`MJPEGStreamDecoder` + `PersonTrackerSession`, keyed by a stable `UUID` rather than an array
index. Exactly one camera is "active" for gamepad control at a time (`cycleCamera`, previously
an inert stub, now really cycles). `CameraGridView.swift` adds a multiview grid — every
camera's feed decodes live simultaneously regardless of which is active; tapping a tile makes
it active. `CameraSessionStore` also fixes a real safety gap found in the Electron reference:
switching the active camera there never sends a stop command, so a real PTZ camera left mid-pan
would keep moving indefinitely — the Swift version stops the outgoing camera explicitly on
every switch.

**AI person tracking** (`TrackingEngine.swift`, `PersonDetector.swift`, `GPUFramePrep.swift`,
`PersonTrackerSession.swift`) — a Vision-framework port of the Electron app's COCO-SSD tracking
pipeline (`public/tracking.worker.js`): `VNDetectHumanRectanglesRequest` (not pose estimation —
only a box's center/height is ever needed) detects people, `TrackingEngine` runs the same
EMA-smoothed lock/match/lost state machine and shot-preset target tables (full/mid/none), and
the result drives pan/tilt/zoom through the same per-camera `CameraClient` used by the gamepad
path. `GPUFramePrep` converts decoded frames to `CVPixelBuffer` via a Metal-backed `CIContext`
before handing them to Vision, keeping frame prep off the CPU — matters most with several
cameras tracking concurrently. Tracking is per-camera and independent of which camera is
gamepad-active (mirrors the Electron app's background-tracking capability with no extra
plumbing, since `PersonTrackerSession` sends through its own session's client reactively rather
than through the gamepad's per-tick loop). UI: a "Track" toggle + shot-preset picker in the
header, and `TrackingOverlayView.swift` draws detection boxes over the feed with tap-to-lock.

**UI** (`ContentView.swift`, `SettingsView.swift`, `CameraGridView.swift`,
`HotShotBotSwiftApp.swift`) — a Single/Grid toggle switches between the milestone-1-style single
active-camera view and the new multiview grid; `SettingsView` is now a camera list editor
(add/edit/remove) rather than a single IP/port form; the active camera's status row, feed, and
debug panel are unchanged in spirit from milestone 1.

## What's explicitly NOT done yet

Still later milestones — none of this is implemented here:

- Virtual 3D camera (no Three.js equivalent yet)
- DualSense USB HID light bar control (`electron/main.ts`'s `hid:setLightBar` — GameController
  framework doesn't expose it; would need a raw HID library like the Electron app's `node-hid`)
- Presets (recall/save, thumbnail grid), profiles, macros, full axis-remapping UI
- Focus, iris, gain, white balance controls (`lib/ptz.ts` has encoders for these; only
  pan/tilt/zoom are ported so far)
- Camera auto-discovery
- HUD mode / always-on-top window, tray icon, global keyboard shortcuts

## Project layout

Swift Package Manager executable, not an Xcode `.xcodeproj` — chosen because this machine only
has the Xcode Command Line Tools installed (no full Xcode.app), and SPM builds/tests entirely
from the command line without needing Xcode's GUI or `xcodebuild`. If you later open this in
Xcode.app, `File → Open` on `Package.swift` works fine and gets you the normal Xcode editing/
debugging experience — no conversion needed.

```
HotShotBotSwift/
  Package.swift
  Sources/HotShotBotSwift/
    HotShotBotSwiftApp.swift     — @main App entry point, wires everything together
    ContentView.swift            — main window UI (Single/Grid toggle, active-camera view)
    SettingsView.swift           — camera list editor (add/edit/remove)
    CameraGridView.swift         — multiview grid, one live tile per camera
    GamepadInput.swift           — GameController polling → GamepadState (incl. gyro rotation rate)
    ControlMapping.swift         — button/axis mapping config, hand-written safe Decodable init
    PTZMath.swift                — eased()/clamped() helpers (speed-modifier ease, gyro clamp)
    PTZCommands.swift            — axis → CGI command string encoding (lib/ptz.ts port)
    Camera.swift                 — Camera model, default color palette, hex Color helper
    CameraClient.swift           — throttled HTTP command sending, one instance per camera
    CameraSession.swift          — one camera's client + decoder + tracker + AF/momentum state
    CameraSessionStore.swift     — the camera list, which one is "active", persistence/migration
    PTZControlLoop.swift         — GamepadInput → PTZCommands → active CameraSession wiring
    MJPEGStreamDecoder.swift     — MJPEG-over-HTTP byte-stream parsing → NSImage frames
    TrackingEngine.swift         — pure lock/match/lost + EMA smoothing (tracking.worker.js port)
    PersonDetector.swift         — actor wrapping VNDetectHumanRectanglesRequest
    GPUFramePrep.swift           — Metal-backed CIContext frame → CVPixelBuffer conversion
    PersonTrackerSession.swift   — per-camera tracking session (sample timer, detect, steer)
    TrackingOverlayView.swift    — detection-box overlay + tap-to-lock on the feed
    RemapView.swift              — controller remap sheet
  Tests/HotShotBotSwiftTests/
    PTZCommandsTests.swift      — unit tests for the PTZCommands port
    TrackingEngineTests.swift   — unit tests for TrackingEngine/trackAxis
    PTZMathTests.swift          — unit tests for eased()/clamped()
    CameraTests.swift           — unit tests for Camera/defaultCameraColor/legacy migration decode
  run-tests.sh                  — see "Running tests" below for why this exists
```

## Building

```bash
cd HotShotBotSwift
swift build            # debug build → .build/debug/HotShotBotSwift
swift run               # build + launch
```

**Milestone 1** was verified working on this machine (Command Line Tools only, Swift 6.3.3,
macOS 26.6.1, Apple Silicon): `swift build` completed cleanly with no warnings, and the
resulting binary launched and ran without crashing (checked by running it in the background for
a few seconds with no controller/camera attached, then killing it — confirmed the `App` scene,
`GCController` observers, and empty-state UI all initialize without a physical DualSense or
camera present).

**Milestone 2's additions were verified by `swift build` + the unit test suite only** —
deliberately no `swift run`/launch this time, regardless of environment capability: the app
controls real broadcast camera hardware, and this pass happened while a live show was in
progress elsewhere on this hardware, so launching or restarting the app (Electron or Swift) was
explicitly out of scope for the session. A first real launch after pulling these changes should
re-confirm the milestone-1 smoke test above still holds, then work through "Testing against real
hardware" below — none of the new gyro/tracking/multi-camera behavior has been visually or
functionally exercised yet.

## Running tests

```bash
cd HotShotBotSwift
./run-tests.sh
```

**Why not `swift test` directly:** this environment has only the Xcode Command Line Tools
installed, not full Xcode.app. Apple's `XCTest.framework` for macOS is only bundled with Xcode
proper, so `import XCTest` fails here with "no such module 'XCTest'". The tests instead use
**Swift Testing** (`import Testing`, the modern `@Test`/`#expect` framework), which *does* ship
with the Command Line Tools toolchain — but `swift test`'s default invocation still fails
because it spawns the `swiftpm-testing-helper` subprocess without the `DYLD_FRAMEWORK_PATH` /
`DYLD_LIBRARY_PATH` needed to locate `Testing.framework` and `lib_TestingInterop.dylib` (both
live under `CommandLineTools/Library/Developer/`, not a default search path). `run-tests.sh`
builds with `swift build --build-tests -Xswiftc -F -Xswiftc <CLT frameworks dir>` and then
invokes the compiled `.xctest` bundle directly through `swiftpm-testing-helper` with those env
vars set explicitly. If this is ever run on a machine with full Xcode.app installed, plain
`swift test` should work fine on its own (this script becomes unnecessary but stays harmless).

**What the tests verify:** 48 cases across 4 suites, all currently passing.
`PTZCommandsTests.swift` (18 cases) checks `PTZCommands.axisToPanTiltCmd`/`axisToSpeedByte`/
`axisToZoomCmd` against input/output pairs hand-derived from `lib/ptz.ts`'s exact arithmetic —
deadzone boundaries at ±0.05, full-speed extremes (±1.0 → byte 20/80 for pan/tilt, 01/99 for
zoom), the tilt axis's sign-flip relative to pan, round-half-away-from-zero at the .5 boundaries,
and out-of-range clamping. `TrackingEngineTests.swift` checks `trackAxis`'s deadzone/ramp/full-
speed boundaries, that `lock()` seeds smoothed state with no initial jump, EMA convergence over
repeated steps, and the lost/re-acquire state machine at and around the 0.6 match-distance
threshold. `PTZMathTests.swift` checks `eased()`'s convergence behavior (rate 0/1/mid, and over
many steps) and `clamped()`'s boundary/out-of-range behavior. `CameraTests.swift` checks
`defaultCameraColor`'s palette cycling, `Camera`'s Codable round-trip and stream-URL derivation,
and that the retired `CameraSettings` shape still decodes correctly (the migration path
`CameraSessionStore.loadCameras()` relies on) — this one doesn't touch `UserDefaults` itself, to
avoid writing test fixtures into a real persistent store.

## Testing against real hardware

You'll need to supply what this environment doesn't have:

**A camera.** Launch the app, click the gear icon (or it opens automatically if the active
camera has no IP saved), enter the camera's LAN IP (and port, default 80) in the settings
sheet, and hit "Add" (or "Save" if editing an existing entry). The live feed should start
streaming immediately if the camera is reachable and running an MJPEG-capable firmware at
`/cgi-bin/mjpeg`. The status dot next to "Stream" turns green once the first frame decodes.

**A second (or third) camera, to test multi-camera + multiview.** Add more cameras the same
way. The header's Single/Grid toggle appears once there are 2+ cameras — Grid shows every
camera's feed live at once; tapping a tile makes it the gamepad-active one. `cycleCamera`
(default: the Options button) should also switch the active camera in Single mode.

**A DualSense controller.** Connect via USB or Bluetooth — macOS's GameController framework
should expose it automatically (no pairing step specific to this app). The "Controller" status
dot turns green once `GCControllerDidConnect` fires and the extended gamepad profile is
available. Push the left stick to drive pan/tilt, the right stick vertically to zoom; the debug
panel at the bottom of the window shows the raw stick values, the last CGI command sent, and
the camera's raw text response. Hold L1+R1 together and twist the controller to test gyro
fine-adjust — if pan/tilt moves the wrong direction or axis, that's the unverified
`GyroAxisMapping` guess (see below), fixable as a one-line change there.

**AI tracking.** Click "Track" in the header (disabled while yielded). With a person in frame,
tap their detection box (yellow) to lock on (turns green) — the camera should start steering to
keep them framed per the Free/Mid/Full shot preset. Tap elsewhere on the feed to unlock.

## Known unknowns (not verifiable without real hardware)

- **GameController + DualSense on macOS in practice.** The code reads `leftThumbstick`,
  `rightThumbstick`, `leftTrigger`/`rightTrigger`, `buttonA/B/X/Y`, `dpad`, `buttonOptions`,
  `leftThumbstickButton`/`rightThumbstickButton` off `GCExtendedGamepad`, plus
  `touchpadButton` via a cast to `GCDualSenseGamepad` (Apple's DualSense-specific subclass, has
  existed since macOS 11.3) — all per Apple's public headers, and Apple documents DualSense as
  a first-class supported controller. But whether Bluetooth vs. USB connection matters for
  which profile gets exposed, whether the axis polarity assumptions match a real unit (SDL/other
  frameworks have occasionally disagreed with Apple's about Y-axis sign — worth double-checking
  that "stick up" really produces a positive `yAxis.value` and not a value that needs negating
  on top of what `PTZCommands` already does), and the exact behavior of `waitingForPress` /
  `GCControllerDidConnect` timing over Bluetooth are all unverified.
- **MJPEG parsing against a real Panasonic stream.** The SOI/EOI byte-scanning approach is
  standard for MJPEG-over-HTTP and should be robust to boundary-string variation across camera
  firmware, but it's untested against an actual AW-UE70/UE160/HE130's stream — there could be
  firmware quirks (chunked transfer encoding edge cases, a boundary marker that happens to
  contain byte sequences matching `0xFFD8`/`0xFFD9`, unusually large frames near the 8MB buffer
  cap) that only show up against the real device.
- **No AppKit-level verification that a window actually renders.** The build+launch smoke test
  confirms the process starts and exits cleanly without crashing, but there was no way in this
  environment to visually confirm the SwiftUI window actually paints the feed/controls as
  intended — worth a first-run visual check.
- **Gyro (`GCMotion`) on a real DualSense.** `GCController.motion: GCMotion?` and
  `GCMotion.rotationRate`/`sensorsActive` are confirmed real, documented API surface (checked
  against the actual GameController.framework headers on this machine, not assumed) — but
  whether a physical DualSense (USB or Bluetooth) actually returns a non-nil `.motion` with live
  non-zero `rotationRate` once `sensorsActive = true` is unverified. If `.motion` turns out to be
  nil in practice, gyro fine-adjust degrades safely to "does nothing" rather than crashing.
- **Which `GCRotationRate` axis is pan vs. tilt, and sign, on a real unit.** Not documented
  anywhere in Apple's headers (they specify only the right-hand-rule sign per abstract axis, not
  the controller's physical orientation) — `GyroAxisMapping` in `GamepadInput.swift` is a
  best guess and will likely need a swap/flip after a first real test; it's isolated there
  specifically so that's a one-line fix.
- **Vision detection quality/latency against real camera frames.** Compression artifacts,
  motion blur, and actual per-frame inference time on the target Mac (needs to stay comfortably
  under the 150ms sample interval, especially with multiple cameras tracking at once) are
  unverified against real Panasonic MJPEG frames.
- **N simultaneous `MJPEGStreamDecoder`/`CameraClient`/tracking pipelines' real network/CPU
  behavior** against actual AW-UE70/UE160/HE130 units hasn't been measured — plausible by
  design (the Electron app's own background-tracking feature establishes the pattern works at
  all), but not against this specific hardware.
- **Tuned default values** (`dpadFineSpeed = 0.18`, `modifierEaseRate = 0.20`,
  `fineAdjustSensitivity = 0.15`/`fineAdjustMaxOutput = 0.35`) are reasoned from the existing
  momentum/modifier math, not hardware-validated — expect a tuning pass once testable.
- **SwiftUI grid/tile rendering and the tap-to-lock overlay's hit-testing math** have never been
  visually verified, same category as the existing "no AppKit-level verification" item above.
