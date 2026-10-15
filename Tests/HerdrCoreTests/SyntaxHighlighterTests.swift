import Foundation
import HerdrCore

enum SyntaxHighlighterTests {
    static func run() {
        typealias T = SyntaxHighlighter.Token
        func marked(_ text: String, _ language: SyntaxHighlighter.Language) -> [(String, T)] {
            let ns = text as NSString
            return SyntaxHighlighter.spans(for: text, language: language).map { (ns.substring(with: $0.range), $0.token) }
        }
        func check(_ text: String, _ language: SyntaxHighlighter.Language, _ expected: [(String, T)], line: UInt = #line) {
            let got = marked(text, language)
            XCTAssertEqual(got.map(\.0), expected.map(\.0), line: line)
            XCTAssertEqual(got.map(\.1), expected.map(\.1), line: line)
        }
        check(#"let x = "a // not a comment" // real"#, .swift, [("let", .keyword), ("\"a // not a comment\"", .string), ("// real", .comment)])
        check("/* block\n spans */ func f() -> Int { return 42 }", .swift,
              [("/* block\n spans */", .comment), ("func", .keyword), ("Int", .type), ("return", .keyword), ("42", .number)])
        check(#"let s = "esc \" quote""#, .swift, [("let", .keyword), (#""esc \" quote""#, .string)])
        check("x1 = 3.14", .swift, [("3.14", .number)])
        check("const t = `a\nb`; // c", .typescript, [("const", .keyword), ("`a\nb`", .string), ("// c", .comment)])
        check("interface A {}", .typescript, [("interface", .keyword), ("A", .type)])
        check("interface A {}", .javascript, [("A", .type)])
        check("def f(): # note\n  return None", .python, [("def", .keyword), ("# note", .comment), ("return", .keyword), ("None", .keyword)])
        check(#"{"name": "uherdr", "n": 2, "ok": true}"#, .json, [("\"name\"", .key), ("\"uherdr\"", .string), ("\"n\"", .key), ("2", .number), ("\"ok\"", .key), ("true", .keyword)])
        check("name: x\n- item: true # c\nurl: a#b", .yaml, [("name", .key), ("item", .key), ("true", .keyword), ("# c", .comment), ("url", .key)])
        check("echo \"$HOME\" # hi\nfoo#bar", .shell, [("echo", .keyword), ("\"$HOME\"", .string), ("# hi", .comment)])
        check("# Title\ntext `code` more\n```\nlet x\n```\n", .markdown, [("# Title", .heading), ("`code`", .string), ("```\nlet x\n```", .string)])
        // An unterminated string or comment stops at the end, never past it.
        check("let s = \"open", .swift, [("let", .keyword), ("\"open", .string)])
        check("/* open", .swift, [("/* open", .comment)])
        // A quote left open stops at the line end, so the next line still colours.
        check("let a = \"open\nlet b = 1", .swift, [("let", .keyword), ("\"open", .string), ("let", .keyword), ("1", .number)])
        // Ranges are UTF-16, matching NSTextView, after emoji and accents.
        let emoji = "let 😀 = \"ü\""
        let span = SyntaxHighlighter.spans(for: emoji, language: .swift).last!
        XCTAssertEqual((emoji as NSString).substring(with: span.range), "\"ü\"")
        // Only the first part of a huge file is scanned.
        XCTAssertTrue(SyntaxHighlighter.spans(for: String(repeating: "let ", count: 1000), language: .swift, limit: 40).count == 10)
        XCTAssertEqual(SyntaxHighlighter.Language.forFile("SessionStore.swift"), .swift)
        XCTAssertEqual(SyntaxHighlighter.Language.forFile("page.tsx"), .typescript)
        XCTAssertEqual(SyntaxHighlighter.Language.forFile("Package.resolved"), .json)
        XCTAssertTrue(SyntaxHighlighter.Language.forFile("notes.txt") == nil)
        print("PASS: syntax highlighting: comments, strings with escapes, numbers, keywords, types, JSON/YAML keys, Markdown, unterminated input, UTF-16 ranges, scan limit")
    }
}
