import SwiftUI

/// A single configured PTZ camera — replaces the milestone-1 single-camera `CameraSettings`.
/// IP/port/stream fields mirror `lib/ptz.ts`'s `Camera` type, minus model/virtual-camera fields
/// (still out of scope for this milestone — see the project README).
struct Camera: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var ip: String = ""
    var port: Int = 80
    var colorHex: String = "#1d4ed8"

    /// Default MJPEG stream URL, matching `STREAM_PATHS["aw-ue70"]` in lib/ptz.ts (shared
    /// default across AW-UE70/UE160/HE130 in the TS version).
    var streamURL: URL? {
        guard !ip.isEmpty else { return nil }
        return URL(string: "http://\(ip):\(port)/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30")
    }
}

/// Cycles through a small fixed palette so each new camera gets a visually distinct default
/// color, matching `defaultCameraColor()` in lib/ptz.ts.
func defaultCameraColor(at index: Int) -> String {
    let palette = ["#1d4ed8", "#dc2626", "#16a34a", "#d97706", "#7c3aed", "#0891b2"]
    return palette[index % palette.count]
}

extension Color {
    /// Parses a "#RRGGBB" (or "RRGGBB") hex string into a Color, falling back to a neutral gray
    /// for anything malformed rather than crashing — camera colors are purely cosmetic labels,
    /// never load-bearing, so a bad hex string should never break rendering.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            self = .gray
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
