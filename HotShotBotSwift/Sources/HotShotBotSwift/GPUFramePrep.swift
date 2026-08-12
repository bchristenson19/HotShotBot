import CoreGraphics
import CoreImage
import CoreVideo
import Metal

/// GPU-accelerated frame prep for the AI tracking pipeline: converts a decoded camera frame into
/// the `CVPixelBuffer` format Vision prefers, on the GPU via a Metal-backed `CIContext`, rather
/// than a CPU-bound path — matters most once several cameras are tracking concurrently (see
/// `CameraSession`/`CameraSessionStore`), where CPU-side scaling/format-conversion across N
/// pipelines would compete with everything else on the main thread.
enum GPUFramePrep {
    /// Shared across every camera session — a `CIContext` (and the `MTLDevice` backing it) is
    /// expensive to create and safe to reuse concurrently, so there should only ever be one.
    /// Force-unwrapped: every Mac this app targets (Apple Silicon only, per the project README)
    /// has a default Metal device.
    static let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!)

    /// Renders `cgImage` scaled to `size` into a freshly-allocated BGRA `CVPixelBuffer`, or nil
    /// if either the buffer allocation or the render fails — callers treat that as "skip this
    /// frame," not a fatal error, since a dropped tracking frame just means one detection cycle
    /// is skipped.
    static func makePixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        let scaleX = size.width / CGFloat(cgImage.width)
        let scaleY = size.height / CGFloat(cgImage.height)
        let scaledImage = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        context.render(scaledImage, to: buffer)
        return buffer
    }
}
