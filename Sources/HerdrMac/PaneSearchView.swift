import AppKit
import SwiftUI

/// Search a server snapshot while keeping the live terminal mounted underneath.
struct PaneSearchView: View {
    let paneID: String
    @ObservedObject var store: SessionStore
    let focusToken: UUID
    let close: () -> Void
    @State private var query = ""
    @State private var text = ""
    @State private var matches = PaneSearchMatches()
    @State private var loading = true
    @State private var error: String?
    @State private var truncated = false
    @State private var refreshToken = UUID()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in pane", text: $query)
                    .textFieldStyle(.plain).focused($fieldFocused)
                    .accessibilityLabel("Find in pane")
                    .onKeyPress(keys: [.return]) { press in
                        matches.move(by: press.modifiers.contains(.shift) ? -1 : 1)
                        return .handled
                    }
                Text(query.isEmpty ? "" : matches.ranges.isEmpty ? "No matches" : "\(matches.selectedIndex + 1) of \(matches.ranges.count)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                    .accessibilityLabel("Search results")
                Button { matches.move(by: -1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (Shift-Return)").accessibilityLabel("Previous match")
                    .disabled(matches.ranges.isEmpty)
                Button { matches.move(by: 1) } label: { Image(systemName: "chevron.down") }
                    .help("Next match (Return)").accessibilityLabel("Next match")
                    .disabled(matches.ranges.isEmpty)
                Button(action: close) { Image(systemName: "xmark") }
                    .help("Close search (Escape)").accessibilityLabel("Close search")
            }
            .buttonStyle(.plain).padding(8)
            Divider()
            HStack {
                Text(truncated ? "Output snapshot · last 10,000 lines (truncated)" : "Output snapshot")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if loading { ProgressView().controlSize(.mini) }
                Button("Refresh") { refreshToken = UUID() }.disabled(loading)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(8)
            }
            PaneSearchText(text: text, matches: matches, fontSize: store.fontSize, close: close)
        }
        .background(.background)
        .background(PaneSearchKeyHandler { matches.move(by: $0) })
        .onExitCommand(perform: close)
        .onAppear { fieldFocused = true }
        .onChange(of: focusToken) { _, _ in fieldFocused = true }
        .onChange(of: query) { _, _ in matches = PaneSearchMatches(text: text, query: query) }
        .task(id: refreshToken) {
            loading = true
            error = nil
            do {
                let snapshot = try await store.readPaneForSearch(paneID)
                text = snapshot.text
                truncated = snapshot.truncated
                matches = PaneSearchMatches(text: text, query: query)
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

/// NSTextView's field editor can consume Find Next before SwiftUI buttons see
/// their shortcuts. Handle it only in the window containing the open search.
private struct PaneSearchKeyHandler: NSViewRepresentable {
    let navigate: (Int) -> Void

    func makeNSView(context: Context) -> SearchKeyView { SearchKeyView() }
    func updateNSView(_ view: SearchKeyView, context: Context) { view.navigate = navigate }
    static func dismantleNSView(_ view: SearchKeyView, coordinator: ()) { view.stop() }

    final class SearchKeyView: NSView {
        var navigate: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      window.attachedSheet == nil,
                      event.charactersIgnoringModifiers?.lowercased() == "g",
                      event.modifierFlags.contains(.command),
                      event.modifierFlags.isDisjoint(with: [.control, .option]) else { return event }
                self.navigate?(event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct PaneSearchText: NSViewRepresentable {
    let text: String
    let matches: PaneSearchMatches
    let fontSize: Double
    let close: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let view = SearchOutputTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 7, height: 7)
        view.setAccessibilityLabel("Searchable pane output")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? SearchOutputTextView else { return }
        view.closeSearch = close
        let needsStyle = view.string != text || view.searchRanges != matches.ranges || view.font?.pointSize != CGFloat(fontSize)
        if needsStyle {
            let content = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.textColor
            ])
            for range in matches.ranges {
                content.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
            }
            view.textStorage?.setAttributedString(content)
            view.searchRanges = matches.ranges
        }
        if needsStyle || view.activeMatch != matches.selectedRange {
            view.activeMatch = matches.selectedRange
            view.setSelectedRange(matches.selectedRange ?? NSRange(location: 0, length: 0))
            if let range = matches.selectedRange { view.scrollRangeToVisible(range) }
        }
    }
}

final class SearchOutputTextView: NSTextView {
    var searchRanges: [NSRange] = []
    var activeMatch: NSRange?
    var closeSearch: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { closeSearch?() }
}
