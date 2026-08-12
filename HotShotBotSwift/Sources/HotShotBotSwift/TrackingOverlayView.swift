import SwiftUI

/// Draws each detected person's bounding box over the live feed, and turns a tap into either a
/// lock (tap inside a detection) or an unlock (tap elsewhere while something is locked) — the
/// SwiftUI equivalent of `TrackingCanvas.tsx`'s `handleClick`. `TrackedBox`es are normalized
/// (0...1, top-left origin); this view maps them into the feed image's actual on-screen rect,
/// which is smaller than the container whenever the camera's aspect ratio doesn't exactly match
/// the window (the feed is displayed with `.aspectRatio(contentMode: .fit)`, so it's
/// letterboxed) — the same "fit" math `TrackingCanvas.tsx`'s `mapX`/`mapY` do for a `<canvas>`.
struct TrackingOverlayView: View {
    let detections: [TrackedBox]
    let lockedBox: TrackedBox?
    let imageSize: CGSize?
    let onTapDetection: (TrackedBox) -> Void
    let onTapEmpty: () -> Void

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fittedRect(imageSize: imageSize, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(detections.enumerated()), id: \.offset) { _, box in
                    Rectangle()
                        .strokeBorder(box == lockedBox ? Color.green : Color.yellow, lineWidth: box == lockedBox ? 3 : 1.5)
                        .frame(width: box.w * fitted.width, height: box.h * fitted.height)
                        .position(
                            x: fitted.minX + (box.x + box.w / 2) * fitted.width,
                            y: fitted.minY + (box.y + box.h / 2) * fitted.height
                        )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    let location = value.location
                    guard fitted.contains(location), fitted.width > 0, fitted.height > 0 else { return }
                    let nx = (location.x - fitted.minX) / fitted.width
                    let ny = (location.y - fitted.minY) / fitted.height
                    if let hit = detections.first(where: { nx >= $0.x && nx <= $0.x + $0.w && ny >= $0.y && ny <= $0.y + $0.h }) {
                        onTapDetection(hit)
                    } else {
                        onTapEmpty()
                    }
                }
            )
        }
    }

    /// Computes the on-screen rect the image actually occupies inside `container` under
    /// `aspectRatio(contentMode: .fit)` — full width with letterboxed top/bottom, or full height
    /// with letterboxed left/right, whichever the image's own aspect ratio calls for.
    private static func fittedRect(imageSize: CGSize?, in container: CGSize) -> CGRect {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height
        if imageAspect > containerAspect {
            let height = container.width / imageAspect
            return CGRect(x: 0, y: (container.height - height) / 2, width: container.width, height: height)
        } else {
            let width = container.height * imageAspect
            return CGRect(x: (container.width - width) / 2, y: 0, width: width, height: container.height)
        }
    }
}
