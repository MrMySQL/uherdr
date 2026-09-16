import AppKit
import UniformTypeIdentifiers
import HerdrCore

/// Reads file representations only for a user-initiated paste. Raw media is
/// staged privately so local and SSH harnesses receive readable files alike.
struct TerminalClipboardFiles {
    let urls: [URL]
    let directory: URL?

    static func hasFiles(_ board: NSPasteboard) -> Bool {
        (board.pasteboardItems ?? []).contains { item in
            item.types.contains(.fileURL) || mediaType(item) != nil
        }
    }

    static func read(_ board: NSPasteboard) throws -> Self {
        var urls: [URL] = []
        var directory: URL?
        do {
            for item in board.pasteboardItems ?? [] {
                if let value = item.string(forType: .fileURL) {
                    guard let url = URL(string: value), url.isFileURL,
                          !url.path.isEmpty, url.path.rangeOfCharacter(from: .controlCharacters) == nil else {
                        throw HerdrError.message("The clipboard contains an invalid file path.")
                    }
                    urls.append(url)
                    continue
                }
                guard let type = mediaType(item) else { continue }
                guard var data = item.data(forType: type), !data.isEmpty else {
                    throw HerdrError.message("The clipboard media could not be read.")
                }
                var ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "dat"
                // Screenshots commonly supply TIFF. PNG is accepted by both
                // agent CLIs and preserves transparency without JPEG loss.
                if type == .tiff {
                    guard let bitmap = NSBitmapImageRep(data: data),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw HerdrError.message("The clipboard image could not be decoded.")
                    }
                    data = png
                    ext = "png"
                }
                if directory == nil {
                    let root = FileManager.default.temporaryDirectory
                        .appendingPathComponent("herdr-clipboard-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o700])
                    directory = root
                }
                let url = directory!.appendingPathComponent("attachment-\(urls.count + 1).\(ext)")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }
            return Self(urls: urls, directory: directory)
        } catch {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    func discard() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private static func mediaType(_ item: NSPasteboardItem) -> NSPasteboard.PasteboardType? {
        // Prefer existing PNG bytes when an item offers multiple encodings.
        if item.types.contains(.png) { return .png }
        return item.types.first {
            guard let type = UTType($0.rawValue) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }
    }
}
