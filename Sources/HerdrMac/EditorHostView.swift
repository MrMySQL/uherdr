import AppKit
import SwiftUI
import HerdrCore

/// One editor tab's content, shown in place of the terminals: the header,
/// any banner the tab needs (recovered draft, save problems), and the text.
struct EditorHostView: View {
    let tab: EditorStore.Tab
    let space: String
    @ObservedObject var editors: EditorStore
    let root: String?
    let fontSize: Double
    /// False while an SSH device is disconnected: edits stay, Save waits.
    var canSave = true
    /// For the disconnected banner (frame 08).
    var deviceName = "The device"
    var onReconnect: (() -> Void)? = nil
    /// SSH tabs can't be revealed in Finder.
    var isRemote = false
    /// Markdown preview: images of the space, and links to other files.
    var readAsset: (@Sendable (String) async throws -> FileReader.Raw)? = nil
    var onOpenFile: (String, String?) -> Void = { _, _ in }
    var onFocus: () -> Void = {}
    @State private var comparing: CompareSheet.Model?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            banners
            switch tab.load {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(reason):
                message(title: "Can't open this file", detail: reason, systemImage: "exclamationmark.triangle")
            case .diff:
                EmptyView() // diff tabs are shown by DiffHostView
            case let .media(.data(data)):
                if FileKind.of(tab.name) == .pdf { PDFViewerView(name: tab.name, data: data) } else { ImageViewerView(name: tab.name, data: data) }
            case let .media(.tooLarge(bytes)):
                message(title: "This file is too large to show", detail: "\(tab.name) is \(Self.size(bytes)); images and PDFs open up to \(Self.size(FileReader.mediaLimit)).", systemImage: "doc")
            case let .loaded(contents):
                switch contents.kind {
                case let .text(saved) where tab.showsPreview && FileKind.of(tab.name) == .markdown:
                    if let root, let readAsset {
                        MarkdownPreviewView(markdown: tab.text ?? saved, name: tab.name, documentPath: tab.filePath, root: root,
                                            readAsset: readAsset, fragment: tab.previewFragment, onOpenFile: onOpenFile)
                    }
                case .text:
                    CodeTextView(text: tab.text ?? "", fontSize: fontSize, language: SyntaxHighlighter.Language.forFile(tab.name),
                                 editable: tab.canEdit, reveal: tab.reveal, onFocus: onFocus,
                                 onEdit: { editors.edit(tab.id, in: space, text: $0) })
                case let .unsupported(reason):
                    // Frame 18.
                    CantShowView(title: "Can't show this file",
                                 detail: "\(tab.name) is \(reason == "binary" ? "a binary file" : reason) (\(Self.size(contents.byteCount))). uHerdr shows text, images and PDFs.",
                                 path: tab.filePath, canReveal: !isRemote)
                case let .tooLarge(bytes, limit):
                    message(title: "This file is too large to open", detail: "\(tab.name) is \(Self.size(bytes)); the editor opens files up to \(Self.size(limit)).", systemImage: "doc")
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .alert("“\(tab.name)” changed on disk", isPresented: binding(for: .conflict)) {
            Button("Compare…") { compare() }.keyboardShortcut(.defaultAction)
            Button("Discard my edits") { editors.discardEdits(tab.id, in: space) }
            Button("Overwrite with my version", role: .destructive) { Task { await editors.save(tab.id, in: space, mode: .overwrite) } }
            Button("Cancel", role: .cancel) { editors.dismissSaveProblem(tab.id, in: space) }
        } message: {
            Text("The file changed after you opened it. Your edits are not saved yet.")
        }
        .alert("Save “\(tab.name)” in place?", isPresented: inPlaceBinding) {
            Button("Save in Place") { Task { await editors.save(tab.id, in: space, mode: .inPlace) } }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { editors.dismissSaveProblem(tab.id, in: space) }
        } message: {
            if case let .needsInPlace(reason) = tab.saveState {
                Text("\(reason) Saving in place writes straight into the file; if the save is interrupted, the file may be left partly written.")
            }
        }
        .sheet(item: $comparing) { model in
            CompareSheet(model: model,
                         onOverwrite: { comparing = nil; Task { await editors.save(tab.id, in: space, mode: .overwrite) } },
                         onDiscard: { comparing = nil; editors.discardEdits(tab.id, in: space) },
                         onCancel: { comparing = nil; editors.dismissSaveProblem(tab.id, in: space) })
        }
    }

    private func binding(for state: EditorStore.SaveState) -> Binding<Bool> {
        // Each button changes the save state itself, which closes the alert.
        Binding(get: { tab.saveState == state && comparing == nil }, set: { _ in })
    }

    private var inPlaceBinding: Binding<Bool> {
        Binding(get: { if case .needsInPlace = tab.saveState { return true } else { return false } }, set: { _ in })
    }

    private func compare() {
        Task {
            let disk = await editors.diskVersion(tab.id, in: space) ?? ""
            comparing = CompareSheet.Model(name: tab.name, disk: disk, mine: tab.text ?? "")
        }
    }

    @ViewBuilder private var banners: some View {
        if let draft = tab.recoveredDraft {
            banner(.blue, "arrow.uturn.backward", "Recovered draft.", "Unsaved edits from \(draft.savedAt.formatted(date: .abbreviated, time: .shortened)).") {
                Button("Compare with disk") { comparing = CompareSheet.Model(name: tab.name, disk: tab.baselineText ?? "", mine: draft.text, draftMode: true) }
                Button("Discard draft") { editors.discardDraft(tab.id, in: space) }
                Button("Keep draft") { editors.keepDraft(tab.id, in: space) }.buttonStyle(.borderedProminent)
            }
        }
        if !canSave, tab.isDirty {
            banner(.red, "exclamationmark.triangle", "\(deviceName) disconnected.", "Save is paused; your edits are kept in this tab and as a draft.") {
                if let onReconnect { Button("Reconnect", action: onReconnect) }
            }
        }
        switch tab.saveState {
        case let .failed(reason):
            banner(.red, "exclamationmark.triangle", "Couldn't save.", reason) {
                Button("Try Again") { save() }
                Button("Dismiss") { editors.dismissSaveProblem(tab.id, in: space) }
            }
        case let .outcomeUnknown(reason):
            banner(.orange, "questionmark.circle", "Save outcome unknown.", "The connection dropped during the save, and reading the file back didn't show your version. \(reason)") {
                Button("Compare with disk") { compare() }
                Button("Try Again") { save() }
            }
        default: EmptyView()
        }
    }

    private func banner<Actions: View>(_ tint: Color, _ icon: String, _ title: String, _ detail: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            (Text(title).bold() + Text(" " + detail)).font(.system(size: 12)).lineLimit(2)
            Spacer()
            actions().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func save() { Task { await editors.save(tab.id, in: space) } }

    private var header: some View {
        HStack(spacing: 8) {
            if let image = FileIcon.image(named: FileIconName.name(for: tab.name, isDirectory: false)) {
                Image(nsImage: image).resizable().frame(width: 14, height: 14)
            }
            Text(tab.name).font(.system(size: 12, weight: .medium))
            Text(relativeFolder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if let note = tab.note {
                Label(note, systemImage: "arrow.clockwise").font(.system(size: 10, weight: .medium)).foregroundStyle(herdrAccentColor)
            }
            if FileKind.of(tab.name) == .markdown, case let .loaded(contents) = tab.load, case .text = contents.kind {
                Picker("Mode", selection: Binding(get: { tab.showsPreview }, set: { editors.setPreview(tab.id, in: space, $0) })) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("Edit or preview (⌥⌘V). Remote images in the preview load from their servers, which can see your IP address.")
            }
            if case .media = tab.load {
                Text([FileKind.of(tab.name) == .pdf ? "PDF" : "Image", "read-only"].joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if case let .loaded(contents) = tab.load, case .text = contents.kind {
                if !tab.canEdit {
                    Text(tab.readOnlyNote ?? "Read-only").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
                } else if tab.isDirty {
                    Button(action: save) {
                        // Spinner only while saving, at the button's normal width.
                        ZStack {
                            Text("Save").opacity(tab.saveState == .saving ? 0 : 1)
                            if tab.saveState == .saving { ProgressView().controlSize(.mini) }
                        }
                    }
                    .controlSize(.small).disabled(!canSave || tab.saveState == .saving)
                    .help(canSave ? "Save (⌘S)" : "Reconnect the device to save")
                }
                Text([SyntaxHighlighter.Language.forFile(tab.name)?.displayName, "UTF-8\(contents.hasBOM ? " BOM" : "")", contents.lineEnding.rawValue]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).frame(height: 30)
    }

    private var relativeFolder: String {
        let folder = (tab.filePath as NSString).deletingLastPathComponent
        guard let root, folder.hasPrefix(root) else { return folder }
        let rest = folder.dropFirst(root.count).drop { $0 == "/" }
        return rest.isEmpty ? "" : String(rest)
    }

    private func message(title: String, detail: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

/// The disk version beside your edits, line by line, with the conflict's choices.
struct CompareSheet: View {
    struct Model: Identifiable {
        let id = UUID()
        let name: String
        let disk: String
        let mine: String
        /// Comparing a recovered draft: the choices are the draft's, not a save's.
        var draftMode = false
    }
    let model: Model
    @State private var lines: [LineDiff.Line] = []
    var onOverwrite: () -> Void
    var onDiscard: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("“\(model.name)”: on disk ← → \(model.draftMode ? "draft" : "your edits")").font(.headline)
                Spacer()
                Text("\(lines.filter { $0.kind == .removed }.count) removed · \(lines.filter { $0.kind == .added }.count) added")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            // Lines never wrap: long ones scroll sideways, and every row spans
            // at least the sheet's width so the colours line up.
            GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            Text(line.old.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
                            Text(line.new.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
                            Text(line.kind == .added ? " + " : line.kind == .removed ? " − " : "   ")
                            Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(line.kind == .added ? Color.green.opacity(0.15) : line.kind == .removed ? Color.red.opacity(0.15) : .clear)
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: proxy.size.width, alignment: .leading)
            }
            }
            Divider()
            HStack {
                if model.draftMode {
                    Spacer()
                    Button("Close", action: onCancel).keyboardShortcut(.cancelAction)
                } else {
                    Button("Discard my edits", action: onDiscard)
                    Spacer()
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Button("Overwrite with my version", role: .destructive, action: onOverwrite)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 460)
        .task(id: model.id) {
            let disk = model.disk, mine = model.mine
            let worker = Task.detached {
                LineDiff.compare(disk, mine, isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            lines = result
        }
    }
}

/// Monospaced text with a line-number gutter, syntax colours and undo.
struct CodeTextView: NSViewRepresentable {
    let text: String
    let fontSize: Double
    var language: SyntaxHighlighter.Language? = nil
    var editable = false
    var reveal: EditorStore.Reveal? = nil
    var onFocus: () -> Void = {}
    var onEdit: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Selects and shows a requested place once per request.
    func show(_ reveal: EditorStore.Reveal?, in textView: NSTextView, coordinator: Coordinator) {
        guard let reveal, reveal.id != coordinator.shownReveal, !textView.string.isEmpty else { return }
        coordinator.shownReveal = reveal.id
        let text = textView.string as NSString
        var start = 0, line = 1
        while line < reveal.line, start < text.length {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            line += 1
        }
        let lineEnd = NSMaxRange(text.lineRange(for: NSRange(location: min(start, text.length), length: 0)))
        let location = min(start + reveal.columns.lowerBound, lineEnd)
        let range = NSRange(location: location, length: max(0, min(reveal.columns.count, lineEnd - location)))
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        if reveal.focus { textView.window?.makeFirstResponder(textView) }
        DispatchQueue.main.async { textView.showFindIndicator(for: range) }
    }

    func makeNSView(context: Context) -> CodeEditorContainer {
        let container = CodeEditorContainer()
        context.coordinator.parent = self
        context.coordinator.container = container
        container.textView.delegate = context.coordinator
        container.textView.onFocus = onFocus
        container.textView.isEditable = editable
        container.textView.allowsUndo = true
        apply(to: container)
        DispatchQueue.main.async { show(reveal, in: container.textView, coordinator: context.coordinator) }
        return container
    }

    func updateNSView(_ container: CodeEditorContainer, context: Context) {
        context.coordinator.parent = self
        container.textView.onFocus = onFocus
        container.textView.isEditable = editable
        // Typing already put this text in the view; only outside changes
        // (reload, discard, keep draft) replace it.
        if container.textView.string != text || container.textView.font?.pointSize != CGFloat(fontSize) { apply(to: container) }
        show(reveal, in: container.textView, coordinator: context.coordinator)
    }

    func apply(to container: CodeEditorContainer) {
        let textView = container.textView
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        textView.font = font
        textView.textColor = .textColor
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            let length = (text as NSString).length
            textView.selectedRanges = selection.compactMap { value in
                let range = value.rangeValue
                return range.location <= length ? NSValue(range: NSRange(location: range.location, length: min(range.length, length - range.location))) : nil
            }.nilIfEmpty ?? [NSValue(range: NSRange(location: 0, length: 0))]
        }
        highlight(textView)
        container.gutter.refresh()
        container.needsLayout = true
    }

    func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: NSRange(location: 0, length: storage.length))
        if let language {
            for span in SyntaxHighlighter.spans(for: storage.string, language: language) where NSMaxRange(span.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: Self.color(span.token), range: span.range)
            }
        }
        storage.endEditing()
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView?
        weak var container: CodeEditorContainer?
        var shownReveal: UUID?
        private var recolour: Task<Void, Never>?

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, let parent else { return }
            parent.onEdit(textView.string)
            container?.gutter.refresh()
            // Re-colour once typing pauses briefly, not on every keystroke.
            recolour?.cancel()
            recolour = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, let parent = self.parent else { return }
                parent.highlight(textView)
            }
        }
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

extension CodeTextView {
    /// Xcode's default theme, in its light and dark versions, following the
    /// window's appearance.
    static func color(_ token: SyntaxHighlighter.Token) -> NSColor {
        switch token {
        case .comment: return palette.comment
        case .string: return palette.string
        case .number: return palette.number
        case .keyword: return palette.keyword
        case .type: return palette.type
        case .key: return palette.key
        case .heading: return palette.heading
        }
    }

    private static let palette = (
        comment: dynamic(light: 0x5D6C79, dark: 0x6C7986),
        string: dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        number: dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        keyword: dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        type: dynamic(light: 0x3900A0, dark: 0xD0A8FF),
        key: dynamic(light: 0x326D74, dark: 0x67B7A4),
        heading: dynamic(light: 0x0F68A0, dark: 0x5DD8FF)
    )

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        func rgb(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }
}

/// The gutter sits beside the scroll view rather than as an NSRulerView: in a
/// SwiftUI-hosted scroll view the ruler didn't make room for itself and the
/// text ran under it. Line numbers also stay put when scrolling sideways.
final class CodeEditorContainer: NSView {
    let scroll = NSScrollView()
    let textView = FocusReportingTextView(usingTextLayoutManager: false)
    lazy var gutter = LineNumberGutter(textView: textView)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Editor")
        scroll.documentView = textView
        addSubview(gutter)
        addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(gutter, selector: #selector(LineNumberGutter.changed), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(gutter, selector: #selector(LineNumberGutter.changed), name: NSText.didChangeNotification, object: textView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let width = gutter.thickness
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}

/// Reports when the editor takes the keyboard, so terminals stop reclaiming it.
extension FocusReportingTextView {
    /// ⌘F while an editor shows: its own find bar, never the hidden pane's search.
    @MainActor static func showFindBar(in window: NSWindow?, replace: Bool = false) {
        guard let window else { return }
        let textView = window.firstResponder as? FocusReportingTextView ?? window.contentView.flatMap(first)
        guard let textView else { return }
        window.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = (replace ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
        textView.performFindPanelAction(item)
    }

    private static func first(in view: NSView) -> FocusReportingTextView? {
        if let match = view as? FocusReportingTextView { return match }
        for child in view.subviews { if let match = first(in: child) { return match } }
        return nil
    }
}

final class FocusReportingTextView: NSTextView {
    var onFocus: () -> Void = {}
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus() }
        return accepted
    }
}

/// Draws the line numbers of the visible lines, aligned with the text.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private(set) var thickness: CGFloat = 40

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc func changed() { needsDisplay = true }

    /// Fits the widest line number (at least three digits).
    func refresh() {
        guard let textView else { return }
        let lines = max(1, textView.string.reduce(into: 1) { if $1 == "\n" { $0 += 1 } })
        let digits = max(3, String(lines).count)
        thickness = (CGFloat(digits) * ((textView.font?.pointSize ?? 12) * 0.62) + 16).rounded()
        superview?.needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (textView.font?.pointSize ?? 12) - 1), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let text = textView.string as NSString
        let visible = clip.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Lines before the first visible character.
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let inset = textView.textContainerInset.height
        var index = characters.location
        repeat {
            let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
            var y: CGFloat
            if text.length == 0 {
                y = 0
            } else {
                let glyph = layout.glyphIndexForCharacter(at: min(lineRange.location, max(0, text.length - 1)))
                y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            y += inset - visible.minY
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: thickness - size.width - 8, y: y + 1), withAttributes: attributes)
            line += 1
            index = NSMaxRange(lineRange)
        } while index < NSMaxRange(characters) && index < text.length
    }
}
