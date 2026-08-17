import AppKit
import Metal
import QuartzCore
import SceneKit
import simd

/// Drives a virtual camera's live feed: the native equivalent of `VirtualCameraCanvas.tsx`'s
/// requestAnimationFrame loop. On its own serial queue (~30 fps) it ticks the `VirtualPtzController`,
/// applies the integrated pose to the scene's `SCNCamera`, animates the walking actor, renders the
/// scene offscreen to an `NSImage`, and pushes that frame into the camera's `MJPEGStreamDecoder`
/// (via `publish(frame:)`) — so the UI and the tracking pipeline consume it exactly like a real
/// MJPEG feed, with no changes to either.
///
/// All scene-graph mutation and rendering happen on `renderQueue`; only the final frame publish
/// hops to the main thread (inside `MJPEGStreamDecoder.publish`). `SCNRenderer.snapshot` is safe to
/// call off the main thread, and keeping every scene write on this one queue avoids races with it.
final class VirtualCameraRenderer {

    private let controller: VirtualPtzController
    private let decoder: MJPEGStreamDecoder
    private let virtualScene = VirtualScene()
    private let renderer: SCNRenderer?

    /// Render resolution. The tracker downsamples to 480×270 (`PersonTrackerSession.detectionSize`)
    /// and the UI is aspect-fit, so 960×540 is plenty of detail at a fraction of full-HD cost.
    private static let renderSize = CGSize(width: 960, height: 540)
    private static let frameInterval = 1.0 / 30.0

    private let renderQueue = DispatchQueue(label: "com.hotshotbot.virtualcamera.render")
    private var timer: DispatchSourceTimer?
    private var startTime: CFTimeInterval = 0
    private var lastTime: CFTimeInterval = 0

    init(controller: VirtualPtzController, decoder: MJPEGStreamDecoder) {
        self.controller = controller
        self.decoder = decoder
        if let device = MTLCreateSystemDefaultDevice() {
            let r = SCNRenderer(device: device, options: nil)
            r.scene = virtualScene.scene
            r.pointOfView = virtualScene.cameraNode
            self.renderer = r
        } else {
            self.renderer = nil
        }
    }

    /// Begins the render loop. Idempotent — a second call while already running is a no-op.
    func start() {
        renderQueue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let now = CACurrentMediaTime()
            self.startTime = now
            self.lastTime = now
            let t = DispatchSource.makeTimerSource(queue: self.renderQueue)
            t.schedule(deadline: .now(), repeating: Self.frameInterval)
            t.setEventHandler { [weak self] in self?.renderFrame() }
            self.timer = t
            t.resume()
        }
    }

    /// Stops the render loop and releases the timer. Safe to call more than once.
    func stop() {
        renderQueue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    deinit {
        timer?.cancel()
    }

    private func renderFrame() {
        guard let renderer else { return }
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now
        let elapsed = now - startTime

        controller.tick(dt: dt)
        applyPose()
        virtualScene.updateActor(elapsed: elapsed)

        let image = renderer.snapshot(atTime: now, with: Self.renderSize, antialiasingMode: .multisampling4X)
        decoder.publish(frame: image)
    }

    /// Applies the controller's `(yaw, pitch, fov)` to the scene camera. Uses a quaternion rather
    /// than `eulerAngles` to avoid any ambiguity in SceneKit's rotation order: yaw about world Y
    /// (negated, matching Three.js `rotation.y = -yaw` so +yaw pans right), then pitch about the
    /// yawed local X. The camera only rotates — it never translates. FOV is the vertical field of
    /// view (`projectionDirection = .vertical`, set once in `VirtualScene`).
    private func applyPose() {
        let pose = controller.pose
        let qYaw = simd_quatf(angle: Float(-pose.yaw), axis: SIMD3<Float>(0, 1, 0))
        let qPitch = simd_quatf(angle: Float(pose.pitch), axis: SIMD3<Float>(1, 0, 0))
        virtualScene.cameraNode.simdOrientation = qYaw * qPitch
        virtualScene.cameraNode.camera?.fieldOfView = CGFloat(pose.fov)
    }
}
