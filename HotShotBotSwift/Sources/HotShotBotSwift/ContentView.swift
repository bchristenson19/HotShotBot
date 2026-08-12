import SwiftUI

/// Main window: a Single/Grid toggle switches between the milestone-1-style single active-camera
/// feed and a multiview grid of every configured camera. Camera settings sheet and controller
/// remap sheet are app-level, not per-camera, so they live here rather than in `ActiveCameraView`.
struct ContentView: View {
    @ObservedObject var gamepad: GamepadInput
    @ObservedObject var sessionStore: CameraSessionStore
    @ObservedObject var controlLoop: PTZControlLoop

    @State private var showSettings = false
    @State private var showRemap = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sessionStore.isGridMode {
                CameraGridView(sessionStore: sessionStore)
            } else if let session = sessionStore.activeSession {
                // .id(session.id) forces SwiftUI to treat this as a fresh view when the active
                // camera changes, rather than trying to reuse the previous one's identity.
                ActiveCameraView(gamepad: gamepad, session: session, controlLoop: controlLoop)
                    .id(session.id)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .sheet(isPresented: $showSettings) {
            SettingsView(sessionStore: sessionStore, isPresented: $showSettings)
        }
        .sheet(isPresented: $showRemap) {
            RemapView(mapping: controlLoop.mapping, isPresented: $showRemap) { updated in
                controlLoop.mapping = updated
                updated.save()
            }
        }
        .onAppear {
            // See HotShotBotSwiftApp.init() — this executable has no app bundle, so launching
            // from a terminal leaves keyboard focus on whatever was frontmost before (e.g.
            // Terminal itself) even though the window is visible. Activating here, after the
            // window has actually appeared, reliably steals focus; doing it in App.init() was
            // too early and got silently dropped.
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)

            // CameraSessionStore starts every session's stream itself at construction time, so
            // there's nothing to start here — just decide whether Settings needs to pop up
            // because the active camera has no IP configured yet.
            if sessionStore.activeSession?.camera.ip.isEmpty ?? true {
                showSettings = true
            }
        }
    }

    private var header: some View {
        HStack {
            if let session = sessionStore.activeSession {
                Circle().fill(Color(hex: session.camera.colorHex)).frame(width: 8, height: 8)
                Label(
                    session.camera.ip.isEmpty
                        ? session.camera.name
                        : "\(session.camera.name) — \(session.camera.ip):\(session.camera.port)",
                    systemImage: "video.fill"
                )
                .font(.headline)
            } else {
                Label("No camera configured", systemImage: "video.fill").font(.headline)
            }

            Spacer()

            if sessionStore.sessions.count > 1 {
                Picker("", selection: $sessionStore.isGridMode) {
                    Text("Single").tag(false)
                    Text("Grid").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
            }

            statusBadge(
                label: "Controller",
                connected: gamepad.state.connected,
                waiting: gamepad.waitingForPress
            )

            Button {
                showRemap = true
            } label: {
                Image(systemName: "gamecontroller")
            }
            .buttonStyle(.plain)
            .help("Remap controller")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Camera settings")
        }
        .padding()
    }

    private func statusBadge(label: String, connected: Bool, waiting: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connected ? Color.green : (waiting ? Color.yellow : Color.red))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No camera configured — add one in Settings.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The single-camera feed + status + debug panel for whichever camera is currently active.
/// Holds direct `@ObservedObject` references to the session's OWN `client`/`decoder` (not just
/// the session itself) so this view actually resubscribes to their published changes (frames,
/// CMD/RES, connection state) — merely observing `CameraSession` wouldn't do that, since nested
/// `ObservableObject`s don't forward change notifications to a parent's observers automatically.
private struct ActiveCameraView: View {
    @ObservedObject var gamepad: GamepadInput
    @ObservedObject var session: CameraSession
    @ObservedObject var client: CameraClient
    @ObservedObject var stream: MJPEGStreamDecoder
    @ObservedObject var tracker: PersonTrackerSession
    @ObservedObject var controlLoop: PTZControlLoop

    init(gamepad: GamepadInput, session: CameraSession, controlLoop: PTZControlLoop) {
        self.gamepad = gamepad
        self.session = session
        self.client = session.client
        self.stream = session.decoder
        self.tracker = session.tracker
        self.controlLoop = controlLoop
    }

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            Divider()
            feedArea
            Divider()
            debugPanel
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            statusBadge(label: "Stream", connected: stream.status == .streaming, waiting: stream.status == .connecting)

            Text(session.autoFocus ? "AF" : "MF")
                .font(.caption2).bold()
                .foregroundStyle(session.autoFocus ? .green : .secondary)

            if client.isYielded {
                Text("Yielded")
                    .font(.caption).bold()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.25))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }

            Spacer()

            Button(tracker.isEnabled ? "Tracking On" : "Track") {
                tracker.isEnabled.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tracker.isEnabled ? Color.green.opacity(0.25) : Color.gray.opacity(0.2))
            .foregroundStyle(tracker.isEnabled ? .green : .secondary)
            .clipShape(Capsule())
            .disabled(client.isYielded)
            .help(client.isYielded ? "Un-yield to track" : "Click-to-track mode")

            if tracker.isEnabled {
                Picker("", selection: $tracker.shotPreset) {
                    Text("Free").tag(ShotPreset.none)
                    Text("Mid").tag(ShotPreset.mid)
                    Text("Full").tag(ShotPreset.full)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)

                Text(tracker.trackingState.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func statusBadge(label: String, connected: Bool, waiting: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connected ? Color.green : (waiting ? Color.yellow : Color.red))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var feedArea: some View {
        ZStack {
            Color.black
            if let frame = stream.currentFrame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                if tracker.isEnabled {
                    TrackingOverlayView(
                        detections: tracker.detections,
                        lockedBox: tracker.lockedBox,
                        imageSize: frame.size,
                        onTapDetection: { tracker.lock($0) },
                        onTapEmpty: { tracker.clearLock() }
                    )
                }
            } else {
                VStack(spacing: 8) {
                    switch stream.status {
                    case .idle:
                        Text("No stream — set a camera IP in Settings")
                    case .connecting:
                        ProgressView()
                        Text("Connecting to camera…")
                    case .error(let message):
                        Text("Stream error: \(message)")
                    case .streaming:
                        Text("Waiting for first frame…")
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(minHeight: 360)
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Debug")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            HStack {
                Text("CMD:").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(client.lastCommand.isEmpty ? "—" : client.lastCommand)
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text("RES:").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(client.lastResponse.isEmpty ? "—" : client.lastResponse)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 16) {
                Text(String(format: "L: %.2f, %.2f", gamepad.state.leftX, gamepad.state.leftY))
                Text(String(format: "R: %.2f, %.2f", gamepad.state.rightX, gamepad.state.rightY))
                Text(String(format: "L2/R2: %.2f / %.2f", gamepad.state.l2, gamepad.state.r2))
                Text("Frames: \(stream.frameCount)")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
