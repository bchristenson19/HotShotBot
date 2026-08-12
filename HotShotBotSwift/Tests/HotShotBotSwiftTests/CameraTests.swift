import Foundation
import Testing
@testable import HotShotBotSwift

/// Verifies `Camera`'s Codable round-trip and stream-URL derivation, `defaultCameraColor`'s
/// palette cycling, and that `LegacyCameraSettings` (the retired milestone-1 `CameraSettings`
/// shape, kept only for migration) still decodes real legacy-formatted JSON correctly. Doesn't
/// touch `UserDefaults` at all — `CameraSessionStore.loadCameras()`'s migration path reads a
/// real, shared, persistent store, so it's exercised by reasoning + these decode-level tests
/// rather than by writing test fixtures into the actual UserDefaults domain.
struct CameraTests {

    // MARK: - defaultCameraColor

    @Test func defaultCameraColorCyclesThroughThePalette() {
        // Whatever the palette's length is, index N and index N+length must match, and adjacent
        // indices must not (a cycling palette with only one distinct color would defeat its own
        // purpose) — checked structurally rather than pinning exact hex values, so this doesn't
        // need to change if the palette itself is retouched later.
        var paletteSize = 1
        while defaultCameraColor(at: paletteSize) != defaultCameraColor(at: 0) {
            paletteSize += 1
            #expect(paletteSize < 64) // sanity bound — a real palette is nowhere near this large
        }
        #expect(paletteSize > 1)
        #expect(defaultCameraColor(at: 0) != defaultCameraColor(at: 1))
        #expect(defaultCameraColor(at: 1) == defaultCameraColor(at: 1 + paletteSize))
    }

    // MARK: - Camera: defaults, streamURL, Codable round-trip

    @Test func cameraWithNoIPHasNoStreamURL() {
        let camera = Camera(name: "Camera 1")
        #expect(camera.ip == "")
        #expect(camera.streamURL == nil)
    }

    @Test func cameraWithIPProducesExpectedStreamURL() {
        let camera = Camera(name: "Camera 1", ip: "192.168.1.50", port: 80)
        #expect(camera.streamURL?.absoluteString == "http://192.168.1.50:80/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30")
    }

    @Test func cameraCodableRoundTrip() {
        let original = Camera(name: "Wide Shot", ip: "10.0.0.5", port: 8080, colorHex: "#123456")
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(Camera.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - LegacyCameraSettings: migration decode

    @Test func legacyCameraSettingsDecodesRealMilestone1Shape() {
        // Matches exactly what the retired `CameraSettings.save()` would have written: both
        // fields always present, since Encodable always encodes every stored property.
        let json = #"{"ip":"10.0.0.5","port":8080}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(LegacyCameraSettings.self, from: json)
        #expect(decoded.ip == "10.0.0.5")
        #expect(decoded.port == 8080)
    }
}
