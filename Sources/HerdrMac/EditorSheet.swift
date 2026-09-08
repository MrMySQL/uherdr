import SwiftUI

struct EditorSheet: View {
    let sheet: AppSheet
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var cwd = NSHomeDirectory()
    @State private var kind = "claude"
    @FocusState private var fieldFocused: Bool
    private var title: String {
        switch sheet {
        case .space: return "Create a space"
        case .tab: return "Create a tab"
        case .rename(let target): return "Rename \(target.singular)"
        case .agent: return "Start an agent"
        case .settings: return "Settings"
        }
    }
    private var valid: Bool {
        switch sheet {
        case .settings: return true
        case .space:
            let path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let validPath = store.isRemote ? path.hasPrefix("/") : FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
            return !label.trimmingCharacters(in: .whitespaces).isEmpty && validPath
        case .agent: return label.range(of: #"^[a-z][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
        default: return !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title).font(.system(size: 21, weight: .semibold))
            switch sheet {
            case .settings: settingsFields
            case .agent: agentFields
            default:
                VStack(alignment: .leading, spacing: 7) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $label).textFieldStyle(.roundedBorder).focused($fieldFocused)
                }
                if case .space = sheet {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Project folder").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("Folder", text: $cwd).textFieldStyle(.roundedBorder)
                            if !store.isRemote { Button("Choose…") { chooseFolder() } }
                        }
                        Text(store.isRemote ? "Enter the full folder path on \(store.profile.name)." : "Each space keeps its own tabs, terminals, and agents.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(buttonTitle) { submit() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!valid)
            }
        }
        .padding(28).frame(width: 480)
        .onAppear {
            if case .rename(let target) = sheet { label = target.label }
            if case .tab = sheet { label = "Terminal" }
            if case .agent = sheet { label = "agent-\(Int.random(in: 100...999))" }
            cwd = store.currentPane?.directory.isEmpty == false ? store.currentPane!.directory : store.defaultDirectory
            fieldFocused = true
        }
    }
    private var buttonTitle: String {
        switch sheet { case .settings: return "Done"; case .rename: return "Rename"; case .agent: return "Start agent"; default: return "Create" }
    }
    private var agentFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The agent starts in a new Git worktree and opens in its own space.").font(.callout).foregroundStyle(.secondary)
            Picker("Agent", selection: $kind) {
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex")
                Text("OpenCode").tag("opencode")
                Text("Gemini CLI").tag("gemini")
                Text("Pi").tag("pi")
                Text("Cursor").tag("cursor")
            }
            TextField("Agent name", text: $label).textFieldStyle(.roundedBorder).focused($fieldFocused)
            Text("Use a unique lowercase name. This pane’s folder must be in a Git repository. Install the selected agent CLI first.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var settingsFields: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Manage connections using the menu beside each device in the sidebar.").font(.callout).foregroundStyle(.secondary)
            Picker("Appearance", selection: $store.appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }.pickerStyle(.segmented)
            HStack {
                Text("Terminal text").font(.callout)
                Slider(value: $store.fontSize, in: 10...22, step: 1)
                Text("\(Int(store.fontSize)) pt").font(.system(size: 11, design: .monospaced)).frame(width: 38)
            }
            Text("Quitting detaches the client. Your herdr sessions continue running.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { cwd = url.path; if label.isEmpty { label = url.lastPathComponent } }
    }
    private func submit() {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sheet {
        case .space:
            let path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            store.createSpace(label: name, cwd: store.isRemote ? path : (path as NSString).expandingTildeInPath)
        case .tab: store.createTab(label: name)
        case .rename(let target): store.rename(target, label: name)
        case .agent(let paneID): store.startAgent(paneID: paneID, kind: kind, name: name)
        case .settings: break
        }
        dismiss()
    }
}
