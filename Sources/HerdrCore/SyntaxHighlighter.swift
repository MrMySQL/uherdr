import Foundation

/// A light, approximate syntax highlighter for the editor: one pass over the
/// text that marks comments, strings, numbers, keywords and type names. It is
/// not a parser; it only colours text and never changes it.
public enum SyntaxHighlighter {
    public enum Token: Equatable, Sendable { case comment, string, number, keyword, type, key, heading }

    public struct Span: Equatable, Sendable {
        /// UTF-16 range, as NSTextView uses.
        public let range: NSRange
        public let token: Token
        public init(_ range: NSRange, _ token: Token) { self.range = range; self.token = token }
    }

    public enum Language: String, CaseIterable, Sendable {
        case swift, javascript, typescript, python, go, rust, json, yaml, shell, markdown

        public static func forFile(_ name: String) -> Language? {
            let lower = name.lowercased()
            if lower == "dockerfile" || lower == "makefile" { return .shell }
            switch (lower as NSString).pathExtension {
            case "swift": return .swift
            case "js", "mjs", "cjs", "jsx": return .javascript
            case "ts", "mts", "tsx": return .typescript
            case "py": return .python
            case "go": return .go
            case "rs": return .rust
            case "json", "jsonc", "resolved": return .json
            case "yml", "yaml": return .yaml
            case "sh", "bash", "zsh": return .shell
            case "md", "markdown": return .markdown
            default: return nil
            }
        }

        public var displayName: String {
            switch self {
            case .swift: return "Swift"
            case .javascript: return "JavaScript"
            case .typescript: return "TypeScript"
            case .python: return "Python"
            case .go: return "Go"
            case .rust: return "Rust"
            case .json: return "JSON"
            case .yaml: return "YAML"
            case .shell: return "Shell"
            case .markdown: return "Markdown"
            }
        }
    }

    struct Rules {
        var lineComments: [String] = []
        var blockComment: (String, String)?
        var quotes: [Character] = ["\""]
        var keywords: Set<String> = []
        var capitalizedAreTypes = false
    }

