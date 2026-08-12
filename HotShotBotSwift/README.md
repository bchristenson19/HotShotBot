# HotShotBotSwift

Native macOS Swift/SwiftUI rewrite of HotShotBot, starting from scratch. **Milestone 1** was
DualSense stick input → Panasonic CGI commands → live MJPEG feed, for a single real camera.
**Milestone 2** added AI person tracking, a DualSense gyro-driven fine-adjust mode, tuned
D-pad/speed-modifier/stick-deadzone control feel, and multi-camera support with a multiview
grid. **v1.0.0** (this release) turns that multi-camera support into something usable on a real
show: a multiview grid that actually fills the window instead of leaving most of it blank,
double-click-to-focus, a DualSense light bar synced to the active camera (forced yellow while
yielded to an RP-200), yield-to-RP-200 automation (yielded by default on launch, kept in
lockstep with whichever camera is active), a real fix for the camera-cycle button doing
nothing, and a remappable grid-view toggle.
It lives alongside the existing Electron/Next.js app (`app/`, `electron/`, `lib/`, etc. at the
repo root) on the `swift` branch — the Electron app is untouched and stays as reference while
this native version grows. Shipped as
[`v1.0.0-swift`](https://github.com/bchristenson19/HotShotBot/releases/tag/v1.0.0-swift).

## What's implemented

**Core control pipeline** (unchanged in shape since milestone 1, tuned since):
1. **Gamepad input** (`Sources/HotShotBotSwift/GamepadInput.swift`) — polls a connected
   `GCController`'s `extendedGamepad` profile via Apple's `GameController` framework at ~60Hz
   and publishes a `GamepadState` struct shaped like `hooks/useGamepad.ts`'s `GamepadState` in
   the TS app (leftX/Y, rightX/Y, face buttons, l1/r1, l2/r2 triggers, l3/r3, d-pad, options,
   touchpad, connected, plus rotation-rate gyro fields — see "Gyro fine-adjust" below).
   **v1.0.0 fix:** the `options` field was reading `pad.buttonOptions`, but GameController's
   naming is Xbox-derived — `buttonOptions` is the DualSense's **Create** button (left side),
   while the physical **Options** button (right side, the one actually bound to Cycle Camera by
   default) reports through `buttonMenu`. This was the root cause of the camera-cycle button
   doing nothing; confirmed fixed after the user tested it on real hardware.
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
immediate, not glide). New entirely for this milestone; no equivalent in the Electron app.
**Confirmed working on a real DualSense** — `GCController.motion` does stream live rotation-rate
data in practice, resolving what was originally an unverified assumption. Real-hardware testing
did surface one real fix: tilt felt backwards, so `ControlMapping.fineAdjustTiltInverted`
(Remap → Pan/Tilt → Gyro Fine-Adjust) was added as a dedicated toggle, deliberately separate
from the stick's own `tiltInverted` since gyro and stick are unrelated input paths — flipping
one doesn't touch the other. Which raw `GCRotationRate` axis maps to pan (as opposed to tilt)
is still an unconfirmed guess (`GyroAxisMapping` in `GamepadInput.swift`) — see "Known unknowns."

**Tuned control feel** — D-pad fine pan/tilt now uses a smaller, user-tunable
`ControlMapping.dpadFineSpeed` (default 0.18) instead of a hardcoded 0.4; the speed modifier's
slow↔full-speed transition now eases via `ControlMapping.modifierEaseRate` (`PTZMath.eased`)
instead of snapping instantly. `ControlMapping` gained a hand-written `Decodable` init
(`decodeIfPresent(...) ?? default` per field) specifically so adding these new fields can never
wipe a previously-saved mapping — the compiler-synthesized version would throw on any unknown
key and silently reset to defaults. `ControlMapping.stickDeadzone` (Remap → Pan/Tilt → Sticks)
zeroes a raw stick axis at or below threshold before sensitivity/D-pad/modifier/brake/momentum
ever see it — added after real-world testing with an older controller whose sticks don't
return exactly to center; the previous fixed 0.05 threshold only gated momentum's internal
decay-vs-accelerate decision and did nothing at all when momentum was disabled, so drift could
still leak straight through as slow, unwanted pan/tilt/zoom creep.

