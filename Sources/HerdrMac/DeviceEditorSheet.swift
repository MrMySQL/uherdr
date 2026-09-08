import SwiftUI
import HerdrCore

struct DeviceEditorSheet: View {
    let target: DeviceEditorTarget
    @ObservedObject var devices: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: DeviceProfile

    init(target: DeviceEditorTarget, devices: DeviceStore) {
        self.target = target; self.devices = devices
        _profile = State(initialValue: target.profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(target.isNew ? "Add a device" : "Edit device").font(.system(size: 22, weight: .semibold))
            Form {
                TextField("Name", text: $profile.name)
                if profile.kind == .ssh {
                    TextField("SSH host", text: $profile.host, prompt: Text("alex@mac-mini.local or SSH alias"))
                    TextField("Username", text: $profile.user, prompt: Text("From host or SSH config"))
                    TextField("Port", text: $profile.port, prompt: Text("From SSH config, otherwise 22"))
                    TextField("Identity file", text: $profile.identityFile, prompt: Text("Optional local key path"))
                    TextField("Remote socket", text: $profile.socketPath, prompt: Text("Automatic"))
                } else {
                    TextField("Socket path", text: $profile.socketPath)
                }
                TextField("Local herdr executable", text: $profile.executable)
            }.textFieldStyle(.roundedBorder)
            if profile.kind == .ssh {
                Text("Uses your SSH keys, agent, and ~/.ssh/config. Enable Remote Login on the other Mac and connect with SSH once in Terminal to verify its host key. Password-only login is not supported here.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Start herdr on the other device first. Leave Remote socket empty for its default session, or enter ~/.config/herdr/sessions/<name>/herdr.sock for a named session. A compatible herdr CLI is also needed on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = normalized.validationError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save and connect") { devices.save(normalized); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(normalized.validationError != nil)
            }
        }.padding(28).frame(width: 540)
    }

    private var normalized: DeviceProfile {
        var copy = profile
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = copy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.user = copy.user.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.port = copy.port.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.identityFile = copy.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.socketPath = copy.socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.executable = copy.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}
