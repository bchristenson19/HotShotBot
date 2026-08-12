import Foundation

/// Sends Panasonic CGI commands to a camera over HTTP, throttled to avoid flooding it with
/// duplicate commands on every controller poll tick.
///
/// Ports the request shape used by `app/api/camera/route.ts` (the Next.js proxy the Electron
/// app talks to) directly against the camera — this native app has no CORS restriction so it
/// skips the proxy layer entirely and hits the camera straight from `URLSession`.
@MainActor
final class CameraClient: ObservableObject {

    /// The camera being controlled. Empty `ip` means "not configured". One `CameraClient` per
    /// `CameraSession` — see that file.
    @Published var camera: Camera

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
    ///
    /// Defaults to `true` (a deliberate deviation from app/page.tsx's default-unyielded state):
    /// on a fresh launch, no camera should move until the operator explicitly takes control,
    /// rather than a stray gamepad touch immediately driving whatever camera happens to be
    /// active. `CameraSessionStore.setActive` un-yields whichever camera becomes active and
    /// yields whichever stops being active, so this default only really matters for however long
    /// it takes the operator to press the yield button (Triangle by default) or switch cameras.
    @Published private(set) var isYielded = true

    func toggleYield() {
        setYielded(!isYielded)
    }

    func setYielded(_ yielded: Bool) {
        isYielded = yielded
    }

    /// Minimum spacing between sent PTZ commands on a given channel, matching `CMD_INTERVAL_MS`
    /// in `app/page.tsx` (66ms) — the gamepad is polled at ~60Hz but the camera shouldn't be
    /// hit that often.
    static let commandIntervalMs: UInt64 = 66

    private var lastSentAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession

    init(camera: Camera) {
        self.camera = camera
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
        guard !camera.ip.isEmpty else { return }
        guard !inFlight.contains(channel) else { return }
        inFlight.insert(channel)
        lastCommand = cmd

        let urlString = "http://\(camera.ip):\(camera.port)/cgi-bin/\(endpoint)"
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
