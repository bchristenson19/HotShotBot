import SwiftUI

/// Whether a camera is a real networked Panasonic PTZ head or the in-app virtual camera.
/// Mirrors `lib/ptz.ts`'s `CameraModel` union (`"aw-ue70" | … | "virtual"`), collapsed here to
/// the only distinction the native app actually acts on: real cameras hit the network, virtual
/// ones are driven by a `VirtualPtzController` + `VirtualCameraRenderer` entirely on-device.
/// `RawRepresentable`/`Codable` so it persists in the `[Camera]` JSON blob.
enum CameraKind: String, Codable {
    case panasonic
    case virtual
}

/// A single configured PTZ camera — replaces the milestone-1 single-camera `CameraSettings`.
/// IP/port/stream fields mirror `lib/ptz.ts`'s `Camera` type; `kind` adds the virtual-camera
/// distinction (see `CameraKind`), previously deferred.
struct Camera: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var ip: String = ""
    var port: Int = 80
    var colorHex: String = "#1d4ed8"

    /// Defaulted so persisted `[Camera]` JSON written before this field existed still decodes
    /// (as `.panasonic`) — same migration-safety reasoning as every other defaulted field here.
    var kind: CameraKind = .panasonic

    /// Mirrors `isVirtual(cam)` in lib/ptz.ts.
    var isVirtual: Bool { kind == .virtual }

    /// Default MJPEG stream URL, matching `STREAM_PATHS["aw-ue70"]` in lib/ptz.ts (shared
    /// default across AW-UE70/UE160/HE130 in the TS version). Virtual cameras have no network
    /// stream — their frames come from `VirtualCameraRenderer` instead — so this is `nil` for
    /// them (matching `defaultStreamUrl` returning `""` for virtual in the TS version).
    var streamURL: URL? {
        guard kind != .virtual, !ip.isEmpty else { return nil }
        return URL(string: "http://\(ip):\(port)/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30")
    }

    init(id: UUID = UUID(), name: String, ip: String = "", port: Int = 80,
         colorHex: String = "#1d4ed8", kind: CameraKind = .panasonic) {
        self.id = id
        self.name = name
        self.ip = ip
        self.port = port
        self.colorHex = colorHex
        self.kind = kind
    }

    /// Custom decoder so a defaulted field can be *absent* from persisted JSON. Swift's
    /// synthesized `init(from:)` ignores property default values and requires every key — so
    /// `[Camera]` blobs written before `kind` (or any future defaulted field) existed would fail
    /// to decode outright, losing the user's saved cameras. Decoding each field with a fallback
    /// keeps old data readable. (`encode(to:)` stays synthesized.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 80
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#1d4ed8"
        kind = try c.decodeIfPresent(CameraKind.self, forKey: .kind) ?? .panasonic
    }
}

/// Cycles through a small fixed palette so each new camera gets a visually distinct default
/// color, matching `defaultCameraColor()` in lib/ptz.ts. Deliberately contains no yellow: the
/// DualSense light bar is driven to the active camera's color (`PTZControlLoop.updateLightBar`)
/// EXCEPT while yielded to an RP-200, when it's forced solid yellow — that signal only stays
/// unambiguous if no camera color can ever be mistaken for it.
func defaultCameraColor(at index: Int) -> String {
    let palette = ["#1d4ed8", "#dc2626", "#16a34a", "#d97706", "#7c3aed", "#0891b2"]
    return palette[index % palette.count]
}

/// Parses a "#RRGGBB" (or "RRGGBB") hex string into 0–255 RGB components — shared by `Color.init(hex:)`
/// below and by the DualSense light bar, which wants raw bytes rather than a SwiftUI `Color`.
func hexToRGB255(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
}

extension Color {
    /// Falls back to a neutral gray for anything malformed rather than crashing — camera colors
    /// are purely cosmetic labels, never load-bearing, so a bad hex string should never break
    /// rendering.
    init(hex: String) {
        guard let (r, g, b) = hexToRGB255(hex) else {
            self = .gray
            return
        }
        self = Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
