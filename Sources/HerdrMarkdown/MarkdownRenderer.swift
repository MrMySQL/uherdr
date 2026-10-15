import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Markdown to HTML for the preview, with GitHub's renderer (cmark-gfm):
/// tables, strikethrough, autolinks and task lists. Raw HTML is kept (READMEs
/// put images in <img> tags); the page that shows it runs without JavaScript,
/// under a strict Content-Security-Policy, and never navigates.
public enum MarkdownRenderer {
    /// The body HTML for a Markdown document.
    public static func body(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_GITHUB_PRE_LANG | CMARK_OPT_FOOTNOTES | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let extensionPointer = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, extensionPointer)
            }
        }
        let bytes = Array(markdown.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { cmark_parser_feed(parser, $0, buffer.count) }
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return addHeadingIDs(String(cString: html))
    }

    /// The Content-Security-Policy of every preview page: no scripts, no
    /// frames, no forms, no network except images (remote images load, as
    /// decided, plus the space's own images through `uherdr-asset:`).
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src https: http: data: uherdr-asset:; style-src 'unsafe-inline'; font-src data:; "
        + "media-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    /// A complete page around the document's HTML. `disabledReason` says,
    /// for a link's href, why it won't open (outside the space); such links
    /// are shown dimmed with the reason as a tooltip, and lose their href.
    public static func page(_ markdown: String, title: String, disabledReason: (String) -> String? = { _ in nil }) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="referrer" content="no-referrer">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head><body><article class="markdown">
        \(disableLinks(body(markdown), disabledReason))
        </article></body></html>
        """
    }

    static func disableLinks(_ html: String, _ reason: (String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<a href=\"([^\"]*)\"") else { return html }
        var result = ""
        var last = html.startIndex
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let whole = Range(match.range, in: html), let href = Range(match.range(at: 1), in: html) else { continue }
            let target = unescape(String(html[href]))
            guard let why = reason(target) else { continue }
            result += html[last..<whole.lowerBound]
            result += "<a class=\"disabled\" title=\"\(escape(why))\" data-href=\"\(html[href])\""
            last = whole.upperBound
        }
        return result + html[last...]
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// GitHub-style ids on headings ("Build and run" → "build-and-run"), so
    /// `#heading` links have somewhere to go. Repeats get "-1", "-2".
    static func addHeadingIDs(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<h([1-6])>(.*?)</h\\1>", options: [.dotMatchesLineSeparators]) else { return html }
        var used: [String: Int] = [:]
        var result = ""
        var last = html.startIndex
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let whole = Range(match.range, in: html), let level = Range(match.range(at: 1), in: html),
                  let inner = Range(match.range(at: 2), in: html) else { continue }
            var slug = slugify(stripTags(String(html[inner])))
            if let count = used[slug] { used[slug] = count + 1; slug += "-\(count + 1)" } else { used[slug] = 0 }
            result += html[last..<whole.lowerBound]
            result += "<h\(html[level]) id=\"\(slug)\">\(html[inner])</h\(html[level])>"
            last = whole.upperBound
        }
        return result + html[last...]
    }

    public static func slugify(_ text: String) -> String {
        let decoded = text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        return String(decoded.lowercased().compactMap { c -> Character? in
            if c.isLetter || c.isNumber || c == "-" || c == "_" { return c }
            if c == " " { return "-" }
            return nil
        })
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// GitHub-like, following the system's light or dark appearance.
    static let css = """
    :root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --code-bg: rgba(129,139,152,.12); --link: #0969da; }
    @media (prefers-color-scheme: dark) { :root { --fg: #e6edf3; --muted: #9198a1; --border: #3d444d; --code-bg: rgba(101,108,118,.2); --link: #4493f8; } }
    html { background: transparent; }
    body { margin: 0; padding: 28px 40px 60px; font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); }
    .markdown { max-width: 920px; margin: 0 auto; overflow-wrap: break-word; }
    h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
    h1, h2, h3, h4, h5, h6 { margin: 1.4em 0 .6em; line-height: 1.25; font-weight: 600; }
    h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
    a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
    a.disabled { color: var(--muted); cursor: not-allowed; text-decoration: line-through dotted; }
    code, pre { font: 13px/1.45 ui-monospace, "SF Mono", Menlo, monospace; }
    code { background: var(--code-bg); padding: .15em .35em; border-radius: 5px; }
    pre { background: var(--code-bg); padding: 14px 16px; border-radius: 7px; overflow: auto; }
    pre code { background: none; padding: 0; }
    blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    table { border-collapse: collapse; display: block; overflow: auto; }
    th, td { border: 1px solid var(--border); padding: 6px 13px; }
    img { max-width: 100%; border-radius: 6px; }
    iframe, object, embed, video, audio, form { display: none; }
    hr { border: 0; border-top: 1px solid var(--border); margin: 24px 0; }
    ul.contains-task-list, li.task-list-item { list-style: none; }
    li.task-list-item input { margin: 0 .4em 0 -1.3em; }
    """
}
