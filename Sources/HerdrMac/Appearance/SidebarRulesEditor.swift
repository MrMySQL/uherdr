import AppKit
import HerdrCore
import SwiftUI

struct SidebarRulesEditor: View {
    @ObservedObject var store: AppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = SidebarConfiguration()
    @State private var target = "spaces"
    @State private var agent = ""
    @State private var sample = "production"
    @State private var preview: [[SidebarTokenRun]] = []
    @State private var diagnostic: String?
    private var readOnly: Bool { store.themeSource == .herdrConfig }
    private var section: SidebarSection { (target == "agents" ? draft.agents : draft.spaces) ?? SidebarSection() }
    private var rows: [[SidebarOccurrence]]? { agent.isEmpty ? section.rows : section.rowsByAgent[agent] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sidebar rows and rules").font(.headline)
                Spacer()
                if readOnly { Button("Copy to native preset") { perform { try store.copySidebarToNative(); load() } } }
            }
            Text("Branch and Git status are unavailable in the public snapshot and are omitted. Tab labels use the available public label. Metadata appears when the server supplies it.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Rows", selection: $target) {
                Text("Spaces").tag("spaces"); Text("Agents").tag("agents")
            }.onChange(of: target) { _, _ in agent = ""; updatePreview() }
            if target == "agents" {
                Picker("Agent layout", selection: $agent) {
                    Text("All agents").tag("")
                    ForEach(SidebarConfiguration.canonicalAgents, id: \.self) { Text($0).tag($0) }
                }.onChange(of: agent) { _, _ in updatePreview() }
                Text("An agent layout completely replaces the common rows.").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                HStack {
                    Text(rows == nil ? (agent.isEmpty ? "Native default layout" : "Common agent layout") : "Custom layout")
                    Spacer()
                    Button("Use default") { setRows(nil) }.disabled(rows == nil)
                    Button("Add row") { var next = rows ?? []; next.append([SidebarOccurrence(token: target == "spaces" ? "workspace" : "agent")]); setRows(next) }
                        .disabled((rows?.count ?? 0) >= 16)
                }
                HStack {
                    Text("Row gap")
                    TextField("Row gap (0–65535)", value: Binding(get: { Int(section.rowGap) }, set: { value in
                        guard let value = UInt16(exactly: value) else { return }; var next = section; next.rowGap = value; setSection(next)
                    }), format: .number)
                        .accessibilityLabel("Row gap (0–65535)")
                }
                ForEach((rows ?? []).indices, id: \.self) { index in rowEditor(index) }
                Button("Save native sidebar") { perform { try store.setNativeSidebar(draft); load() } }
            }.disabled(readOnly)
            if readOnly { Text("Imported layouts and rules are read-only.").font(.caption) }
            if let diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.red) }
            Divider()
            TextField("Preview token value", text: $sample).onChange(of: sample) { _, _ in updatePreview() }
            SidebarRowView(rows: preview, rowGap: section.rowGap)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if !previewContrastWarnings.isEmpty {
                Label("Low contrast sidebar preview (below 4.5:1): " + previewContrastWarnings.joined(separator: ", ") + ". Colors are kept as chosen.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            Text("Preview applies the sample to every text token before truncation. Save applies valid edits to all devices.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
        .onChange(of: store.themeSource) { _, _ in load() }
        .onChange(of: store.sidebarConfiguration) { _, _ in load() }
    }

    private var previewContrastWarnings: [String] {
        let palette = NativePalette(snapshot: store.resolvedSnapshot, colorScheme: colorScheme)
        let scheme: ColorScheme = store.mode == .system ? colorScheme : (store.mode == .dark ? .dark : .light)
        return Array(Set(preview.flatMap { $0 }.compactMap { run -> String? in
            guard case .rgb(let r, let g, let b) = run.style.foreground else { return nil }
            let foreground = NSColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255,
                                     alpha: run.style.dim == true ? 0.55 : 1)
            let low = ["sidebar_bg", "active_row"].contains {
                NativePalette.contrastRatio(foreground: foreground, background: palette.nsColor($0), colorScheme: scheme) < 4.5
            }
            return low ? run.token : nil
        })).sorted()
    }

    private func rowEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Row \(index + 1)").font(.subheadline.bold())
                Spacer()
                Button("↑") { var next = rows!; next.swapAt(index, index - 1); setRows(next) }.disabled(index == 0).help("Move row up")
                Button("↓") { var next = rows!; next.swapAt(index, index + 1); setRows(next) }.disabled(index + 1 == rows!.count).help("Move row down")
                Button("Remove row") { var next = rows!; next.remove(at: index); setRows(next) }
                Button("Add token") { var next = rows!; next[index].append(.init(token: "workspace")); setRows(next) }.disabled(rows![index].count >= 16)
            }
            ForEach(rows![index].indices, id: \.self) { token in occurrenceEditor(index, token) }
        }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func occurrenceEditor(_ row: Int, _ index: Int) -> some View {
        let occurrence = rows![row][index]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Token or $metadata", text: Binding(get: { rows![row][index].token }, set: { text in edit(row, index) { $0.token = text } }))
                Menu("Built-in") {
                    ForEach(target == "agents" ? SidebarConfiguration.agentTokens : SidebarConfiguration.spaceTokens, id: \.self) { token in
                        Button(token) { edit(row, index) { $0.token = token } }
                    }
                }.fixedSize()
                Button("↑") { var next = rows!; next[row].swapAt(index, index - 1); setRows(next) }.disabled(index == 0).help("Move token earlier")
                Button("↓") { var next = rows!; next[row].swapAt(index, index + 1); setRows(next) }.disabled(index + 1 == rows![row].count).help("Move token later")
                Button("Remove") { var next = rows!; next[row].remove(at: index); setRows(next) }
            }
            SidebarStyleEditor(style: Binding(get: { rows![row][index].style }, set: { style in edit(row, index) { $0.style = style } }))
            ForEach(occurrence.rules.indices, id: \.self) { ruleIndex in
                SidebarConditionEditor(rule: Binding(get: { rows![row][index].rules[ruleIndex] }, set: { rule in edit(row, index) { $0.rules[ruleIndex] = rule } }),
                    first: ruleIndex == 0, last: ruleIndex + 1 == occurrence.rules.count,
                    move: { offset in edit(row, index) { $0.rules.swapAt(ruleIndex, ruleIndex + offset) } },
                    remove: { edit(row, index) { $0.rules.remove(at: ruleIndex) } })
            }
            Button("Add first-match rule") { edit(row, index) { $0.rules.append(.init(condition: .contains(""))) } }
                .disabled(occurrence.rules.count >= 16 || ["state_icon", "git_status"].contains(occurrence.token))
        }.padding(6)
    }

    private func edit(_ row: Int, _ token: Int, _ update: (inout SidebarOccurrence) -> Void) {
        var next = rows!; update(&next[row][token]); setRows(next)
    }
    private func setRows(_ rows: [[SidebarOccurrence]]?) {
        var next = section
        if agent.isEmpty { next.rows = rows } else { next.rowsByAgent[agent] = rows }
        setSection(next)
    }
    private func setSection(_ section: SidebarSection) {
        if target == "agents" { draft.agents = section } else { draft.spaces = section }
        diagnostic = nil; updatePreview()
    }
    private func updatePreview() {
        let layout = section.layout(agent: agent.isEmpty ? nil : agent) ?? []
        let values = Dictionary(layout.flatMap { $0.map { ($0.token, sample) } }, uniquingKeysWith: { first, _ in first })
        preview = section.resolve(values: values, status: .working, agent: agent.isEmpty ? nil : agent)
    }
    private func load() { draft = store.sidebarConfiguration ?? SidebarConfiguration(); diagnostic = nil; updatePreview() }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { diagnostic = error.localizedDescription } }
}

