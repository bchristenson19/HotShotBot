import SwiftUI

/// Camera list editor — add/edit/remove cameras, replacing the milestone-1 single IP/port
/// fields now that `CameraSessionStore` supports more than one. Structurally similar to the TS
/// app's `CameraConfig.tsx`. A camera-kind picker chooses between a real networked Panasonic
/// camera and the in-app virtual camera (which needs no IP/port).
struct SettingsView: View {
    @ObservedObject var sessionStore: CameraSessionStore
    @Binding var isPresented: Bool

    @State private var editingCameraID: Camera.ID?
    @State private var nameText = ""
    @State private var ipText = ""
    @State private var portText = ""
    @State private var kindSelection: CameraKind = .panasonic

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Cameras").font(.title2).bold()
                Spacer()
                Button {
                    resetForm()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Add another camera")
            }

            List(sessionStore.sessions) { session in
                HStack {
                    Circle().fill(Color(hex: session.camera.colorHex)).frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(session.camera.name).font(.body)
                        Text(subtitle(for: session.camera))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { beginEditing(session.camera) }
                        .buttonStyle(.plain).font(.caption)
                    Button("Remove") { sessionStore.removeCamera(id: session.id) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(minHeight: 160)

            Divider()

            Text(editingCameraID == nil ? "Add Camera" : "Edit Camera").font(.headline)
            Form {
                TextField("Name", text: $nameText, prompt: Text("Camera 1"))
                Picker("Type", selection: $kindSelection) {
                    Text("Panasonic").tag(CameraKind.panasonic)
                    Text("Virtual").tag(CameraKind.virtual)
                }
                // Kind is fixed once a camera exists — the live session's client/renderer are
                // wired for one kind at construction, so switching would require rebuilding the
                // session. Add a new camera of the other kind instead.
                .disabled(editingCameraID != nil)
                if kindSelection == .panasonic {
                    TextField("Camera IP address", text: $ipText, prompt: Text("192.168.1.50"))
                    TextField("Port", text: $portText, prompt: Text("80"))
                } else {
                    Text("A simulated 3D camera — no network hardware needed. Drives the same "
                        + "gamepad, PTZ, and AI-tracking pipeline against a rendered scene.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                if editingCameraID != nil {
                    Button("Cancel Edit") { resetForm() }
                }
                Spacer()
                Button(editingCameraID == nil ? "Add" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("Panasonic AW-UE70 / AW-UE160 / AW-HE130 on the local network. Commands go to "
                + "/cgi-bin/aw_ptz, the live feed comes from /cgi-bin/mjpeg.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 560)
        .onAppear {
            // Preserves milestone-1's UX for the common single-camera case: the form starts
            // pre-populated for editing the one existing camera, rather than defaulting to "Add"
            // and leaving a redundant blank entry behind. Once there are 2+ cameras, "Add" is the
            // more useful default.
            if sessionStore.sessions.count == 1, editingCameraID == nil {
                beginEditing(sessionStore.sessions[0].camera)
            }
        }
    }

    private func subtitle(for camera: Camera) -> String {
        if camera.isVirtual { return "Virtual camera" }
        return camera.ip.isEmpty ? "No IP set" : "\(camera.ip):\(camera.port)"
    }

    private func beginEditing(_ camera: Camera) {
        editingCameraID = camera.id
        nameText = camera.name
        ipText = camera.ip
        portText = String(camera.port)
        kindSelection = camera.kind
    }

    private func resetForm() {
        editingCameraID = nil
        nameText = ""
        ipText = ""
        portText = ""
        kindSelection = .panasonic
    }

    private func commit() {
        let ip = ipText.trimmingCharacters(in: .whitespaces)
        let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 80
        let name = nameText.trimmingCharacters(in: .whitespaces)

        if let id = editingCameraID, let existing = sessionStore.sessions.first(where: { $0.id == id }) {
            var updated = existing.camera
            updated.name = name.isEmpty ? existing.camera.name : name
            updated.ip = ip
            updated.port = port
            sessionStore.applyEdits(id: id, updated)
        } else {
            let defaultName = kindSelection == .virtual ? "Virtual Camera" : "Camera \(sessionStore.sessions.count + 1)"
            let newCamera = Camera(
                name: name.isEmpty ? defaultName : name,
                ip: kindSelection == .virtual ? "" : ip,
                port: port,
                colorHex: defaultCameraColor(at: sessionStore.sessions.count),
                kind: kindSelection
            )
            sessionStore.addCamera(newCamera)
        }
        resetForm()
    }
}
