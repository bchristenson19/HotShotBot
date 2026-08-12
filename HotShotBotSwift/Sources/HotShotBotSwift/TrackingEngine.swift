import Foundation

/// Normalized bounding box (0...1 on both axes), TOP-LEFT origin — matches the coordinate
/// convention `tracking.worker.js`'s COCO-SSD detections already used, which this engine's math
/// (ported line-for-line from that file) assumes throughout. `PersonDetector` is responsible for
/// converting Vision's lower-left-origin boxes into this convention before they ever reach here.
struct TrackedBox: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

enum TrackingState: String, Equatable {
    case idle, detecting, tracking, lost
}

/// Which portion of the subject the camera should frame — matches `ShotPreset` in
/// `hooks/useTracking.ts`/`useMultiCameraTracking.ts`.
enum ShotPreset: String, CaseIterable, Codable {
    case full, mid, none
}

/// Proportional-with-deadzone steering function — direct port of `trackAxis()` in
/// `public/tracking.worker.js`: no output below `deadZone`, full `speed` beyond 6x `deadZone`,
/// linear ramp between the two so the camera accelerates into a move rather than snapping to
/// full speed the instant it clears the deadzone.
func trackAxis(_ offset: Double, speed: Double, deadZone: Double) -> Double {
    let magnitude = abs(offset)
    guard magnitude >= deadZone else { return 0 }
    let direction: Double = offset > 0 ? 1 : -1
    let fastZone = deadZone * 6
    guard magnitude <= fastZone else { return direction * speed }
    return direction * ((magnitude - deadZone) / (fastZone - deadZone)) * speed
}

/// Person-tracking state machine + EMA smoothing — direct port of the lock/detect/track/lost
/// logic in `public/tracking.worker.js`. Pure and framework-free (no Vision/AppKit imports) so
/// it's testable without a camera, a Vision request, or any UI — see `TrackingEngineTests.swift`.
/// `PersonDetector` supplies the per-frame `detections`; this type never talks to Vision itself.
struct TrackingEngine {
    private(set) var lockedBox: TrackedBox?
    private var smoothX = 0.5
    private var smoothHeadY = 0.5
    private var smoothH: Double = 0

    /// EMA smoothing factor for the locked target's position — 0 = no smoothing (jittery),
    /// 1 = instant (no smoothing at all). Matches tracking.worker.js's `SMOOTH`.
    static let smoothing = 0.35
    /// Fraction of the box's height, down from its top, where the "head" anchor point sits —
    /// matches `HEAD_OFFSET`.
    static let headOffsetFraction = 0.04
    /// Normalized center-to-center distance beyond which a detection is considered too far from
    /// the locked box's last position to be the same person — matches the literal `0.6` in
    /// tracking.worker.js's `processFrame`.
    static let lostDistance = 0.6

    /// Desired bounding-box height as a fraction of frame height (nil = don't drive zoom at
    /// all). Matches `SHOT_PRESETS`.
    private static func targetHeight(for preset: ShotPreset) -> Double? {
        switch preset {
        case .full: return 0.80
        case .mid: return 1.80
        case .none: return nil
        }
    }

    /// Where the head anchor should sit vertically in frame (0 = top, 1 = bottom). Matches
    /// `TILT_TARGETS`.
    private static func targetHeadY(for preset: ShotPreset) -> Double {
        switch preset {
        case .full: return 0.15
        case .mid: return 0.20
        case .none: return 0.28
        }
    }

    /// Seeds the smoothed position/height from `box` with no initial lurch — mirrors the "lock"
    /// message handler in tracking.worker.js.
    mutating func lock(_ box: TrackedBox) {
        lockedBox = box
        smoothX = box.x + box.w / 2
        smoothHeadY = box.y + box.h * Self.headOffsetFraction
        smoothH = box.h
    }

    mutating func unlock() {
        lockedBox = nil
    }

    struct Output: Equatable {
        var state: TrackingState
        var detections: [TrackedBox]
        var lockedBox: TrackedBox?
        var pan: Double
        var tilt: Double
        var zoom: Double
    }

    /// One tracking step for a single frame's detections — direct port of `processFrame` (minus
    /// the actual person-detection, which happens upstream via `PersonDetector` and is handed in
    /// here as `detections`).
    mutating func step(detections: [TrackedBox], speed: Double, shotPreset: ShotPreset, deadZone: Double) -> Output {
        guard let locked = lockedBox else {
            return Output(state: detections.isEmpty ? .idle : .detecting, detections: detections, lockedBox: nil, pan: 0, tilt: 0, zoom: 0)
        }

        // Find the detection whose center is closest to the locked box's last known center.
        let lockedCenterX = locked.x + locked.w / 2
        let lockedCenterY = locked.y + locked.h / 2
        var best: TrackedBox?
        var bestDistance = Double.infinity
        for detection in detections {
            let dx = (detection.x + detection.w / 2) - lockedCenterX
            let dy = (detection.y + detection.h / 2) - lockedCenterY
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                best = detection
            }
        }

        guard let best, bestDistance <= Self.lostDistance else {
            // No detection close enough to be the same person — report "lost" but deliberately
            // leave `lockedBox` untouched (not cleared), so a later frame can re-acquire the same
            // target without requiring the user to tap-to-lock again, exactly like the JS worker.
            return Output(state: .lost, detections: detections, lockedBox: locked, pan: 0, tilt: 0, zoom: 0)
        }

        lockedBox = best

        // Smooth the matched box's center-X and head-Y with EMA to absorb frame-to-frame jitter.
        let rawCenterX = best.x + best.w / 2
        let rawHeadY = best.y + best.h * Self.headOffsetFraction
        smoothX += (rawCenterX - smoothX) * Self.smoothing
        smoothHeadY += (rawHeadY - smoothHeadY) * Self.smoothing
        smoothH += (best.h - smoothH) * Self.smoothing

        let pan = trackAxis(smoothX - 0.5, speed: speed, deadZone: deadZone)
        let tilt = trackAxis(smoothHeadY - Self.targetHeadY(for: shotPreset), speed: speed, deadZone: deadZone)

        var zoom = 0.0
        if let targetHeight = Self.targetHeight(for: shotPreset) {
            let zoomDeadZone = deadZone * 1.5
            let error = smoothH - targetHeight
            if abs(error) > zoomDeadZone {
                zoom = max(-1, min(1, -error * speed * 1.5))
            }
        }

        return Output(state: .tracking, detections: detections, lockedBox: best, pan: pan, tilt: tilt, zoom: zoom)
    }
}
