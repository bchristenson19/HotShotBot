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

    // MARK: - CameraKind: default, migration, virtual stream URL

    @Test func cameraDefaultsToPanasonicKind() {
        #expect(Camera(name: "Camera 1").kind == .panasonic)
        #expect(Camera(name: "Camera 1").isVirtual == false)
    }

    @Test func cameraJSONWithoutKindDecodesAsPanasonic() {
        // Persisted `[Camera]` written before `kind` existed has no `kind` key — it must still
        // decode (as `.panasonic`), which is why the field is defaulted.
        let jsonString = "{\"id\":\"00000000-0000-0000-0000-000000000000\",\"name\":\"Old Cam\",\"ip\":\"10.0.0.9\",\"port\":80,\"colorHex\":\"#1d4ed8\"}"
        let decoded = try! JSONDecoder().decode(Camera.self, from: Data(jsonString.utf8))
        #expect(decoded.kind == CameraKind.panasonic)
        #expect(decoded.name == "Old Cam")
    }

    @Test func virtualCameraHasNoStreamURLEvenWithIP() {
        // A virtual camera never streams over the network, so streamURL is nil regardless of any
        // stale ip/port left on the struct.
        let camera = Camera(name: "Virtual", ip: "192.168.1.50", port: 80, kind: .virtual)
        #expect(camera.isVirtual)
        #expect(camera.streamURL == nil)
    }

    @Test func cameraKindRoundTripsThroughCodable() {
        let original = Camera(name: "Virtual", colorHex: "#123456", kind: .virtual)
        let decoded = try! JSONDecoder().decode(Camera.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.kind == .virtual)
    }

    // MARK: - hexToRGB255

    @Test func hexToRGB255ParsesWithLeadingHash() {
        let rgb = hexToRGB255("#1d4ed8")
        #expect(rgb?.r == 0x1d)
        #expect(rgb?.g == 0x4e)
        #expect(rgb?.b == 0xd8)
    }

    @Test func hexToRGB255ParsesWithoutLeadingHash() {
        let rgb = hexToRGB255("dc2626")
        #expect(rgb?.r == 0xdc)
        #expect(rgb?.g == 0x26)
        #expect(rgb?.b == 0x26)
    }

    @Test func hexToRGB255RejectsMalformedInput() {
        #expect(hexToRGB255("") == nil)
        #expect(hexToRGB255("#zzzzzz") == nil)
        #expect(hexToRGB255("#abc") == nil)
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