**Multi-camera support + multiview** (`Camera.swift`, `CameraSession.swift`,
`CameraSessionStore.swift`) — a `Camera` list (name/ip/port/color) replaces the milestone-1
single `CameraSettings`; each camera gets its own `CameraSession` bundling a `CameraClient` +
`MJPEGStreamDecoder` + `PersonTrackerSession`, keyed by a stable `UUID` rather than an array
index. Exactly one camera is "active" for gamepad control at a time (`cycleCamera`, previously
an inert stub, now really cycles — see the `buttonMenu` fix above). `SettingsView`'s camera list
editor now has a dedicated "+" button next to the "Cameras" title (v1.0.0 fix — with exactly one
camera configured, the sheet auto-opens into an Edit form for discoverability, but that used to
leave no *visible* way to add a second camera; clicking "Cancel Edit" happened to reset the form
into Add mode, but nothing signaled that).

`CameraGridView.swift` adds a multiview grid — every camera's feed decodes live simultaneously
regardless of which is active. Tiles are sized from a `GeometryReader` read of the whole grid's
available space rather than a fixed adaptive-width grid (which left most of the window as dead
space at typical camera counts): `CameraGridView.bestColumnCount` brute-forces the row/column
split that renders the biggest 16:9 tile for the current window shape and camera count — e.g.
exactly 2 cameras in a normal (not ultra-wide) window actually render bigger stacked in 1 column
than side by side in 2, which is non-obvious enough that it's covered by
`CameraGridViewTests.swift` rather than trusted by eye alone. A single tap on a tile makes it the
gamepad-active camera without leaving the grid; a double tap does that AND switches back to
Single view to show it full-window, mirroring hardware multiviewers' "double-click to focus"
convention. The active tile's outline is red and 5px wide (was a thin accent-color border).

`CameraSessionStore` also fixes a real safety gap found in the Electron reference: switching the
active camera there never sends a stop command, so a real PTZ camera left mid-pan would keep
moving indefinitely — the Swift version stops the outgoing camera explicitly on every switch
(`setActive`/`stopOutgoingCamera`). `setActive` additionally keeps yield state in lockstep with
which camera is active (see "Yield-to-RP-200 automation" below): the outgoing camera is yielded,
the incoming one is un-yielded — this fires from single/double-tapping a tile and from the
controller's Cycle Camera button alike, since both funnel through the same method.

**Yield-to-RP-200 automation** (`CameraClient.swift`, `CameraSessionStore.swift`) —
`CameraClient.isYielded` now defaults to `true` (was `false`): on a fresh launch, no camera
moves until the operator explicitly takes control, rather than a stray gamepad touch
immediately driving whatever camera happens to be active. With only one camera configured
that means pressing the yield button (Triangle by default) once after launch; with two or more,
selecting a camera in multiview (single/double tap, or the Cycle Camera button) un-yields it
automatically via `setActive` (see above), so in normal multi-camera use only the camera you're
actively driving is ever un-yielded — every other tile reads as handed off to an RP-200 rather
than silently still-under-HotShotBot-control. Confirmed working as described.

**DualSense light bar** (`DualSenseLightBar.swift`, wired into `PTZControlLoop`) — this app had
no light-bar control at all before v1.0.0 (see "What's explicitly NOT done yet" in the previous
milestone). `DualSenseLightBar` is a native `IOHIDManager`-based port of the Electron app's
`node-hid`-based `hid:setLightBar` handler (`electron/main.ts`) — same 48-byte USB output report
(report ID `0x02`, valid-fields flags `0xff`/`0x0f`, RGB at bytes 44–46), just via IOKit
(a system framework) instead of an npm dependency, since this is a plain SPM package with no
external dependencies. `PTZControlLoop.updateLightBar()` runs at the top of every ~60Hz gamepad
poll tick (diffed against the last-sent color so it doesn't re-write the HID device 60 times a
second) and sets the light bar to the active camera's `colorHex`, or solid yellow whenever that
camera is yielded — none of the default camera colors are yellow (see `defaultCameraColor`'s
doc comment), so that stays an unambiguous signal. USB only, matching the Electron app's own
limitation: Bluetooth DualSense connections don't expose the output report this needs. **Not
yet confirmed against a real controller** — see "Known unknowns".

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
Tracking can also be toggled straight from the controller — `toggleTracking` is a
`ButtonActionId` bound to Square by default (rebindable in Remap → Buttons), so it doesn't have
to be reached for on-screen mid-shot.