private struct SidebarStyleEditor: View {
    @Binding var style: SidebarStyle
    var body: some View {
        HStack {
            Toggle("Color", isOn: Binding(get: { style.foreground != nil }, set: { style.foreground = $0 ? .rgb(255, 128, 64) : nil }))
            if style.foreground != nil {
                ColorPicker("Foreground", selection: Binding(get: {
                    guard case .rgb(let r, let g, let b) = style.foreground else { return .primary }
                    return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
                }, set: { value in
                    guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                    style.foreground = .rgb(UInt8((rgb.redComponent * 255).rounded()), UInt8((rgb.greenComponent * 255).rounded()), UInt8((rgb.blueComponent * 255).rounded()))
                }), supportsOpacity: false).labelsHidden()
            }
            SidebarOptionalBool(label: "Bold", value: $style.bold)
            SidebarOptionalBool(label: "Dim", value: $style.dim)
        }.font(.caption)
    }
}

private struct SidebarOptionalBool: View {
    let label: String
    @Binding var value: Bool?
    var body: some View {
        Picker(label, selection: Binding(get: { value.map { $0 ? 1 : 0 } ?? -1 }, set: { value = $0 == -1 ? nil : $0 == 1 })) {
            Text("Inherit").tag(-1); Text("On").tag(1); Text("Off").tag(0)
        }
    }
}

private struct SidebarConditionEditor: View {
    @Binding var rule: SidebarRule
    let first: Bool
    let last: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    private var kind: String {
        switch rule.condition { case .equals: "equals"; case .contains: "contains"; case .startsWith: "starts_with"; case .gt: "gt"; case .lt: "lt" }
    }
    private var numeric: Bool { kind == "gt" || kind == "lt" }
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("If", selection: Binding(get: { kind }, set: { kind in
                    switch kind { case "equals": rule.condition = .equals(""); case "contains": rule.condition = .contains(""); case "starts_with": rule.condition = .startsWith(""); case "gt": rule.condition = .gt(0); default: rule.condition = .lt(0) }
                    if numeric { rule.ignoreCase = nil }
                })) { ForEach(["equals", "contains", "starts_with", "gt", "lt"], id: \.self) { Text($0).tag($0) } }
                if numeric {
                    TextField("Threshold", value: Binding(get: {
                        switch rule.condition { case .gt(let n), .lt(let n): return n; default: return 0 }
                    }, set: { rule.condition = kind == "gt" ? .gt($0) : .lt($0) }), format: .number)
                } else {
                    TextField("Value (empty allowed)", text: Binding(get: {
                        switch rule.condition { case .equals(let s), .contains(let s), .startsWith(let s): return s; default: return "" }
                    }, set: { value in
                        switch kind { case "equals": rule.condition = .equals(value); case "contains": rule.condition = .contains(value); default: rule.condition = .startsWith(value) }
                    }))
                }
                Button("↑") { move(-1) }.disabled(first).help("Move rule earlier")
                Button("↓") { move(1) }.disabled(last).help("Move rule later")
                Button("Remove", action: remove)
            }
            HStack {
                if !numeric { SidebarOptionalBool(label: "ASCII ignore case", value: $rule.ignoreCase) }
                SidebarOptionalBool(label: "Hide", value: $rule.hide)
            }
            SidebarStyleEditor(style: $rule.style)
        }.padding(6).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
    }
}
