import AppKit
import SwiftUI
import HerdrCore

/// The Changes panel (frames 03 and 15): Git status of the space's folder in
/// Conflicts, Staged, Changes and Untracked groups, as a tree or a list.
/// Read-only: nothing is staged, committed or discarded here.
struct ChangesView: View {
    @ObservedObject var model: ChangesModel
    let deviceName: String
    let isRemote: Bool
    /// The diff (or file) tab shown in the editor, to highlight its row.
    let activeID: String?
    var onOpen: (GitChange, _ keep: Bool) -> Void
    @AppStorage("changes.layout") private var listLayout = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.state {
            case .idle, .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(error):
                failure(error)
            case let .loaded(changes):
                loaded(changes)
            }
            Divider()
            Text("Read-only view. Stage and commit from a terminal.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private func loaded(_ changes: GitChanges) -> some View {
        VStack(spacing: 0) {
            branchLine(changes)
            HStack(spacing: 6) {
                Picker("Layout", selection: $listLayout) {
                    Text("Tree").tag(false)
                    Text("List").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                Spacer()
                Button { collapseAll(changes) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.borderless).help("Collapse all").accessibilityLabel("Collapse all")
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh").accessibilityLabel("Refresh changes")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if changes.changes.isEmpty {
                empty("No changes", changes.outside > 0
                      ? "Nothing changed in this space's folder."
                      : "The working tree matches the last commit.", systemImage: "checkmark.circle")
                if changes.outside > 0 { outsideNote(changes.outside).padding(10) }
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(GitChange.Group.allCases, id: \.self) { group in
                            let rows = changes.changes.filter { $0.group == group }
                            if !rows.isEmpty { section(group, rows, changes) }
                        }
                        if changes.outside > 0 { outsideNote(changes.outside).padding(10) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func branchLine(_ changes: GitChanges) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(changes.branch.label).lineLimit(1).truncationMode(.middle)
                Spacer()
                if changes.branch.ahead > 0 || changes.branch.behind > 0 {
                    Text([changes.branch.ahead > 0 ? "↑\(changes.branch.ahead)" : nil, changes.branch.behind > 0 ? "↓\(changes.branch.behind)" : nil]
                            .compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(herdrAccentColor)
                        .help(changes.branch.upstream.map { "Compared with \($0)" } ?? "")
                }
            }
            .font(.system(size: 11, weight: .medium))
            if !changes.prefix.isEmpty {
                Text("Repository: \(abbreviated(changes.repositoryRoot))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Showing changes in \(changes.prefix) only").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }

    private func section(_ group: GitChange.Group, _ rows: [GitChange], _ changes: GitChanges) -> some View {
        let id = "g:" + group.title
        let open = !model.collapsed.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.toggle(id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                    Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    Spacer()
                    Text("\(rows.count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.title), \(rows.count)")
            if open {
                if listLayout {
                    ForEach(rows.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) { change in
                        row(change, name: (change.path as NSString).lastPathComponent, depth: 0, changes: changes, showFolder: true)
                    }
                } else {
                    ForEach(ChangeTree.build(rows, prefix: changes.prefix)) { node in nodeView(node, group: group, depth: 0, changes: changes) }
                }
            }
        }
    }

    private func nodeView(_ node: ChangeTree.Node, group: GitChange.Group, depth: Int, changes: GitChanges) -> AnyView {
        switch node {
        case let .file(change, name):
            return AnyView(row(change, name: name, depth: depth, changes: changes, showFolder: false))
        case let .folder(name, path, children):
            let id = group.title + ":" + path
            let open = !model.collapsed.contains(id)
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                Button { model.toggle(id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 12)
                        // A joined row ("Sources/HerdrMac") takes its first folder's icon.
                        icon(FileIconName.name(for: String(name.split(separator: "/").first ?? Substring(name)), isDirectory: true))
                        Text(name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .padding(.leading, 10 + CGFloat(depth) * 14).padding(.trailing, 10).frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name) folder")
                if open {
                    ForEach(children) { child in nodeView(child, group: group, depth: depth + 1, changes: changes) }
                }
            })
        }
    }

    private func row(_ change: GitChange, name: String, depth: Int, changes: GitChanges, showFolder: Bool) -> some View {
        let selected = activeID == RightSidebarView.changeTabID(change, changes: changes)
        let relativeFolder = (String(change.path.dropFirst(changes.prefix.count)) as NSString).deletingLastPathComponent
        return HStack(spacing: 5) {
            Color.clear.frame(width: 12)
            icon(FileIconName.name(for: name, isDirectory: false))
            Text(name).lineLimit(1).truncationMode(.middle).strikethrough(change.isDeleted, color: .secondary)
            if let original = change.originalPath {
                Text("← " + (original as NSString).lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            } else if change.isDeleted {
                Text("deleted · read-only").foregroundStyle(.secondary).lineLimit(1)
            } else if showFolder, !relativeFolder.isEmpty {
                Text(relativeFolder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text(String(change.letter)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(color(change.letter))
        }
        .font(.system(size: 12))
        .padding(.leading, 10 + CGFloat(depth) * 14).padding(.trailing, 12).frame(height: 24)
        .background(selected ? herdrAccentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay { if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(herdrAccentColor.opacity(0.6)) } }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(change, true) }
        .onTapGesture { onOpen(change, false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(description(change))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(change, false) }
        .contextMenu {
            Button("Open Diff") { onOpen(change, true) }
            Button("Copy Path") { FileOutlineView.Coordinator.copy(changes.absolutePath(change.path)) }
            Button("Copy Relative Path") { FileOutlineView.Coordinator.copy(String(change.path.dropFirst(changes.prefix.count))) }
        }
    }

    private func description(_ change: GitChange) -> String {
        switch change.letter {
        case "M": return "modified"
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "C": return change.group == .conflicts ? "conflict" : "copied"
        case "U": return "untracked"
        case "T": return "type changed"
        default: return String(change.letter)
        }
    }

    private func color(_ letter: Character) -> Color {
        switch letter {
        case "M", "T": return .orange
        case "A", "U": return .green
        case "D", "C": return .red
        case "R": return .blue
        default: return .secondary
        }
    }

    private func icon(_ name: String) -> some View {
        Group {
            if let image = FileIcon.image(named: name) { Image(nsImage: image).resizable() } else { Color.clear }
        }
        .frame(width: 14, height: 14)
    }

    private func outsideNote(_ count: Int) -> some View {
        Label(count == 1 ? "1 more change outside this space's folder is not shown."
                         : "\(count) more changes outside this space's folder are not shown.",
              systemImage: "exclamationmark.triangle")
            .font(.system(size: 11)).foregroundStyle(.yellow)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func failure(_ error: GitChangesError) -> some View {
        let folder = model.root.map(abbreviated) ?? "This folder"
        switch error {
        case .notRepository:
            return empty("Not a Git repository", "\(folder) isn't inside a Git repository, so there are no changes to show. Files and Search still work.",
                         systemImage: "arrow.triangle.branch")
        case .gitMissing:
            return empty("Git isn't installed on \(deviceName)",
                         isRemote ? "Install git on that device to see changes here. Files and Search still work."
                                  : "Install Apple's Command Line Tools (xcode-select --install) to see changes here. Files and Search still work.",
                         systemImage: "exclamationmark.triangle")
        case .dubiousOwnership:
            return empty("Git won't read this repository",
                         "Another user owns it. If you trust it, run git config --global --add safe.directory \(model.root ?? "<folder>") on \(deviceName).",
                         systemImage: "lock")
        case .folderMissing:
            return empty("Can't open the folder", "\(folder) is missing or can't be read.", systemImage: "folder.badge.questionmark")
        case let .failed(reason):
            return empty("Can't read changes", reason, systemImage: "exclamationmark.triangle")
        }
    }

    private func empty(_ title: String, _ detail: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func collapseAll(_ changes: GitChanges) {
        var ids = Set<String>()
        for group in GitChange.Group.allCases {
            let rows = changes.changes.filter { $0.group == group }
            guard !rows.isEmpty else { continue }
            func walk(_ nodes: [ChangeTree.Node]) {
                for case let .folder(_, path, children) in nodes { ids.insert(group.title + ":" + path); walk(children) }
            }
            walk(ChangeTree.build(rows, prefix: changes.prefix))
        }
        model.collapsed = ids
    }

    private func abbreviated(_ path: String) -> String {
        guard !isRemote else { return path }
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
