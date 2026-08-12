import SwiftUI

/// Grid of live tiles, one per configured camera — shown when the header's Single/Grid toggle
/// is set to Grid. Every tile decodes its own stream independently regardless of which camera is
/// active, so all feeds stay live simultaneously; a single tap makes a tile the gamepad-controlled
/// active camera without leaving the grid (still only one camera receives gamepad input at a time
/// — see `PTZControlLoop`/`CameraSessionStore.activeSession`), while a double tap does that AND
/// flips `sessionStore.isGridMode` back to Single, mirroring the "double-click to
/// focus" convention of hardware multiviewers. Neither the Electron app nor this one had a simultaneous multi-feed
/// view before this, so there's no prior layout to port here.
///
/// Tiles are sized from a `GeometryReader` read of the whole grid's available space rather than
/// SwiftUI's adaptive-column grid (which was sized to fit a scrolling handful of minimum-width
/// tiles, leaving most of the window as dead space below/beside them at typical camera counts) —
/// this computes a row/column split that actually fills the window, choosing whichever column
/// count renders the biggest 16:9 tiles for the current window shape and camera count.
struct CameraGridView: View {
    @ObservedObject var sessionStore: CameraSessionStore

    private let spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let count = sessionStore.sessions.count
            let columns = Self.bestColumnCount(
                for: count, containerWidth: geo.size.width, containerHeight: geo.size.height, spacing: spacing
            )
            let rows = columns > 0 ? Int(ceil(Double(count) / Double(columns))) : 0
            let cellWidth = columns > 0 ? (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns) : 0
            let cellHeight = rows > 0 ? (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows) : 0

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(columns, 1)),
                spacing: spacing
            ) {
                ForEach(sessionStore.sessions) { session in
                    CameraTileView(session: session, isActive: session.id == sessionStore.activeCameraID)
                        .frame(width: cellWidth, height: cellHeight)
                        // Stacking a count:2 gesture ahead of a count:1 on the same view is
                        // SwiftUI's standard disambiguation idiom — the single-tap handler only
                        // fires once the double-tap window has elapsed without a second tap.
                        .onTapGesture(count: 2) {
                            sessionStore.setActive(id: session.id)
                            sessionStore.isGridMode = false
                        }
                        .onTapGesture(count: 1) {
                            sessionStore.setActive(id: session.id)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }

    /// Picks the column count (1...count) whose resulting `columns × ceil(count/columns)` grid
    /// renders the largest 16:9 tile in `containerWidth × containerHeight` — e.g. 2 cameras in a
    /// wide window come out taller stacked in 1 column than side by side in 2, because a 16:9
    /// tile pillarboxes less in a wide-short cell than it letterboxes in a narrow-tall one.
    /// Brute-forced rather than derived from a formula since `count` is always small (number of
    /// configured cameras) and this only reruns when that count or the window size changes.
    static func bestColumnCount(for count: Int, containerWidth: CGFloat, containerHeight: CGFloat, spacing: CGFloat) -> Int {
        guard count > 0, containerWidth > 0, containerHeight > 0 else { return 0 }
        let aspect: CGFloat = 16.0 / 9.0
        var bestColumns = 1
        var bestTileHeight: CGFloat = -1
        for columns in 1...count {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let cellWidth = (containerWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (containerHeight - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            guard cellWidth > 0, cellHeight > 0 else { continue }
            let tileHeight = min(cellHeight, cellWidth / aspect)
            if tileHeight > bestTileHeight {
                bestTileHeight = tileHeight
                bestColumns = columns
            }
        }
        return bestColumns
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
                    .strokeBorder(isActive ? Color.red : Color.clear, lineWidth: 5)
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
