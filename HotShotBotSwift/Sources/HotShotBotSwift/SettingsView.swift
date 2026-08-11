import SwiftUI

/// Minimal camera connection settings sheet — just IP/port entry, persisted via
/// `CameraSettings.save()` (UserDefaults). No camera list/multi-camera management yet; that's
/// out of scope for this milestone (see `lib/mapping.ts`/`CameraConfig.tsx` in the TS version
/// for what that eventually grows into).
struct SettingsView: View {
    @ObservedObject var client: CameraClient
    @ObservedObject var stream: MJPEGStreamDecoder
    @Binding var isPresented: Bool

    @State private var ipText: String = ""
    @State private var portText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Camera Settings")
                .font(.title2).bold()

            Form {
                TextField("Camera IP address", text: $ipText, prompt: Text("192.168.1.50"))
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $portText, prompt: Text("80"))
                    .textFieldStyle(.roundedBorder)
            }

            Text("Panasonic AW-UE70 / AW-UE160 / AW-HE130 on the local network. Commands go to "
                + "/cgi-bin/aw_ptz, the live feed comes from /cgi-bin/mjpeg.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Save & Connect") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            ipText = client.settings.ip
            portText = String(client.settings.port)
        }
    }

    private func save() {
        var settings = client.settings
        settings.ip = ipText.trimmingCharacters(in: .whitespaces)
        settings.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 80
        settings.save()
        client.settings = settings
        isPresented = false

        if let url = settings.streamURL {
            stream.start(url: url)
        } else {
            stream.stop()
        }
    }
}
