import Foundation

/// Owns every configured camera's `CameraSession` and which one is currently "active" (i.e.
/// receiving gamepad-driven commands via `PTZControlLoop`) — replaces the milestone-1 app's
/// single global `CameraClient`/`CameraSettings`/`MJPEGStreamDecoder` trio. Mirrors the
/// `Camera[]` + `activeCamIndex` shape of app/page.tsx, but keys the active camera by a stable
/// `Camera.id` (`UUID`) rather than an array index — reordering or removing an earlier camera
/// can't silently retarget the gamepad at the wrong one the way an index-based scheme could.
@MainActor
final class CameraSessionStore: ObservableObject {
    @Published private(set) var sessions: [CameraSession] = []
    @Published private(set) var activeCameraID: Camera.ID?

    /// Single/Grid view mode — lives here rather than as `ContentView`'s own local `@State` so
    /// `PTZControlLoop` can flip it directly from a remappable button press (`.toggleGridView`),
    /// the same way it already reads/writes everything else camera-related through this store.
    @Published var isGridMode = false

    var activeSession: CameraSession? {
        sessions.first { $0.id == activeCameraID } ?? sessions.first
    }

    init(cameras: [Camera]) {
        sessions = cameras.map { CameraSession(camera: $0) }
        activeCameraID = sessions.first?.id
        for session in sessions { session.start() }
    }

    func addCamera(_ camera: Camera) {
        let session = CameraSession(camera: camera)
        sessions.append(session)
        session.start()
        if activeCameraID == nil { activeCameraID = session.id }
        persist()
    }

    func removeCamera(id: Camera.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if activeCameraID == id { stopOutgoingCamera() }
        sessions[index].teardown()
        sessions.remove(at: index)
        if activeCameraID == id { activeCameraID = sessions.first?.id }
        persist()
    }

    func applyEdits(id: Camera.ID, _ updated: Camera) {
        sessions.first { $0.id == id }?.applyEdits(updated)
        persist()
    }

    /// Switches which camera is gamepad-active — and, since only one camera can be driven at a
    /// time, keeps yield state in lockstep: the incoming camera is un-yielded (it's the one about
    /// to be driven) and the outgoing one is yielded (most visible in multiview, where the other
    /// tiles keep streaming but aren't being steered — they should read as handed off, not as
    /// silently-still-under-HotShotBot-control). Mirrors the light bar's own active-camera-only
    /// signal — see `PTZControlLoop.updateLightBar`.
    func setActive(id: Camera.ID) {
        guard id != activeCameraID else { return }
        stopOutgoingCamera()
        activeSession?.client.setYielded(true)
        sessions.first { $0.id == id }?.client.setYielded(false)
        activeCameraID = id
    }

    /// Real implementation of the `cycleCamera` button action — `PTZControlLoop` previously kept
    /// this as a deliberate no-op since the app was single-camera only.
    func cycleActive() {
        guard !sessions.isEmpty else { return }
        let currentIndex = sessions.firstIndex { $0.id == activeCameraID } ?? 0
        setActive(id: sessions[(currentIndex + 1) % sessions.count].id)
    }

    /// Safety fix vs. the Electron reference: `app/page.tsx`'s `setActiveCamIndex` call sites
    /// (the cycleCamera action, sidebar/tab clicks) have no adjacent stop-command dispatch — if
    /// the outgoing camera was mid-pan when you switch away, a real Panasonic PTZ camera has no
    /// client-side watchdog and keeps physically moving until *some* command reaches it again,
    /// which may never happen once the gamepad loop retargets the new active camera. Send an
    /// explicit stop + zero the outgoing session's velocities on every active-camera change.
    private func stopOutgoingCamera() {
        guard let old = activeSession else { return }
        old.stopPanTilt()
        old.client.send(PTZCommands.axisToZoomCmd(0), channel: "zoom")
        old.zoomVelocity = 0
    }

    func persist() {
        let cameras = sessions.map(\.camera)
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static let defaultsKey = "com.hotshotbot.cameras"
    private static let legacyDefaultsKey = "com.hotshotbot.cameraSettings"

    /// Loads the persisted camera list, migrating the milestone-1 single-camera key if this is
    /// the first launch after upgrading (so an existing user's configured IP isn't lost), or
    /// falling back to one blank default camera if neither key has anything yet.
    static func loadCameras() -> [Camera] {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Camera].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        if let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let legacy = try? JSONDecoder().decode(LegacyCameraSettings.self, from: data),
           !legacy.ip.isEmpty {
            return [Camera(name: "Camera 1", ip: legacy.ip, port: legacy.port, colorHex: defaultCameraColor(at: 0))]
        }
        return [Camera(name: "Camera 1", colorHex: defaultCameraColor(at: 0))]
    }
}

/// Minimal shape of the retired milestone-1 `CameraSettings`, kept only so `loadCameras()` can
/// migrate an existing single-camera install's saved IP/port into the new `[Camera]` list.
/// Internal rather than private so `CameraTests.swift` can verify its decoding directly.
struct LegacyCameraSettings: Codable {
    var ip: String = ""
    var port: Int = 80
}
