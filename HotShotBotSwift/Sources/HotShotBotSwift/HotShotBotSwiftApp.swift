import SwiftUI

/// App entry point. Owns the long-lived pieces (gamepad polling, the multi-camera session
/// store) and wires them together with a `PTZControlLoop`, then hands them to `ContentView` for
/// display.
///
/// This is a Swift Package Manager executable target rather than a full Xcode app project (no
/// Info.plist/app bundle) — see HotShotBotSwift/README.md for why, and for the tradeoffs (no
/// Dock icon, no code signing, launches as a plain foreground process via `swift run`).
@main
struct HotShotBotSwiftApp: App {
    @StateObject private var gamepad: GamepadInput
    @StateObject private var sessionStore: CameraSessionStore
    @StateObject private var controlLoop: PTZControlLoop

    init() {
        let gamepad = GamepadInput()
        let sessionStore = CameraSessionStore(cameras: CameraSessionStore.loadCameras())
        _gamepad = StateObject(wrappedValue: gamepad)
        _sessionStore = StateObject(wrappedValue: sessionStore)
        // PTZControlLoop subscribes to gamepad.$state itself, so it needs the same instances
        // that get installed into the @StateObject wrappers above, not fresh ones.
        _controlLoop = StateObject(wrappedValue: PTZControlLoop(gamepad: gamepad, sessionStore: sessionStore, mapping: ControlMapping.load()))

        // With no Info.plist/app bundle (this is a bare SPM executable), launching from a
        // terminal doesn't make the app the frontmost/key-focused app the way double-clicking
        // a real .app would — the window can be visible on screen while keyboard input still
        // goes to whatever had focus before launch (e.g. Terminal), so text fields appear
        // unresponsive. setActivationPolicy alone (called here, before the run loop starts) is
        // necessary for the app to be activatable at all as a plain executable, but the actual
        // activate() call has to happen after launch finishes — see ContentView's .onAppear.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(gamepad: gamepad, sessionStore: sessionStore, controlLoop: controlLoop)
        }
        .windowResizability(.contentSize)
    }
}
