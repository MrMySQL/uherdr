import SwiftUI
import AppKit
import HerdrCore

/// Every shortcut uHerdr has, grouped as in the menus, with search.
/// Clicking a shortcut records a new one; clashes and keys the terminal
/// needs are confirmed inline before anything changes.
struct KeyboardShortcutsSheet: View {
    private struct Pending: Equatable {
        let action: ShortcutAction
        let chord: KeyChord
        var step: ShortcutChangeStep
        var clashAccepted = false
        /// Row actions a Reset still puts back once this one is replaced.
        var resetAfter: [ShortcutAction] = []
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = ShortcutSettings.shared
    @State private var search = ""
    @State private var recording: ShortcutAction?
    /// Why the last key press was not taken, shown while recording.
    @State private var rejection: String?
    @State private var pending: Pending?
    @State private var keyMonitor: Any?

    private var bindings: ShortcutBindings { settings.bindings }
    private var groups: [ShortcutGroup] { ShortcutGroup.filtered(search) { bindings.chord(for: $0) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.system(size: 17, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search shortcuts", text: $search).textFieldStyle(.plain)
                }
                .font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 6).frame(width: 260)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            ScrollView {
                if groups.isEmpty {
                    Text("No shortcut matches “\(search)”.").foregroundStyle(.secondary).padding(40)
                } else {
                    HStack(alignment: .top, spacing: 40) {
                        column(groups.filter { ["Spaces", "Tabs", "Panes"].contains($0.title) })
                        column(groups.filter { !["Spaces", "Tabs", "Panes"].contains($0.title) })
                    }
                    .padding(24)
                }
            }
            Divider()
            HStack {
                Text(footer).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset all") { cancelEditing(); settings.update { $0.resetAll() } }
                    .disabled(bindings.changedCount == 0)
                Button("Done") { cancelEditing(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 860, height: 680)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    private var footer: String {
        if recording != nil { return rejection ?? "Press the new shortcut, or Esc to cancel." }
        if let pending {
            switch pending.step {
            case .clash: return "Choose Replace or Cancel to continue."
            case .terminalReserved: return "Choose Use Anyway or Cancel to continue."
            default: break
            }
        }
        switch bindings.changedCount {
        case 0: return "Click a shortcut to change it."
        case 1: return "1 shortcut changed."
        case let count: return "\(count) shortcuts changed."
        }
    }

    private func column(_ groups: [ShortcutGroup]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
                    ForEach(group.rows) { row in
                        rowView(row)
                        if let pending, row.actions.contains(pending.action) { panel(pending) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rowView(_ row: ShortcutRow) -> some View {
        let changed = row.actions.contains(where: bindings.isChanged)
        let active = row.actions.contains { $0 == recording || $0 == pending?.action }
        return HStack(spacing: 6) {
            Text(row.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if changed && !active {
                Text("Changed").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                Button("Reset") { reset(row) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("Put back the original shortcut")
            }
            ForEach(Array(row.actions.enumerated()), id: \.offset) { index, action in
                if index > 0 { Text("/").font(.system(size: 11)).foregroundStyle(.tertiary) }
                keycaps(for: action)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(active ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func keycaps(for action: ShortcutAction) -> some View {
        if recording == action {
            Keycap(text: "Press new shortcut…", highlighted: true)
        } else if let pending, pending.action == action {
            ForEach(Array(action.keycaps(for: pending.chord).enumerated()), id: \.offset) { _, cap in Keycap(text: cap, highlighted: true) }
        } else {
            Button { startRecording(action) } label: {
                HStack(spacing: 4) {
                    if let chord = bindings.chord(for: action) {
                        let caps = action.keycaps(for: chord)
                        ForEach(Array(caps.enumerated()), id: \.offset) { index, cap in
                            if index > 0 { Text("·").font(.system(size: 11)).foregroundStyle(.tertiary) }
                            Keycap(text: cap, highlighted: bindings.isChanged(action))
                        }
                    } else {
                        Keycap(text: "None", highlighted: true)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Click, then press the new shortcut for \(action.title)")
            .accessibilityLabel("\(action.title): \(bindings.chord(for: action).map { action.keycaps(for: $0).joined(separator: ", ") } ?? "no shortcut")")
        }
    }

    @ViewBuilder private func panel(_ pending: Pending) -> some View {
        let keys = pending.action.keycaps(for: pending.chord).joined(separator: " · ")
        VStack(alignment: .leading, spacing: 6) {
            switch pending.step {
            case .clash(let others):
                let quoted = ListFormatter.localizedString(byJoining: others.map { "“\($0.title)”" })
                let names = ListFormatter.localizedString(byJoining: others.map(\.title))
                Label("\(keys) is already used by \(quoted).", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                Text("Replace gives \(keys) to \(pending.action.title) and leaves \(names) without a shortcut. Cancel keeps \(others.count == 1 ? "both" : "all") as they were.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Cancel") { self.pending = nil }; Button("Replace") { advance(clashAccepted: true) }.buttonStyle(.borderedProminent) }
            case .terminalReserved:
                Label("\(keys) won’t reach the terminal any more.", systemImage: "apple.terminal")
                    .font(.system(size: 12, weight: .semibold))
                Text("Terminal programs rely on ⌃ with a letter: ⌃C interrupts, ⌃D ends input. If \(pending.action.title) takes \(keys), uHerdr handles it first in every pane.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Cancel") { self.pending = nil }; Button("Use Anyway") { advance(terminalAccepted: true) }.buttonStyle(.borderedProminent) }
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.45)))
        .padding(.vertical, 4)
    }

    // MARK: Editing

    private func startRecording(_ action: ShortcutAction) {
        pending = nil
        rejection = nil
        recording = action
    }

    private func cancelEditing() {
        recording = nil
        pending = nil
        rejection = nil
    }

    private func reset(_ row: ShortcutRow) {
        cancelEditing()
        reset(row.actions)
    }

    /// Resets what it can and asks about the first clash; Replace resumes with the rest.
    private func reset(_ actions: [ShortcutAction]) {
        var stop: (action: ShortcutAction, rest: [ShortcutAction])?
        settings.update { stop = $0.reset(actions) }
        guard let stop else { return }
        propose(stop.action.defaultChord, for: stop.action)
        pending?.resetAfter = stop.rest
    }

    private func propose(_ chord: KeyChord, for action: ShortcutAction) {
        let step = ShortcutChangeStep.next(for: chord, action: action, in: bindings)
        switch step {
        case .invalid:
            rejection = "Use ⌘, ⌃ or ⌥ with a key."
            recording = action
        case .apply:
            settings.update { $0.assign(chord, to: action) }
        case .clash, .terminalReserved:
            pending = Pending(action: action, chord: chord, step: step)
        }
    }

    private func advance(clashAccepted: Bool = false, terminalAccepted: Bool = false) {
        guard var current = pending else { return }
        current.clashAccepted = current.clashAccepted || clashAccepted
        let step = ShortcutChangeStep.next(for: current.chord, action: current.action, in: bindings,
                                           clashAccepted: current.clashAccepted, terminalAccepted: terminalAccepted)
        if step == .apply {
            pending = nil
            settings.update { $0.assign(current.chord, to: current.action) }
            reset(current.resetAfter)
        } else {
            current.step = step
            pending = current
        }
    }

    /// While recording, the next key press is the new shortcut; menus never see it.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = recording else { return event }
            if event.keyCode == 53 {
                cancelEditing()
                return nil
            }
            guard let chord = KeyChord(event: event) else {
                rejection = "That key can’t be a shortcut. Use a letter, digit, symbol, Return or Tab."
                return nil
            }
            recording = nil
            rejection = nil
            propose(chord, for: action)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct Keycap: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(highlighted ? Color.accentColor : .primary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(highlighted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.15)))
    }
}
