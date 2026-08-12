import SwiftUI

/// Grid of live tiles, one per configured camera — shown when the header's Single/Grid toggle
/// is set to Grid. Every tile decodes its own stream independently regardless of which camera is
/// active, so all feeds stay live simultaneously; tapping a tile makes it the gamepad-controlled
/// active camera (still only one camera receives gamepad input at a time — see
/// `PTZControlLoop`/`CameraSessionStore.activeSession`). Neither the Electron app nor this one
/// had a simultaneous multi-feed view before this, so there's no prior layout to port here.
struct CameraGridView: View {
    @ObservedObject var sessionStore: CameraSessionStore

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(sessionStore.sessions) { session in
                    CameraTileView(session: session, isActive: session.id == sessionStore.activeCameraID)
                        .onTapGesture { sessionStore.setActive(id: session.id) }
                }
            }
            .padding(8)
        }
        .background(Color.black.opacity(0.9))
    }
}

/// Holds a direct `@ObservedObject` reference to the session's own `decoder` (not just the
/// session) so this tile actually redraws as frames arrive — see `ActiveCameraView`'s doc
/// comment in ContentView.swift for why merely observing `CameraSession` wouldn't do that.
private struct CameraTileView: View {
    @ObservedObject var session: CameraSession
    @ObservedObject var stream: MJPEGStreamDecoder
    @ObservedObject var tracker: PersonTrackerSession
    let isActive: Bool

    init(session: CameraSession, isActive: Bool) {
        self.session = session
        self.stream = session.decoder
        self.tracker = session.tracker
        self.isActive = isActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black
                if let frame = stream.currentFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text(stream.status == .connecting ? "Connecting…" : "No stream")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            HStack {
                Circle().fill(Color(hex: session.camera.colorHex)).frame(width: 8, height: 8)
                Text(session.camera.name).font(.caption).bold()
                Spacer()
                Button {
                    tracker.isEnabled.toggle()
                } label: {
                    Image(systemName: tracker.isEnabled ? "figure.walk.circle.fill" : "figure.walk.circle")
                        .foregroundStyle(tracker.isEnabled ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(tracker.isEnabled ? "Tracking on — click to stop" : "Click to start tracking this camera")
                Circle()
                    .fill(stream.status == .streaming ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(6)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
