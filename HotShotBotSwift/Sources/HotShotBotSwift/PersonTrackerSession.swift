import AppKit
import Foundation

/// Per-camera AI tracking session, owned by `CameraSession`. Samples the camera's decoded feed
/// on its own timer (independent of `PTZControlLoop`'s 60Hz gamepad-poll tick), runs person
/// detection off the main actor via `PersonDetector`, steps a `TrackingEngine`, and sends the
/// resulting pan/tilt/zoom nudges straight through this camera's own `CameraClient`. This
/// mirrors the Electron app's Web Worker (`public/tracking.worker.js`) posting `sendPT`/
/// `sendZoom` reactively from `onmessage`, rather than through the gamepad's per-frame loop —
/// and because sends go through THIS session's own client regardless of which camera is
/// currently gamepad-active, tracking a non-active camera in the background (`FrameCapture.tsx`'s
/// role in the Electron app) works with no extra plumbing: enabling tracking on any camera just
/// works, active or not. `PTZControlLoop` only has to suppress its OWN gamepad-driven sends
/// while a camera's tracker is enabled — see its `handle(_:)`.
@MainActor
final class PersonTrackerSession: ObservableObject {
    @Published var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? startSampling() : stopSampling()
        }
    }
    @Published var shotPreset: ShotPreset = .none
    @Published private(set) var trackingState: TrackingState = .idle
    @Published private(set) var detections: [TrackedBox] = []
    @Published private(set) var lockedBox: TrackedBox?

    /// Deliberately separate from `ControlMapping.ptSensitivity` — a completely different input
    /// path (detection error, not a stick axis), matching the Electron app's own separate
    /// per-camera `speed` field on `CameraTrackingConfig`.
    var trackingSpeed: Double = 0.5
    var deadZone: Double = 0.04

    /// How often to sample a frame for detection — matches the throttled sampling rate
    /// `TrackingCanvas.tsx` posts frames to the tracking worker at, deliberately much slower
    /// than the ~30fps the camera stream itself decodes at; tracking doesn't need every frame,
    /// and running Vision that often would be wasteful, especially with multiple cameras
    /// tracking at once.
    private static let sampleInterval: TimeInterval = 0.15
    /// Detection runs at this fixed size regardless of the source frame's resolution — tracking
    /// only ever needs a box's center/height, not fine detail, and a smaller buffer is cheaper
    /// for both the GPU resize (`GPUFramePrep`) and the Vision request itself.
    private static let detectionSize = CGSize(width: 480, height: 270)

    private var engine = TrackingEngine()
    private let detector = PersonDetector()
    private var frameTimer: Timer?
    private var detecting = false
    private unowned let decoder: MJPEGStreamDecoder
    private unowned let client: CameraClient

    init(decoder: MJPEGStreamDecoder, client: CameraClient) {
        self.decoder = decoder
        self.client = client
    }

    deinit {
        frameTimer?.invalidate()
    }

    private func startSampling() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleFrame() }
        }
    }

    private func stopSampling() {
        frameTimer?.invalidate()
        frameTimer = nil
        detecting = false
        detections = []
        trackingState = .idle
        // lockedBox is deliberately NOT cleared here — disabling tracking (e.g. to hand control
        // back to the gamepad for a moment) shouldn't forget who you were tracking; only
        // clearLock() (an explicit unlock) does that. Re-enabling resumes the same lock.
    }

    private func sampleFrame() {
        // Skip this tick if the previous detection is still running — mirrors tracking.worker.js's
        // own `inferring` guard, so a slow frame doesn't queue a backlog of overlapping requests.
        guard !detecting,
              let image = decoder.currentFrame,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        guard let pixelBuffer = GPUFramePrep.makePixelBuffer(from: cgImage, size: Self.detectionSize) else { return }

        detecting = true
        Task {
            defer { detecting = false }
            do {
                let boxes = try await detector.detectPeople(in: pixelBuffer)
                apply(engine.step(detections: boxes, speed: trackingSpeed, shotPreset: shotPreset, deadZone: deadZone))
            } catch {
                // A single failed detection just means one skipped cycle, not a fatal error —
                // the next sample tick tries again.
            }
        }
    }

    private func apply(_ output: TrackingEngine.Output) {
        detections = output.detections
        trackingState = output.state
        lockedBox = output.lockedBox
        guard isEnabled else { return } // may have been disabled while detection was in flight
        if output.state == .tracking {
            client.sendContinuous(PTZCommands.axisToPanTiltCmd(pan: output.pan, tilt: output.tilt), channel: "pt")
            client.sendContinuous(PTZCommands.axisToZoomCmd(output.zoom), channel: "zoom")
        }
    }

    /// Called from a tap on a detection box in `TrackingOverlayView` — mirrors app/page.tsx's
    /// click-to-lock UI.
    func lock(_ box: TrackedBox) {
        engine.lock(box)
        lockedBox = box
    }

    func clearLock() {
        engine.unlock()
        lockedBox = nil
        trackingState = .idle
    }
}
