import AppKit
import SwiftUI
import HerdrCore

extension Notification.Name {
    /// Menu commands for the window: ⌘P and ⇧⌘F.
    static let uherdrQuickOpen = Notification.Name("uherdr.quickOpen")
    static let uherdrSearchInSpace = Notification.Name("uherdr.searchInSpace")
    /// Right sidebar commands; the object is "toggle", "files" or "changes".
    static let uherdrSidebar = Notification.Name("uherdr.sidebar")
    static let uherdrGoToLine = Notification.Name("uherdr.goToLine")
}

/// ⌘L: a line, or line:column, in the shown editor.
struct GoToLineView: View {
    let lineCount: Int
    var onGo: (Int, Int) -> Void
    var onClose: () -> Void
    @State private var text = ""
    @State private var escape: Any?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line").foregroundStyle(.secondary)
            TextField("Go to line (1–\(lineCount)), or line:column", text: $text)
                .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                .onSubmit {
                    guard let target = LineTarget.parse(text) else { return }
                    onGo(min(target.line, max(1, lineCount)), target.column)
                }
            if !text.isEmpty, LineTarget.parse(text) == nil {
                Text("Type a line number").font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14).frame(width: 460, height: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .task { try? await Task.sleep(for: .milliseconds(30)); focused = true }
        .onAppear {
            escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                onClose()
                return nil
            }
        }
        .onDisappear { if let escape { NSEvent.removeMonitor(escape) }; escape = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Go to line")
    }
}

/// The ⌘P palette (frame 05).
struct QuickOpenView: View {
    @ObservedObject var model: QuickOpenModel
    let place: String
    var onOpen: (String, _ keep: Bool) -> Void
    var onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var escape: Any?

    var body: some View {
        let matches = model.matches
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to file", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .onSubmit { choose(matches, keep: false) }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        choose(matches, keep: true)
                        return .handled
                    }
                Text(place).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            switch model.files {
            case .loading where matches.isEmpty:
                HStack { ProgressView().controlSize(.small); Text("Reading files…").foregroundStyle(.secondary) }
                    .font(.system(size: 12)).frame(maxWidth: .infinity).padding(16)
            case let .failed(reason):
                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(16)
            default:
                if matches.isEmpty {
                    Text("No file matches “\(model.query)”").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(16)
                } else {
                    ScrollViewReader { scroller in
                        ScrollView {
                            // At most 50 rows: a plain stack, keyed by path (an index
                            // key showed stale rows after the list changed).
                            VStack(spacing: 0) {
                                ForEach(Array(matches.enumerated()), id: \.element.path) { index, match in
                                    row(match, selected: index == model.selection)
                                        .onTapGesture { model.selection = index; choose(matches, keep: false) }
                                }
                            }
                        }
                        .frame(height: min(CGFloat(matches.count) * 32, 360))
                        .onChange(of: model.selection) { _, value in
                            if matches.indices.contains(value) { scroller.scrollTo(matches[value].path) }
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Text("↩ open"); Text("⌘↩ open and keep tab"); Text("esc close")
                Spacer()
                Text("\(matches.count) of \(model.total) files")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).frame(height: 28)
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        // The field takes focus once the overlay is in the window (an
        // immediate request is lost while the editor still holds it).
        .task { try? await Task.sleep(for: .milliseconds(30)); focused = true }
        // Esc closes the palette. In this overlay the field editor never passes
        // Esc on as a cancel command, so watch for it while the palette is up.
        .onAppear {
            escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                onClose()
                return nil
            }
        }
        .onDisappear { model.cancel(); if let escape { NSEvent.removeMonitor(escape) }; escape = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Open")
    }

    private func choose(_ matches: [FuzzyMatcher.Match], keep: Bool) {
        guard matches.indices.contains(model.selection) else { return }
        onOpen(matches[model.selection].path, keep)
    }

    private func row(_ match: FuzzyMatcher.Match, selected: Bool) -> some View {
        let chars = Array(match.path)
        let nameStart = (chars.lastIndex(of: "/").map { $0 + 1 }) ?? 0
        let marked = Set(match.positions)
        func styled(_ range: Range<Int>) -> AttributedString {
            var out = AttributedString()
            for i in range {
                var piece = AttributedString(String(chars[i]))
                if marked.contains(i) { piece.foregroundColor = herdrAccentColor }
                out += piece
            }
            return out
        }
        let name = String(chars[nameStart...])
        let tags = [model.open.contains(match.path) ? "open" : nil, model.unsaved.contains(match.path) ? "unsaved" : nil].compactMap { $0 }
        return HStack(spacing: 8) {
            if let image = FileIcon.image(named: FileIconName.name(for: name, isDirectory: false)) {
                Image(nsImage: image).resizable().frame(width: 15, height: 15)
            }
            Text(styled(nameStart..<chars.count)).font(.system(size: 13))
            if nameStart > 0 {
                Text(styled(0..<(nameStart - 1))).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if !tags.isEmpty { Text(tags.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).frame(height: 32)
        .background(selected ? herdrAccentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(match.path + (tags.isEmpty ? "" : ", " + tags.joined(separator: ", ")))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
