import Foundation

/// Sends Panasonic CGI commands to a camera over HTTP, throttled to avoid flooding it with
/// duplicate commands on every controller poll tick.
///
/// Ports the request shape used by `app/api/camera/route.ts` (the Next.js proxy the Electron
/// app talks to) directly against the camera — this native app has no CORS restriction so it
/// skips the proxy layer entirely and hits the camera straight from `URLSession`.
@MainActor
final class CameraClient: ObservableObject {

    /// IP (and optional port) of the camera being controlled. Empty IP means "not configured".
    @Published var settings: CameraSettings

    /// Most recent command string sent, and the camera's raw text response — mirrors the
    /// "CMD / RES" debug panel in `app/page.tsx`.
    @Published private(set) var lastCommand = ""
    @Published private(set) var lastResponse = ""
    @Published private(set) var isConnected = false

    /// When true, an external controller (e.g. an RP-200 panel) is driving this camera —
    /// `send()` suppresses every outgoing command unconditionally. Mirrors `yieldedCams`/
    /// `isYielded` in app/page.tsx, but collapsed into `CameraClient` itself (the single choke
    /// point all commands already flow through here) rather than kept in a separate top-level
    /// ref the TS version needs because its state lives one level up, in the page component.
    @Published private(set) var isYielded = false

    func toggleYield() {
        isYielded.toggle()
    }

    /// Minimum spacing between sent PTZ commands on a given channel, matching `CMD_INTERVAL_MS`
    /// in `app/page.tsx` (66ms) — the gamepad is polled at ~60Hz but the camera shouldn't be
    /// hit that often.
    static let commandIntervalMs: UInt64 = 66

    private var lastSentAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession

    init(settings: CameraSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        session = URLSession(configuration: config)
    }

    /// Sends a command on a named channel (e.g. "pt", "zoom") if enough time has elapsed since
    /// the last send on that channel. Same throttling model as `sendContinuous` in app/page.tsx.
    func sendContinuous(_ cmd: String, channel: String, endpoint: String = "aw_ptz") {
        let now = Date()
        if let last = lastSentAt[channel],
           now.timeIntervalSince(last) * 1000 < Double(Self.commandIntervalMs) {
            return
        }
        lastSentAt[channel] = now
        send(cmd, channel: channel, endpoint: endpoint)
    }

    /// Sends a command immediately (no throttling), dropping it if a request on the same
    /// channel is already in flight — mirrors the `inFlight` guard around `sendCmd` in
    /// app/page.tsx, which exists so a slow/hanging camera response doesn't pile up requests.
    func send(_ cmd: String, channel: String = "default", endpoint: String = "aw_ptz") {
        // Must be the first check — matches app/page.tsx's sendCmd, where the yielded check is
        // the first thing checked (after confirming a camera is selected at all), so yielding
        // suppresses every outgoing command unconditionally, not just pan/tilt.
        guard !isYielded else { return }
        guard !settings.ip.isEmpty else { return }
        guard !inFlight.contains(channel) else { return }
        inFlight.insert(channel)
        lastCommand = cmd

        let urlString = "http://\(settings.ip):\(settings.port)/cgi-bin/\(endpoint)"
            + "?cmd=\(cmd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cmd)&res=1"
        guard let url = URL(string: urlString) else {
            inFlight.remove(channel)
            return
        }

        let task = session.dataTask(with: url) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(channel)
                if let error {
                    self.lastResponse = "Network error: \(error.localizedDescription)"
                    self.isConnected = false
                    return
                }
                self.isConnected = (response as? HTTPURLResponse)?.statusCode == 200
                if let data, let text = String(data: data, encoding: .utf8) {
                    self.lastResponse = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    self.lastResponse = "ok"
                }
            }
        }
        task.resume()
    }

    /// Sends the pan/tilt stop command immediately — used when the controller disconnects or
    /// sticks return to center, so the camera doesn't keep drifting.
    func stopPanTilt() {
        send(PTZCommands.stopCmd, channel: "pt")
    }
}

/// Persisted camera connection settings (IP + port). Loaded from / saved to UserDefaults.
/// The TS version keeps a full multi-camera list in localStorage (`lib/mapping.ts`-adjacent
/// `ptz-cameras` key) — this milestone only needs one camera, so this is intentionally the
/// minimal single-camera subset of that shape.
struct CameraSettings: Codable, Equatable {
    var ip: String = ""
    var port: Int = 80

    private static let defaultsKey = "com.hotshotbot.cameraSettings"

    static func load() -> CameraSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(CameraSettings.self, from: data)
        else { return CameraSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Default MJPEG stream URL for this camera, matching `STREAM_PATHS["aw-ue70"]` in
    /// lib/ptz.ts (shared default across AW-UE70/UE160/HE130 in the TS version).
    var streamURL: URL? {
        guard !ip.isEmpty else { return nil }
        return URL(string: "http://\(ip):\(port)/cgi-bin/mjpeg?resolution=1920x1080&quality=4&framerate=30")
    }
}
