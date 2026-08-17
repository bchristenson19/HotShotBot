import Foundation

/// One configured camera's live state: its HTTP client, MJPEG decoder, and the per-camera AF/
/// momentum state that used to live directly on `PTZControlLoop` back when this app was
/// single-camera only. `PTZControlLoop` now holds a `CameraSessionStore` and reads/writes
/// through `sessionStore.activeSession` instead of a single `CameraClient` — see that file.
@MainActor
final class CameraSession: ObservableObject, Identifiable {
    let id: Camera.ID
    @Published var camera: Camera
    let client: CameraClient
    let decoder: MJPEGStreamDecoder
    let tracker: PersonTrackerSession

    /// Non-nil for a virtual camera (`camera.kind == .virtual`): renders the SceneKit feed and
    /// pushes frames into `decoder`, and its `VirtualPtzController` is wired into `client` so
    /// PTZ commands drive the virtual pose instead of the network. `nil` for real cameras.
    private let virtualRenderer: VirtualCameraRenderer?

    /// Per-camera AF state — mirrors `autoFocus`/`oneTouchActive` in app/page.tsx, now scoped
    /// per-camera instead of once globally. Note: with no camera-status poll in either
    /// milestone, this still reflects only what THIS app last commanded for THIS camera, not
    /// necessarily its real current AF state — same real limitation as milestone 1, just now
    /// correctly scoped instead of one global flag misrepresenting every other camera.
    @Published private(set) var autoFocus = true
    @Published private(set) var oneTouchActive = false
    private var oneTouchTimer: DispatchWorkItem?

    /// Momentum/modifier state — moved here from PTZControlLoop for the same per-camera reason:
    /// camera A's mid-glide velocity shouldn't bleed into camera B's after switching the active
    /// camera, and each camera eases its own speed-modifier transition independently. Plain
    /// (non-`@Published`) since nothing in the UI binds to these directly — only PTZControlLoop
    /// reads/writes them, same as when they lived there.
    var panVelocity: Double = 0
    var tiltVelocity: Double = 0
    var zoomVelocity: Double = 0
    var currentModifierScale: Double = 1.0

    init(camera: Camera) {
        self.id = camera.id
        self.camera = camera
        let decoder = MJPEGStreamDecoder()
        self.decoder = decoder

        if camera.isVirtual {
            let controller = VirtualPtzController()
            self.client = CameraClient(camera: camera, virtualController: controller)
            self.virtualRenderer = VirtualCameraRenderer(controller: controller, decoder: decoder)
        } else {
            self.client = CameraClient(camera: camera)
            self.virtualRenderer = nil
        }
        self.tracker = PersonTrackerSession(decoder: decoder, client: client)
    }

    /// Starts this camera's feed: the SceneKit render loop for a virtual camera, or the MJPEG
    /// network stream for a real one (a virtual camera's `streamURL` is `nil`, so it never opens
    /// a `URLSession`).
    func start() {
        if let virtualRenderer {
            virtualRenderer.start()
        } else if let url = camera.streamURL {
            decoder.start(url: url)
        }
    }

    /// Fully tears down this session's feed — stops the virtual render loop (or the MJPEG stream)
    /// so no timer/connection is left running after the camera is removed. Called by
    /// `CameraSessionStore.removeCamera` in place of a bare `decoder.stop()`.
    func teardown() {
        virtualRenderer?.stop()
        decoder.stop()
    }

    /// Applies edited fields (name/ip/port/color) from Settings — restarts the stream only if
    /// the address actually changed, so editing just the name/color doesn't interrupt a live feed.
    func applyEdits(_ updated: Camera) {
        let addressChanged = updated.ip != camera.ip || updated.port != camera.port
        camera = updated
        client.camera = updated
        if addressChanged {
            decoder.stop()
            start()
        }
    }

    /// Ports app/page.tsx's `toggleAutoFocus` button action.
    func toggleAutoFocus() {
        autoFocus.toggle()
        let (cmd, endpoint) = PTZCommands.autoFocusCmd(autoFocus)
        client.send(cmd, endpoint: endpoint)
    }

    /// Handles a press of whichever button is bound to `oneTouchFocus`, in whichever mode is
    /// currently configured — mirrors app/page.tsx's `oneTouchFocus` case in `handleButtonPress`
    /// (moved here from PTZControlLoop verbatim, now scoped per-camera). TS also rumbles the
    /// controller here (`rumble(0.5, 0.3, 80)` etc.) — deliberately not ported: GameController's
    /// haptics API (CHHapticEngine-based) is materially more involved to wire up than the browser
    /// Gamepad API's dual-rumble, and out of scope for this pass.
    func handleOneTouchFocusPress(mode: OneTouchFocusMode) {
        switch mode {
        case .pulse:
            guard oneTouchTimer == nil else { return } // already running — ignore re-press
            let onCmd = PTZCommands.autoFocusCmd(true)
            client.send(onCmd.cmd, endpoint: onCmd.endpoint)
            autoFocus = true
            oneTouchActive = true

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.oneTouchTimer = nil
                let offCmd = PTZCommands.autoFocusCmd(false)
                self.client.send(offCmd.cmd, endpoint: offCmd.endpoint)
                self.autoFocus = false
                self.oneTouchActive = false
            }
            oneTouchTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)

        case .hold:
            guard !autoFocus else { return } // already on — release handler turns it off
            let onCmd = PTZCommands.autoFocusCmd(true)
            client.send(onCmd.cmd, endpoint: onCmd.endpoint)
            autoFocus = true
            oneTouchActive = true
        }
    }

    /// Releases a hold-mode one-touch-focus press — called when the currently-bound button is
    /// released. Mirrors app/page.tsx's separate post-loop hold-mode-release check.
    func releaseOneTouchFocusHold() {
        let offCmd = PTZCommands.autoFocusCmd(false)
        client.send(offCmd.cmd, endpoint: offCmd.endpoint)
        autoFocus = false
        oneTouchActive = false
    }

    /// Sends an explicit pan/tilt stop and zeros this session's own velocity — used when the
    /// controller disconnects or this camera stops being the active one, so it doesn't keep
    /// drifting after losing gamepad input.
    func stopPanTilt() {
        client.stopPanTilt()
        panVelocity = 0
        tiltVelocity = 0
    }
}
