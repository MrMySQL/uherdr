import AppKit
import SwiftUI
import HerdrCore

/// The Files tree: an AppKit outline (lazy folders, keyboard navigation and
/// stable scrolling for large trees) over `FileTreeModel`.
struct FileOutlineView: NSViewRepresentable {
    @ObservedObject var model: FileTreeModel
    /// Called when the tree takes the keyboard, so terminals stop reclaiming it.
    var onFocus: () -> Void = {}
    /// A file was clicked (keep: false, a preview) or double-clicked (keep:
    /// true); outsideLink marks a symlink to a file outside the space.
    var onOpen: (_ path: String, _ keep: Bool, _ outsideLink: Bool) -> Void = { _, _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FocusReportingOutlineView()
        outline.onFocus = onFocus
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.allowsMultipleSelection = false
        outline.autoresizesOutlineColumn = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.setAccessibilityLabel("Files")
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.clicked)
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        context.coordinator.onOpen = onOpen
        context.coordinator.outline = outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.sync()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.onOpen = onOpen
        if context.coordinator.syncedRevision != model.revision { context.coordinator.sync() }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var model: FileTreeModel
        var onOpen: (String, Bool, Bool) -> Void = { _, _, _ in }
        weak var outline: NSOutlineView?
        var syncedRevision = -1
        private var syncing = false
        private var nodes: [String: Node] = [:]

        final class Node: NSObject {
            let path: String
            var entry: FileEntry?
            init(path: String) { self.path = path }
        }

        init(model: FileTreeModel) { self.model = model }

        private func node(_ entry: FileEntry) -> Node {
            let node = nodes[entry.path] ?? Node(path: entry.path)
            node.entry = entry
            nodes[entry.path] = node
            return node
        }

        /// Reloads the rows, then re-opens and re-selects what the model says.
        func sync() {
            guard let outline else { return }
            syncing = true
            defer { syncing = false; syncedRevision = model.revision }
            outline.reloadData()
            // Rows are created lazily, when drawn, so each open folder is found
            // through the outline itself, shallowest first: that creates every
            // row on the way down before it is expanded.
            for path in model.expanded.sorted(by: { $0.count < $1.count }) {
                if let node = item(for: path, in: outline) { outline.expandItem(node) }
            }
            if let selection = model.selection, let node = item(for: selection, in: outline) {
                let row = outline.row(forItem: node)
                if row >= 0 {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            } else {
                outline.deselectAll(nil)
            }
        }

        /// The row for a path, asking the outline for each level from the top.
        /// Nil when a folder on the way is closed, filtered out or not loaded.
        private func item(for path: String, in outline: NSOutlineView) -> Node? {
            guard let root = model.canonicalRoot, path.hasPrefix(root + "/") else { return nil }
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent: Node?
            if parentPath == root {
                parent = nil
            } else {
                guard let found = item(for: parentPath, in: outline), outline.isItemExpanded(found) else { return nil }
                parent = found
            }
            for index in 0..<outline.numberOfChildren(ofItem: parent) {
                if let child = outline.child(index, ofItem: parent) as? Node, child.path == path { return child }
            }
            return nil
        }

        private func entries(of item: Any?) -> [FileEntry] {
            if let node = item as? Node { return model.children(of: node.entry.map(listingPath) ?? node.path) }
            guard let root = model.canonicalRoot else { return [] }
            return model.children(of: root)
        }

        /// On this Mac a link to a folder inside the space lists its resolved
        /// target; an SSH device's script lists through the link itself.
        func listingPath(_ entry: FileEntry) -> String {
            if case .symlink = entry.kind, !model.isRemote { return PathBoundary.canonical(entry.path) ?? entry.path }
            return entry.path
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { entries(of: item).count }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            node(entries(of: item)[index])
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Node)?.entry?.isExpandable ?? false
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? Node, let entry = node.entry else { return }
            model.setExpanded(listingPath(entry), true)
            if listingPath(entry) != node.path { model.setExpanded(node.path, true) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? Node else { return }
            model.setExpanded(node.path, false)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            model.selection = (outline.item(atRow: outline.selectedRow) as? Node)?.path
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let entry = node.entry else { return nil }
            let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
            cell.show(entry, ignored: model.isIgnored(entry), state: model.folders[listingPath(entry)])
            return cell
        }

        @objc func clicked() { openClicked(keep: false) }
        @objc func doubleClicked() { openClicked(keep: true) }

        private func openClicked(keep: Bool) {
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? Node,
                  let entry = node.entry else { return }
            switch entry.kind {
            case .file: onOpen(node.path, keep, false)
            case let .symlink(_, inside, isDirectory) where !isDirectory: onOpen(node.path, keep, !inside)
            default:
                if keep, entry.isExpandable {
                    if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
                }
            }
        }

        // MARK: Right-click menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            let path = node.path
            let relative = model.canonicalRoot.flatMap { root in path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil } ?? path
            menu.addItem(ActionItem("Copy Path") { Self.copy(path) })
            menu.addItem(ActionItem("Copy Relative Path") { Self.copy(relative) })
            if !model.isRemote {
                menu.addItem(.separator())
                menu.addItem(ActionItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
            }
        }

        static func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// Reports when it becomes first responder (a click or Tab into the tree).
final class FocusReportingOutlineView: NSOutlineView {
    var onFocus: () -> Void = {}
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus() }
        return accepted
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func runAction() { run() }
}

/// One Files row: icon, name, and a note for links, unreadable folders and loading.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12)
        note.translatesAutoresizingMaskIntoConstraints = false
        note.lineBreakMode = .byTruncatingTail
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon); addSubview(name); addSubview(note)
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ entry: FileEntry, ignored: Bool, state: FileTreeModel.FolderState?) {
        let isFolder: Bool
        var noteText = ""
        var noteColor = NSColor.tertiaryLabelColor
        switch entry.kind {
        case .directory: isFolder = true
        case let .symlink(target, inside, isDirectory):
            isFolder = isDirectory
            noteText = "→ " + target + (inside ? "" : " · read-only")
        default: isFolder = false
        }
        if case .failed(let message)? = state {
            noteText = message.hasPrefix("No permission") ? "No permission" : "Can't read"
            noteColor = .systemRed
        } else if case .loading? = state {
            noteText = "Loading…"
        }
        icon.image = FileIcon.image(named: FileIconName.name(for: entry.name, isDirectory: isFolder))
        name.stringValue = entry.name
        name.textColor = .labelColor
        note.stringValue = noteText
        note.textColor = noteColor
        alphaValue = ignored ? 0.45 : 1
        setAccessibilityLabel(entry.name + (noteText.isEmpty ? "" : ", " + noteText) + (ignored ? ", ignored" : ""))
    }
}

/// Bundled Material icons (Resources/FileIcons), loaded once each.
@MainActor
enum FileIcon {
    static let directory: URL? = AgentIcon.directory?.deletingLastPathComponent().appendingPathComponent("FileIcons")
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let image = cache[name] { return image }
        guard let directory, let image = NSImage(contentsOf: directory.appendingPathComponent(name + ".svg")) else {
            return name == "document" ? nil : image(named: "document")
        }
        image.size = NSSize(width: 16, height: 16)
        cache[name] = image
        return image
    }
}
