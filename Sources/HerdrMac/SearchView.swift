import AppKit
import SwiftUI
import HerdrCore

/// The Search panel (frames 04 and 15): literal text across the space's
/// folder with match case, whole word and include/exclude globs; results
/// grouped by file, unsaved tabs searched as they are now.
struct SearchView: View {
    @ObservedObject var model: SearchModel
    let folderLabel: String
    var deviceName = "this device"
    /// The result shown in the editor, to highlight its row: path and line.
    let activeResult: (path: String, line: Int)?
    var onOpen: (SearchHit, _ keep: Bool) -> Void
    @FocusState private var queryFocused: Bool
    /// Asked to focus the query field (⇧⌘F); a new value focuses it again.
    var focusRequest: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            fields
            Divider()
            content
            Divider()
            footer
        }
        .onAppear { if focusRequest > 0 { queryFocused = true } }
        .onChange(of: focusRequest) { _, _ in queryFocused = true }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.options.query)
                    .textFieldStyle(.plain).focused($queryFocused)
                    .onSubmit { model.rerun() }
                    .onExitCommand { model.options.query = "" }
                toggle("Aa", on: $model.options.caseSensitive, help: "Match case")
                toggle("ab", on: $model.options.wholeWord, help: "Match whole word")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).frame(height: 28)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(queryFocused ? herdrAccentColor.opacity(0.7) : Color.secondary.opacity(0.25)))
            glob("files to include", text: $model.options.include, placeholder: "e.g. Sources/**/*.swift")
            glob("files to exclude", text: $model.options.exclude, placeholder: "e.g. Vendor/**")
        }
        .padding(10)
    }

    private func toggle(_ label: String, on: Binding<Bool>, help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(label).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(on.wrappedValue ? herdrAccentColor : .secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(on.wrappedValue ? herdrAccentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on.wrappedValue ? herdrAccentColor.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain).help(help)
        .accessibilityLabel(help).accessibilityValue(on.wrappedValue ? "on" : "off")
    }

    private func glob(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).frame(height: 24)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.2)))
                .accessibilityLabel(title)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            message("Search this space", "Type to search every file in \(folderLabel). Unsaved edits are searched as they are in their tabs.", "magnifyingglass")
        case .searching where model.groups.isEmpty:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(error):
            failure(error)
        case let .done(outcome, _) where outcome.hits.isEmpty:
            VStack(spacing: 0) {
                message("No results", "Nothing matches “\(model.options.query)” in \(folderLabel).", "magnifyingglass")
                problems(outcome.problems)
            }
        default:
            results
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if case let .done(outcome, _) = model.state, let stopped = outcome.stoppedAt {
                    Label("Showing the first \(stopped). Narrow the search with files to include or exclude.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.yellow)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
                ForEach(model.groups) { group in fileGroup(group) }
                if case let .done(outcome, _) = model.state { problems(outcome.problems) }
            }
            .padding(.vertical, 4)
        }
    }

    private func fileGroup(_ group: SearchModel.FileGroup) -> some View {
        let open = !model.collapsed.contains(group.path)
        let name = (group.path as NSString).lastPathComponent
        let folder = (group.path as NSString).deletingLastPathComponent
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.toggle(group.path) } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 12)
                    if let image = FileIcon.image(named: FileIconName.name(for: name, isDirectory: false)) {
                        Image(nsImage: image).resizable().frame(width: 14, height: 14)
                    }
                    Text(name).lineLimit(1)
                    Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    if group.unsaved {
                        HStack(spacing: 3) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text("unsaved")
                        }
                        .foregroundStyle(.orange).font(.system(size: 10))
                    }
                    Text("\(group.matchCount)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(group.matchCount) \(group.matchCount == 1 ? "match" : "matches")\(group.unsaved ? ", unsaved" : "")")
            if open {
                ForEach(Array(group.hits.enumerated()), id: \.offset) { _, hit in line(hit) }
            }
        }
    }

    private func line(_ hit: SearchHit) -> some View {
        let selected = activeResult.map { $0.path == hit.path && $0.line == hit.line } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(hit.line)").foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
            Text(Self.excerpt(hit)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.leading, 8).padding(.trailing, 8).frame(height: 22)
        .background(selected ? herdrAccentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay { if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(herdrAccentColor.opacity(0.6)) } }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(hit, true) }
        .onTapGesture { onOpen(hit, false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Line \(hit.line): \(hit.text.trimmingCharacters(in: .whitespaces))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(hit, false) }
    }

    /// The line from a little before the first match (indentation dropped),
    /// with every match highlighted.
    static func excerpt(_ hit: SearchHit) -> AttributedString {
        let text = hit.text as NSString
        let first = hit.ranges.first?.lowerBound ?? 0
        let indent = (hit.text.prefix { $0 == " " || $0 == "\t" }).utf16.count
        let start = min(first, first > indent + 24 ? first - 12 : indent)
        var result = AttributedString(start > indent ? "…" : "")
        var cursor = start
        for range in hit.ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor && range.upperBound <= text.length {
            result += AttributedString(text.substring(with: NSRange(location: cursor, length: range.lowerBound - cursor)))
            var match = AttributedString(text.substring(with: NSRange(location: range.lowerBound, length: range.count)))
            match.backgroundColor = Color.yellow.opacity(0.35)
            result += match
            cursor = range.upperBound
        }
        result += AttributedString(text.substring(from: min(cursor, text.length)))
        return result
    }

    private func problems(_ problems: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(problems.prefix(20), id: \.self) { problem in
                Label(problem, systemImage: "lock").font(.system(size: 11)).foregroundStyle(.red.opacity(0.85))
            }
            if problems.count > 20 { Text("and \(problems.count - 20) more").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, problems.isEmpty ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            switch model.state {
            case .searching:
                ProgressView().controlSize(.mini)
                Text("Searching…")
                Spacer()
                Button("Stop") { model.cancel() }.buttonStyle(.borderless).controlSize(.small)
            case let .done(outcome, elapsed):
                let files = Set(outcome.hits.map(\.path)).count
                let matches = outcome.hits.reduce(0) { $0 + $1.ranges.count }
                Image(systemName: outcome.stoppedAt == nil ? "checkmark" : "exclamationmark.triangle")
                Text(outcome.stoppedAt == nil
                     ? "\(matches) \(matches == 1 ? "result" : "results") in \(files) \(files == 1 ? "file" : "files") · \(Self.milliseconds(elapsed)) ms"
                     : "\(matches.formatted())+ results · stopped after \(outcome.stoppedAt!)")
                Spacer()
            default:
                Text(" ")
                Spacer()
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func failure(_ error: SearchError) -> AnyView {
        switch error {
        case .ripgrepMissing:
            return AnyView(ripgrepMissing)
        case .folderMissing:
            return AnyView(message("Can't open the folder", "\(folderLabel) is missing or can't be read.", "folder.badge.questionmark"))
        case let .failed(reason):
            return AnyView(message("Search failed", reason, "exclamationmark.triangle"))
        }
    }

    /// Frame 07: no ripgrep on the device, and the offer to copy uHerdr's own.
    private var ripgrepMissing: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(.secondary)
            Text("ripgrep isn't installed on \(deviceName)").font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
            if let target = model.installTarget, model.installer != nil {
                Text("Content search runs on the server, next to the files. uHerdr can copy its own ripgrep \(target) to ~/.local/share/uherdr/bin. Nothing else is installed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                switch model.install {
                case .installing:
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…") }.font(.system(size: 12))
                case let .failed(reason):
                    Text(reason).font(.system(size: 11)).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button("Try Again") { model.installRipgrep() }.buttonStyle(.borderedProminent).tint(herdrAccentColor)
                case .idle:
                    Button("Install for uHerdr") { model.installRipgrep() }.buttonStyle(.borderedProminent).tint(herdrAccentColor)
                }
            } else {
                Text("Install ripgrep on \(deviceName) to search its files here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Label("Quick Open (⌘P) still works here: it lists files with git.", systemImage: "checkmark")
                .font(.system(size: 11)).foregroundStyle(.yellow)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ title: String, _ detail: String, _ systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
