import AppKit
import SwiftUI
import HerdrCore

/// A read-only diff tab (frame 03): Unified or Split, previous/next change,
/// and Open file. Nothing here stages, commits or discards.
struct DiffHostView: View {
    let tab: EditorStore.Tab
    let spec: EditorStore.DiffSpec
    var fontSize: Double = 12
    var onOpenFile: () -> Void
    @AppStorage("diff.split") private var split = false
    @State private var current = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab.load {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(reason):
                message("Can't show this diff", reason, "exclamationmark.triangle")
            case let .diff(diff) where diff.isBinary:
                message("Binary file", "\(tab.name) is a binary file, so there are no lines to compare.", "doc")
            case let .diff(diff) where diff.hunks.isEmpty:
                message(spec.change.originalPath != nil ? "Renamed, no line changes" : "No changes to show",
                        spec.change.originalPath.map { "Renamed from \($0)." } ?? "The file matches the version it's compared with.", "checkmark.circle")
            case let .diff(diff):
                lines(diff)
            default:
                EmptyView()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var hunkCount: Int { if case let .diff(diff) = tab.load { return diff.hunks.count } else { return 0 } }

    private var groupLabel: String {
        switch spec.change.group {
        case .staged: return "Staged"
        case .changes: return "Unstaged"
        case .untracked: return "Untracked"
        case .conflicts: return "Conflict"
        }
    }

    private var folder: String {
        let parent = (spec.path as NSString).deletingLastPathComponent
        let root = spec.root.hasSuffix("/") ? String(spec.root.dropLast()) : spec.root
        if parent == root { return "" }
        return parent.hasPrefix(root + "/") ? String(parent.dropFirst(root.count + 1)) : parent
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let image = FileIcon.image(named: FileIconName.name(for: tab.name, isDirectory: false)) {
                Image(nsImage: image).resizable().frame(width: 14, height: 14)
            }
            Text(tab.name).font(.system(size: 12, weight: .medium))
            Text(folder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(groupLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Spacer()
            Label("Read-only", systemImage: "lock").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            if hunkCount > 0 {
                Text("\(min(current, hunkCount - 1) + 1) of \(hunkCount)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Button { current = max(0, current - 1) } label: { Image(systemName: "arrow.up") }
                    .disabled(current == 0).help("Previous change").accessibilityLabel("Previous change")
                Button { current = min(hunkCount - 1, current + 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(current >= hunkCount - 1).help("Next change").accessibilityLabel("Next change")
            }
            Picker("Layout", selection: $split) {
                Text("Unified").tag(false)
                Text("Split").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button(action: onOpenFile) { Label(spec.change.isDeleted ? "Open base version" : "Open file", systemImage: "arrow.up.forward.square") }
                .help(spec.change.isDeleted ? "Open the last committed version, read-only" : "Open the file in an editor tab")
        }
        .controlSize(.small)
        .padding(.horizontal, 12).frame(height: 30)
    }

    private func lines(_ diff: GitDiff) -> some View {
        let language = SyntaxHighlighter.Language.forFile(tab.name)
        let numberWidth = CGFloat(max(3, String(diff.hunks.flatMap(\.lines).compactMap { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0).count)) * fontSize * 0.62 + 10
        return GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { index, hunk in
                            Text(hunk.header)
                                .font(.system(size: fontSize, design: .monospaced)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(0.10))
                                .id("hunk-\(index)")
                            if split {
                                ForEach(Array(hunk.splitRows.enumerated()), id: \.offset) { _, pair in
                                    HStack(spacing: 0) {
                                        side(pair.0, number: pair.0?.old, language: language, width: numberWidth)
                                            .frame(width: max(proxy.size.width / 2, 200), alignment: .leading).clipped()
                                        Divider()
                                        side(pair.1, number: pair.1?.new, language: language, width: numberWidth)
                                    }
                                }
                            } else {
                                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                    unified(line, language: language, width: numberWidth)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
                .onChange(of: current) { _, value in withAnimation { scroller.scrollTo("hunk-\(value)", anchor: .top) } }
            }
        }
    }

    private func unified(_ line: GitDiff.Line, language: SyntaxHighlighter.Language?, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(line.old.map(String.init) ?? "").frame(width: width, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.new.map(String.init) ?? "").frame(width: width, alignment: .trailing).foregroundStyle(.tertiary)
            Text(marker(line.kind)).foregroundStyle(markerColor(line.kind)).frame(width: 22)
            Text(Self.highlighted(line.text, language: language)).fixedSize(horizontal: true, vertical: false)
            if line.noNewlineAtEnd { Text("  ⏎̸ no newline at end").foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 1)
        .background(background(line.kind))
        .accessibilityElement(children: .combine)
    }

    private func side(_ line: GitDiff.Line?, number: Int?, language: SyntaxHighlighter.Language?, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "").frame(width: width, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.map { marker($0.kind) } ?? " ").foregroundStyle(line.map { markerColor($0.kind) } ?? .clear).frame(width: 22)
            Text(line.map { Self.highlighted($0.text, language: language) } ?? AttributedString(" ")).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 1)
        .background(line.map { background($0.kind) } ?? Color.primary.opacity(0.03))
    }

    private func marker(_ kind: GitDiff.Line.Kind) -> String {
        switch kind { case .added: return "+"; case .removed: return "−"; case .context: return " " }
    }
    private func markerColor(_ kind: GitDiff.Line.Kind) -> Color {
        switch kind { case .added: return .green; case .removed: return .red; case .context: return .secondary }
    }
    private func background(_ kind: GitDiff.Line.Kind) -> Color {
        switch kind { case .added: return Color.green.opacity(0.14); case .removed: return Color.red.opacity(0.14); case .context: return .clear }
    }

    private func message(_ title: String, _ detail: String, _ systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One line coloured on its own: good enough for a diff, where a line
    /// rarely depends on the lines around it.
    static func highlighted(_ text: String, language: SyntaxHighlighter.Language?) -> AttributedString {
        let shown = text.isEmpty ? " " : text
        let attributed = NSMutableAttributedString(string: shown)
        if let language {
            for span in SyntaxHighlighter.spans(for: shown, language: language) {
                attributed.addAttribute(.foregroundColor, value: CodeTextView.color(span.token), range: span.range)
            }
        }
        return (try? AttributedString(attributed, including: \.appKit)) ?? AttributedString(shown)
    }
}
