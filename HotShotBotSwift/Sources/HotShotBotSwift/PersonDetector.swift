import Vision

/// The only Vision-framework-touching code in the tracking pipeline — kept as its own tiny actor
/// (rather than folded into `PersonTrackerSession`) specifically so
/// `VNImageRequestHandler.perform([_])` (synchronous/blocking) can never run on `@MainActor` and
/// stall the gamepad-polling `Timer`/SwiftUI.
actor PersonDetector {
    private let request: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.revision = VNDetectHumanRectanglesRequestRevision2
        // Default is true — full/mid shot presets need a full-body box, not just the upper body,
        // to compute a meaningful "box height vs. target" zoom error.
        request.upperBodyOnly = false
        return request
    }()

    /// Runs detection on one frame, returning normalized TOP-LEFT-origin boxes — Vision's own
    /// `boundingBox` is normalized but LOWER-LEFT-origin, so `y` is flipped here to match the
    /// convention the rest of the tracking pipeline (ported from COCO-SSD's boxes) assumes.
    func detectPeople(in pixelBuffer: CVPixelBuffer) throws -> [TrackedBox] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox
            return TrackedBox(x: box.origin.x, y: 1 - box.origin.y - box.height, w: box.width, h: box.height)
        }
    }
}
