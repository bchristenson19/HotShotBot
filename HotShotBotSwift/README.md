# HotShotBotSwift

Native macOS Swift/SwiftUI rewrite of HotShotBot, starting from scratch. This is **milestone
1** of the rewrite: DualSense stick input → Panasonic CGI commands → live MJPEG feed, for a
single real camera. It lives alongside the existing Electron/Next.js app (`app/`, `electron/`,
`lib/`, etc. at the repo root) on the `swift` branch — the Electron app is untouched and stays
as reference while this native version grows.

## What's implemented

1. **Gamepad input** (`Sources/HotShotBotSwift/GamepadInput.swift`) — polls a connected
   `GCController`'s `extendedGamepad` profile via Apple's `GameController` framework at ~60Hz
   and publishes a `GamepadState` struct shaped like `hooks/useGamepad.ts`'s `GamepadState` in
   the TS app (leftX/Y, rightX/Y, face buttons, l1/r1, l2/r2 triggers, l3/r3, d-pad, options,
   touchpad, connected).
2. **PTZ command encoding** (`Sources/HotShotBotSwift/PTZCommands.swift`) — a faithful line-by-
   line port of `axisToPanTiltCmd`/`axisToSpeedByte`/`axisToZoomCmd` from `lib/ptz.ts`: same
   `#PTSxxyy` / `#Zxx` string formats, same 0.05 deadzone, same 1–30 (pan/tilt) / 1–49 (zoom)
   speed clamping, same byte math.
3. **Camera HTTP client** (`Sources/HotShotBotSwift/CameraClient.swift`) — sends those commands
   via `GET http://<ip>:<port>/cgi-bin/aw_ptz?cmd=<cmd>&res=1`, matching the request shape
   `app/api/camera/route.ts` builds. Throttled to ~66ms per channel (matching `CMD_INTERVAL_MS`
   in `app/page.tsx`) and drops sends if a request on the same channel is already in flight
   (matching the `inFlight` guard around `sendCmd`).
4. **MJPEG live view** (`Sources/HotShotBotSwift/MJPEGStreamDecoder.swift`) — a
   `URLSessionDataDelegate`-based decoder that reads the camera's
   `multipart/x-mixed-replace` MJPEG stream (`/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30`,
   matching `STREAM_PATHS` in `lib/ptz.ts`) by scanning raw bytes for JPEG SOI (`0xFFD8`) / EOI
   (`0xFFD9`) markers rather than parsing the multipart boundary string, and decodes each
   complete frame to an `NSImage` via `CGImageSource`.
5. **Control loop wiring** (`Sources/HotShotBotSwift/PTZControlLoop.swift`) — subscribes to
   `GamepadInput`'s published state and drives `CameraClient`, hardcoding the TS app's
   *default* `ControlMapping` (`lib/mapping.ts`'s `DEFAULT_MAPPING`): left stick = pan/tilt,
   right stick Y = zoom (inverted so stick-up = zoom in/tele, matching `zoomInverted: true`).
6. **UI** (`ContentView.swift`, `SettingsView.swift`, `HotShotBotSwiftApp.swift`) — a single
   window with the live feed, a controller/stream connection status indicator, a settings sheet
   to enter/persist the camera's IP+port (UserDefaults, via `CameraSettings` in
   `CameraClient.swift`), and a small debug panel showing the last CMD/RES pair and raw stick
   values (mirroring the CMD/RES debug readout in `app/page.tsx`).

## What's explicitly NOT done yet

Everything else in the TS app is a later milestone — none of it is implemented here:

- AI person tracking (Vision framework port of the COCO-SSD tracking pipeline)
- Virtual 3D camera (no Three.js equivalent yet)
- Multi-camera support (this is single-camera only)
- DualSense USB HID light bar control (`electron/main.ts`'s `hid:setLightBar` — GameController
  framework doesn't expose it; would need a raw HID library like the Electron app's `node-hid`)
- Presets (recall/save, thumbnail grid), profiles, full remapping UI
- Focus, iris, gain, white balance controls (`lib/ptz.ts` has encoders for these; only
  pan/tilt/zoom are ported so far)
- Camera auto-discovery, multi-camera config UI
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
    HotShotBotSwiftApp.swift    — @main App entry point, wires everything together
    ContentView.swift           — main window UI
    SettingsView.swift          — camera IP/port settings sheet
    GamepadInput.swift          — GameController polling → GamepadState
    PTZCommands.swift           — axis → CGI command string encoding (lib/ptz.ts port)
    CameraClient.swift          — throttled HTTP command sending + CameraSettings persistence
    PTZControlLoop.swift        — GamepadInput → PTZCommands → CameraClient wiring
    MJPEGStreamDecoder.swift    — MJPEG-over-HTTP byte-stream parsing → NSImage frames
  Tests/HotShotBotSwiftTests/
    PTZCommandsTests.swift      — unit tests for the PTZCommands port (see below)
  run-tests.sh                  — see "Running tests" below for why this exists
```

## Building

```bash
cd HotShotBotSwift
swift build            # debug build → .build/debug/HotShotBotSwift
swift run               # build + launch
```

Verified working on this machine (Command Line Tools only, Swift 6.3.3, macOS 26.6.1, Apple
Silicon): `swift build` completes cleanly with no warnings, and the resulting binary launches
and runs without crashing (checked by running it in the background for a few seconds with no
controller/camera attached, then killing it — confirms the `App` scene, `GCController`
observers, and empty-state UI all initialize without a physical DualSense or camera present).

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

**What the tests verify:** `Tests/HotShotBotSwiftTests/PTZCommandsTests.swift` has 18 cases
checking `PTZCommands.axisToPanTiltCmd`/`axisToSpeedByte`/`axisToZoomCmd` against input/output
pairs hand-derived from `lib/ptz.ts`'s exact arithmetic (not guessed) — deadzone boundaries at
±0.05, full-speed extremes (±1.0 → byte 20/80 for pan/tilt, 01/99 for zoom), the tilt axis's
sign-flip relative to pan, round-half-away-from-zero at the .5 boundaries, and out-of-range
clamping. All 18 currently pass.

## Testing against real hardware

You'll need to supply what this environment doesn't have:

**A camera.** Launch the app, click the gear icon (or it opens automatically if no IP is
saved), enter the camera's LAN IP (and port, default 80) in the settings sheet, and hit
"Save & Connect". The live feed should start streaming immediately if the camera is reachable
and running an MJPEG-capable firmware at `/cgi-bin/mjpeg`. The status dot next to "Stream" in
the header turns green once the first frame decodes.

**A DualSense controller.** Connect via USB or Bluetooth — macOS's GameController framework
should expose it automatically (no pairing step specific to this app). The "Controller" status
dot turns green once `GCControllerDidConnect` fires and the extended gamepad profile is
available. Push the left stick to drive pan/tilt, the right stick vertically to zoom; the debug
panel at the bottom of the window shows the raw stick values, the last CGI command sent, and
the camera's raw text response.

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
