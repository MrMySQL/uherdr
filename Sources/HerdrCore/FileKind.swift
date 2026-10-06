import Foundation

/// Which viewer a file gets: text in the editor (Markdown also has a
/// preview), images and PDFs in read-only viewers. Anything else that isn't
/// text shows "Can't show this file" (frame 18).
public enum FileKind: Equatable, Sendable {
    case text
    case markdown
    case image
    case pdf

    public static func of(_ name: String) -> FileKind {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "tif", "tiff", "bmp", "ico": return .image
        case "pdf": return .pdf
        default: return .text
        }
    }
}

/// What a link in the Markdown preview does. A link to a file inside the
/// space opens it in uHerdr; one leading outside the space is shown disabled;
/// http(s) and mailto open outside uHerdr; nothing ever navigates the preview.
public enum MarkdownLink: Equatable, Sendable {
    /// Opens in the browser (or mail).
    case external(URL)
    /// A file inside the space, with an optional `#heading`.
    case file(path: String, fragment: String?)
    /// A heading in the same document.
    case anchor(String)
    /// Outside the space, or a kind of link uHerdr doesn't follow.
    case disabled(reason: String)

    /// `href` as written in the Markdown; `document` is the Markdown file's
    /// path and `root` the space folder, both absolute on the device. A
    /// leading "/" means the space folder, as GitHub does for a repository.
    public static func resolve(_ href: String, document: String, root: String) -> MarkdownLink {
        let trimmed = href.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .disabled(reason: "Empty link") }
        if trimmed.hasPrefix("#") { return .anchor(decode(String(trimmed.dropFirst()))) }
        if let scheme = scheme(of: trimmed) {
            switch scheme {
            case "http", "https", "mailto":
                guard let url = URL(string: trimmed) else { return .disabled(reason: "Not a valid link") }
                return .external(url)
            default:
                return .disabled(reason: "\(scheme): links don't open from the preview")
            }
        }
        var target = trimmed
        var fragment: String?
        if let hash = target.firstIndex(of: "#") {
            fragment = decode(String(target[target.index(after: hash)...]))
            target = String(target[..<hash])
        }
        if let query = target.firstIndex(of: "?") { target = String(target[..<query]) }
        target = decode(target)
        let base = target.hasPrefix("/") ? root : (document as NSString).deletingLastPathComponent
        let joined = normalize(base + "/" + target)
        let top = normalize(root)
        guard joined == top || joined.hasPrefix(top == "/" ? "/" : top + "/") else {
            return .disabled(reason: "Outside this space's folder")
        }
        return .file(path: joined, fragment: fragment?.isEmpty == true ? nil : fragment)
    }

    private static func scheme(of href: String) -> String? {
        guard let colon = href.firstIndex(of: ":") else { return nil }
        let candidate = href[..<colon]
        guard let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
        return candidate.lowercased()
    }

    private static func decode(_ text: String) -> String { text.removingPercentEncoding ?? text }

    /// Removes "." and resolves ".." lexically (a link's text, not the disk).
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// What Go to Line (⌘L) accepts: "12" is line 12, "12:5" is line 12, column 5.
public enum LineTarget {
    public static func parse(_ text: String) -> (line: Int, column: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let line = Int(parts[0]), line > 0 else { return nil }
        if parts.count == 2 { guard let column = Int(parts[1]), column > 0 else { return nil }; return (line, column) }
        return (line, 1)
    }
}