**UI** (`ContentView.swift`, `SettingsView.swift`, `CameraGridView.swift`,
`HotShotBotSwiftApp.swift`) — a Single/Grid toggle switches between the milestone-1-style single
active-camera view and the new multiview grid; `SettingsView` is now a camera list editor
(add/edit/remove) rather than a single IP/port form; the active camera's status row, feed, and
debug panel are unchanged in spirit from milestone 1. The Single/Grid flag
(`CameraSessionStore.isGridMode`) lives on the session store rather than as `ContentView`'s own
local `@State`, specifically so `PTZControlLoop` can flip it directly from a new remappable
`toggleGridView` button action (defaults to Circle) — the same store already backing everything
else camera-related that both the UI and the control loop need to reach.

## What's explicitly NOT done yet

Still later milestones — none of this is implemented here:

- Virtual 3D camera (no Three.js equivalent yet)
- Presets (recall/save, thumbnail grid), profiles, macros, full axis-remapping UI
- Focus, iris, gain, white balance controls (`lib/ptz.ts` has encoders for these; only
  pan/tilt/zoom are ported so far)
- Camera auto-discovery
- HUD mode / always-on-top window, tray icon, global keyboard shortcuts
- Custom app icon — `Info.plist` has no `CFBundleIconFile`, so the packaged `.app`/DMG shows
  the generic default icon (`build/icon.icns`/`.png` at the repo root are the Electron app's
  icon assets, not currently wired into this target's bundle at all)

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
    CameraGridView.swift         — multiview grid, one live tile per camera, sized to fill the window
    DualSenseLightBar.swift      — native IOKit HID light-bar control (node-hid port, no dependency)
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
    CameraTests.swift           — unit tests for Camera/defaultCameraColor/legacy migration decode/hexToRGB255
    CameraGridViewTests.swift   — unit tests for bestColumnCount's window-aware column selection
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

**Milestone 2's initial implementation was verified by `swift build` + the unit test suite
only** — deliberately no `swift run`/launch during that pass, regardless of environment
capability: a live show was in progress elsewhere on this same hardware at the time, so
launching or restarting the app was explicitly out of scope for that session.

**Milestone 2 has since been built in release configuration (`swift build -c release`),
packaged into a `.app` bundle (`./build-app.sh release`), installed to `/Applications`, and
run on a real DualSense against a real camera** — the core gamepad control pipeline and gyro
fine-adjust are both confirmed working ("the controls feel really solid"). That real-hardware
pass is what surfaced two of this update's fixes: gyro tilt direction needed a dedicated invert
toggle, and an older controller's stick drift needed a real, adjustable deadzone rather than the
previous fixed, momentum-only one.

**v1.0.0 has been through several real-hardware rounds against a live multi-camera setup** —
adding a second camera, multiview grid-fill sizing, double-click-to-focus, per-camera yield
automation, the active-tile outline, and the `buttonMenu` cycle-camera fix were all exercised
live and confirmed working (double-click-to-focus explicitly — "that works well"; the
cycle-camera fix implicitly, via no further complaint after being asked to specifically verify
it). **The DualSense light bar has not** — it was implemented and packaged into this release
without a real controller confirming the light actually changes color; see "Known unknowns".
AI tracking specifically still hasn't had explicit hands-on confirmation in either milestone —
see "Testing against real hardware" below for what to check.

## Releasing

No dedicated script for this yet — the v1.0.0 DMG was built by hand with:

```bash
cd HotShotBotSwift
swift build -c release
./build-app.sh release                     # → .build/HotShotBotSwift.app

rm -rf .build/dmg-staging
mkdir -p .build/dmg-staging
ditto .build/HotShotBotSwift.app .build/dmg-staging/HotShotBotSwift.app
ln -s /Applications .build/dmg-staging/Applications      # drag-to-install convention
hdiutil create -volname "HotShotBotSwift" -srcfolder .build/dmg-staging \
  -ov -format UDZO .build/HotShotBotSwift-<version>-arm64.dmg
```

Tag as `v<version>-swift` (an annotated tag, e.g. `git tag -a v1.0.0-swift -m "..."`) — the
`-swift` suffix disambiguates this sub-project's releases from the Electron app's own `vX.Y.Z`
tags in the same repo. Publish with `gh release create v<version>-swift
.build/HotShotBotSwift-<version>-arm64.dmg --title "..." --notes "..." --latest=false` —
`--latest=false` is deliberate and should stay: the Electron app is still the actively-shipped
product, and its own latest tag (`v1.2.0` as of this writing) should keep the repo's "Latest"
badge unless/until that changes. Remember to bump `Info.plist`'s `CFBundleShortVersionString`
(and `CFBundleVersion`, a plain incrementing build counter) before packaging — `build-app.sh`
copies whatever `Info.plist` currently says, so an unbumped version ships silently.

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

**What the tests verify:** 57 cases across 5 suites, all currently passing.
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
that the retired `CameraSettings` shape still decodes correctly (the migration path
`CameraSessionStore.loadCameras()` relies on), and (added for v1.0.0) `hexToRGB255`'s parsing
with/without a leading `#` and its `nil` return on malformed input — this one doesn't touch
`UserDefaults` itself, to avoid writing test fixtures into a real persistent store.
`CameraGridViewTests.swift` (new for v1.0.0, 6 cases) checks `bestColumnCount`'s brute-force
search picks the column count that actually renders the biggest tile for a given window shape
and camera count — including the non-obvious case (hand-verified via the formula in that
function's own doc comment) where exactly 2 cameras render bigger stacked in 1 column than side
by side in 2, for any window narrower than 16:9.

## Testing against real hardware

You'll need to supply what this environment doesn't have:

**A camera.** Launch the app, click the gear icon (or it opens automatically if the active
camera has no IP saved), enter the camera's LAN IP (and port, default 80) in the settings
sheet, and hit "Add" (or "Save" if editing an existing entry). The live feed should start
streaming immediately if the camera is reachable and running an MJPEG-capable firmware at
`/cgi-bin/mjpeg`. The status dot next to "Stream" turns green once the first frame decodes.

**A second (or third) camera, to test multi-camera + multiview.** Click the "+" next to
"Cameras" in Settings to add more (v1.0.0 fix — this used to only be reachable by clicking
"Cancel Edit" on the auto-opened single-camera edit form, with nothing signaling that). The
header's Single/Grid toggle appears once there are 2+ cameras — Grid shows every camera's feed
live at once, sized to fill the window; a single tap on a tile makes it the gamepad-active one,
a double tap does that AND switches to Single view (**confirmed working** — "that works well").
The active tile has a thick red outline. `cycleCamera` (default: the Options button) should also
switch the active camera in Single mode — **confirmed working** after a v1.0.0 fix (was reading
the wrong physical button; see "Known unknowns"). Whichever camera you switch away from should
show "Yielded" (and the light bar, once confirmed — see below — would show yellow for it) since
`setActive` yields the outgoing camera and un-yields the incoming one automatically.

**A DualSense controller.** Connect via USB or Bluetooth — macOS's GameController framework
should expose it automatically (no pairing step specific to this app). The "Controller" status
dot turns green once `GCControllerDidConnect` fires and the extended gamepad profile is
available. Push the left stick to drive pan/tilt, the right stick vertically to zoom; the debug
panel at the bottom of the window shows the raw stick values, the last CGI command sent, and
the camera's raw text response. If an older controller's sticks don't rest exactly at center,
raise "Dead zone" in Remap → Pan/Tilt → Sticks until the drift stops registering. Hold L1+R1
together and twist the controller to test gyro fine-adjust (confirmed working on real
hardware) — if tilt feels backwards, flip "Invert tilt" in Remap → Pan/Tilt → Gyro Fine-Adjust;
if PAN feels backwards or swapped with tilt, that's the still-unverified `GyroAxisMapping` guess
(see below), which needs an actual code change (a one-line flip/swap in `GamepadInput.swift`),
not just a toggle.

**The DualSense light bar — not yet confirmed, please check this specifically.** Connect the
controller via USB (Bluetooth won't expose the needed HID report). With one camera configured,
launch the app and check the light bar is yellow immediately (yield-on-by-default), then press
Triangle to un-yield and confirm it switches to that camera's color (blue by default for the
first camera). With two cameras, switch the active one (tap a tile, or the Cycle Camera button)
and confirm the light bar follows — and confirm it's yellow while the INACTIVE camera would be
selected, i.e. never showing yellow for a camera that's actually being driven. If nothing happens
at all, the most likely failure point is `DualSenseLightBar.currentDevice()` not finding the
controller via `IOHIDManagerCopyDevices` — worth checking with a HID inspection tool (e.g.
`ioreg -p IOUSB -l | grep -i dualsense`) that the controller enumerates with vendor `0x054c`
product `0x0ce6` over USB on this machine at all.

**AI tracking.** Click "Track" in the header, or press whichever button is bound to
`toggleTracking` (Square by default) — both toggle the same state (disabled while yielded). With
a person in frame, tap their detection box (yellow) to lock on (turns green) — the camera should
start steering to keep them framed per the Free/Mid/Full shot preset. Tap elsewhere on the feed
to unlock.

## Known unknowns (not verifiable without real hardware)

- **GameController + DualSense on macOS in practice — mostly confirmed.** Real-hardware testing
  ("the controls feel really solid") confirms `leftThumbstick`/`rightThumbstick` axis polarity
  and the button reads are correct as ported — no stick-direction or button-mapping complaints,
  only the separate gyro tilt-direction issue described below. One button WAS wrong: the
  physical Options button did nothing because `GamepadState.options` read `pad.buttonOptions`
  (the DualSense's separate Create button, in GameController's Xbox-derived naming) instead of
  `pad.buttonMenu` — fixed for v1.0.0 and confirmed working. Still unconfirmed: whether
  Bluetooth vs. USB connection matters for which profile gets exposed, and the exact behavior of
  `waitingForPress`/`GCControllerDidConnect` timing over Bluetooth specifically (testing so far
  hasn't distinguished the two transports).
- **DualSense light bar via IOKit HID — implemented, not yet confirmed.** New for v1.0.0
  (`DualSenseLightBar.swift`): a byte-for-byte port of the Electron app's working `node-hid`
  report layout, sent via `IOHIDDeviceSetReport` instead. The IOKit call pattern matches known-
  working reference implementations (report ID included in the buffer's first byte AND passed
  as the explicit `reportID` parameter, mirroring how `hidapi`'s own Mac backend does it), but
  nothing has actually confirmed a real DualSense's light bar changes color yet — see "Testing
  against real hardware" above for exactly what to check first.
- **MJPEG parsing against a real Panasonic stream.** The SOI/EOI byte-scanning approach is
  standard for MJPEG-over-HTTP and should be robust to boundary-string variation across camera
  firmware, but it's untested against an actual AW-UE70/UE160/HE130's stream — there could be
  firmware quirks (chunked transfer encoding edge cases, a boundary marker that happens to
  contain byte sequences matching `0xFFD8`/`0xFFD9`, unusually large frames near the 8MB buffer
  cap) that only show up against the real device.
- **~~No AppKit-level verification that a window actually renders.~~ Resolved.** The window
  does render and the controls are usable — confirmed by real-hardware testing (see "Building").
  `CameraGridView`'s multiview layout is now ALSO resolved: grid-fill sizing, double-tap-to-
  focus, and the active-tile outline have all been exercised in live multi-camera use (see
  "Building" and "Testing against real hardware"). `TrackingOverlayView`'s tap-to-lock
  hit-testing specifically still hasn't been part of any confirmation — see below.
- **Gyro (`GCMotion`) on a real DualSense — confirmed working.** `GCController.motion` does
  return non-nil with live `rotationRate` data on real hardware once `sensorsActive = true`,
  resolving what was originally an unverified assumption. Tilt direction did need flipping in
  practice, now handled by the `fineAdjustTiltInverted` toggle rather than a code change.
- **Whether the PAN axis specifically is correctly mapped/signed is still unconfirmed.** Only
  tilt was reported as backwards and only tilt has a toggle so far — `GyroAxisMapping.pan(_:)`
  in `GamepadInput.swift` hasn't had explicit confirmation either way. If pan also turns out
  backwards or swapped with tilt, that needs an actual code change there (or a second toggle
  added the same way `fineAdjustTiltInverted` was), not something fixable from the UI today.
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
- **`TrackingOverlayView`'s tap-to-lock hit-testing math** has never been visually verified
  against a real feed — `CameraGridView`'s own rendering is now resolved (see above), but this
  one specific view wasn't part of that pass.
