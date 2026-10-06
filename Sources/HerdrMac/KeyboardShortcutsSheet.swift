import SwiftUI
import HerdrCore

/// Every shortcut uHerdr has, grouped as in the menus, with search.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var groups: [ShortcutGroup] { ShortcutGroup.filtered(search) { $0.defaultChord } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.system(size: 17, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search shortcuts", text: $search).textFieldStyle(.plain).focused($searchFocused)
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
                        ForEach(Array(ShortcutGroup.columns(groups).enumerated()), id: \.offset) { _, groups in column(groups) }
                    }
                    .padding(24)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 820, height: 640)
        .onAppear { searchFocused = true }
    }

    private func column(_ groups: [ShortcutGroup]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(group.rows) { row in rowView(row) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rowView(_ row: ShortcutRow) -> some View {
        HStack(spacing: 6) {
            Text(row.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            ForEach(Array(row.actions.enumerated()), id: \.offset) { index, action in
                if index > 0 { Text("/").font(.system(size: 11)).foregroundStyle(.tertiary) }
                let caps = action.keycaps(for: action.defaultChord)
                ForEach(Array(caps.enumerated()), id: \.offset) { capIndex, cap in
                    if capIndex > 0 { Text("·").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    Keycap(text: cap)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
    }
}