    static func rules(_ language: Language) -> Rules {
        switch language {
        case .swift:
            return Rules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: [
                "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default",
                "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for",
                "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated",
                "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self",
                "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
                "typealias", "var", "where", "while", "weak", "lazy", "mutating", "any"], capitalizedAreTypes: true)
        case .javascript, .typescript:
            var keywords: Set<String> = [
                "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
                "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in",
                "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
                "try", "typeof", "undefined", "var", "void", "while", "yield"]
            if language == .typescript {
                keywords.formUnion(["abstract", "any", "as", "boolean", "declare", "enum", "implements", "interface",
                                    "keyof", "namespace", "never", "number", "private", "protected", "public", "readonly",
                                    "string", "type", "unknown"])
            }
            return Rules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], keywords: keywords, capitalizedAreTypes: true)
        case .python:
            return Rules(lineComments: ["#"], quotes: ["\"", "'"], keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None",
                "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"], capitalizedAreTypes: true)
        case .go:
            return Rules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "`", "'"], keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
                "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select",
                "struct", "switch", "true", "type", "var"], capitalizedAreTypes: true)
        case .rust:
            return Rules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
                "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"], capitalizedAreTypes: true)
        case .json:
            return Rules(quotes: ["\""], keywords: ["true", "false", "null"])
        case .yaml:
            return Rules(lineComments: ["#"], quotes: ["\"", "'"], keywords: ["true", "false", "null", "yes", "no", "on", "off"])
        case .shell:
            return Rules(lineComments: ["#"], quotes: ["\"", "'"], keywords: [
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
                "function", "return", "export", "local", "set", "echo", "exit", "source", "readonly", "shift"])
        case .markdown:
            return Rules()
        }
    }

    /// Spans for at most `limit` UTF-16 units of the text (large files only
    /// get their beginning coloured, so opening them stays fast).
    public static func spans(for text: String, language: Language, limit: Int = 400_000) -> [Span] {
        let units = Array(text.utf16.prefix(limit))
        if language == .markdown { return markdown(units) }
        let rules = rules(language)
        var spans: [Span] = []
        var i = 0
        let n = units.count
        func starts(with token: String, at index: Int) -> Bool {
            let t = Array(token.utf16)
            guard index + t.count <= n else { return false }
            for k in 0..<t.count where units[index + k] != t[k] { return false }
            return true
        }
        func isIdentStart(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u > 127 }
        func isIdent(_ u: UInt16) -> Bool { isIdentStart(u) || (u >= 48 && u <= 57) }
        while i < n {
            let u = units[i]
            // Line comments run to the end of the line.
            if let marker = rules.lineComments.first(where: { starts(with: $0, at: i) }),
               marker != "#" || i == 0 || !isIdent(units[i - 1]) {
                var j = i
                while j < n && units[j] != 10 { j += 1 }
                spans.append(Span(NSRange(location: i, length: j - i), .comment))
                i = j
                continue
            }
            if let (open, close) = rules.blockComment, starts(with: open, at: i) {
                var j = i + open.utf16.count
                while j < n && !starts(with: close, at: j) { j += 1 }
                j = min(n, j + close.utf16.count)
                spans.append(Span(NSRange(location: i, length: j - i), .comment))
                i = j
                continue
            }
            if let quote = rules.quotes.first(where: { $0.utf16.first == u }) {
                let q = quote.utf16.first!
                var j = i + 1
                var closed = false
                while j < n {
                    if units[j] == q { closed = true; break }
                    if units[j] == 92 { j += 1 } // backslash escape
                    else if units[j] == 10 && q != 96 { break } // only backticks span lines
                    j += 1
                }
                // A closing quote belongs to the string; a line break never does.
                j = min(n, closed ? j + 1 : j)
                // A JSON or YAML string followed by a colon is a key.
                var k = j
                while k < n && (units[k] == 32 || units[k] == 9) { k += 1 }
                let isKey = (language == .json || language == .yaml) && k < n && units[k] == 58
                spans.append(Span(NSRange(location: i, length: j - i), isKey ? .key : .string))
                i = j
                continue
            }
            if u >= 48 && u <= 57, i == 0 || !isIdent(units[i - 1]) {
                var j = i + 1
                while j < n && (isIdent(units[j]) || units[j] == 46) { j += 1 }
                spans.append(Span(NSRange(location: i, length: j - i), .number))
                i = j
                continue
            }
            if isIdentStart(u) {
                var j = i + 1
                while j < n && isIdent(units[j]) { j += 1 }
                let word = String(decoding: units[i..<j], as: UTF16.self)
                if language == .yaml, isYAMLKey(units, from: i, to: j) {
                    spans.append(Span(NSRange(location: i, length: j - i), .key))
                } else if rules.keywords.contains(word) {
                    spans.append(Span(NSRange(location: i, length: j - i), .keyword))
                } else if rules.capitalizedAreTypes, u >= 65 && u <= 90 {
                    spans.append(Span(NSRange(location: i, length: j - i), .type))
                }
                i = j
                continue
            }
            i += 1
        }
        return spans
    }

    /// A plain YAML key: first word on its line, followed by a colon.
    static func isYAMLKey(_ units: [UInt16], from start: Int, to end: Int) -> Bool {
        var k = start - 1
        while k >= 0 && (units[k] == 32 || units[k] == 45) { k -= 1 } // spaces and "- " list markers
        guard k < 0 || units[k] == 10 else { return false }
        var j = end
        while j < units.count && (units[j] == 45 || units[j] == 46 || (units[j] >= 48 && units[j] <= 57)
                                  || (units[j] >= 65 && units[j] <= 90) || (units[j] >= 97 && units[j] <= 122) || units[j] == 95) { j += 1 }
        return j < units.count && units[j] == 58
    }

    /// Markdown: headings, fenced code blocks and inline code.
    static func markdown(_ units: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var lineStart = 0
        var inFence = false
        var fenceStart = 0
        let n = units.count
        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n && units[lineEnd] != 10 { lineEnd += 1 }
            let line = units[lineStart..<lineEnd]
            let isFence = line.starts(with: Array("```".utf16))
            if isFence {
                if inFence { spans.append(Span(NSRange(location: fenceStart, length: lineEnd - fenceStart), .string)) }
                else { fenceStart = lineStart }
                inFence.toggle()
            } else if !inFence {
                if line.first == 35 { spans.append(Span(NSRange(location: lineStart, length: lineEnd - lineStart), .heading)) }
                else {
                    var i = lineStart
                    while i < lineEnd {
                        if units[i] == 96, let close = (i + 1..<lineEnd).first(where: { units[$0] == 96 }) {
                            spans.append(Span(NSRange(location: i, length: close - i + 1), .string))
                            i = close + 1
                        } else { i += 1 }
                    }
                }
            }
            lineStart = lineEnd + 1
        }
        if inFence { spans.append(Span(NSRange(location: fenceStart, length: n - fenceStart), .string)) }
        return spans
    }
}
