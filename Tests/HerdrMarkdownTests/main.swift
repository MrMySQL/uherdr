import Foundation
import HerdrMarkdown

func check(_ ok: Bool, _ label: String, file: StaticString = #fileID, line: UInt = #line) {
    precondition(ok, label, file: file, line: line)
}

let doc = """
# uHerdr client for macOS

A **native** client. ~~old~~ new. See https://example.com and [the guide](docs/guide.md#build-and-run).

| Key | Action |
| --- | --- |
| ⌘S | Save |

- [x] done
- [ ] todo

<img src="docs/shot.png" alt="Screenshot" width="600">

<script>alert(1)</script>

## Build and run
## Build and run

```swift
let x = 1
```

[outside](../../etc/passwd) and [mail](mailto:a@b.c)
"""
let body = MarkdownRenderer.body(doc)
check(body.contains("<h1 id=\"uherdr-client-for-macos\">"), "heading ids")
check(body.contains("<h2 id=\"build-and-run\">") && body.contains("<h2 id=\"build-and-run-1\">"), "repeated headings get -1")
check(body.contains("<table>") && body.contains("<td>⌘S</td>"), "tables")
check(body.contains("<del>old</del>"), "strikethrough")
check(body.contains("<a href=\"https://example.com\">"), "autolinks")
check(body.contains("type=\"checkbox\" checked=\"\" disabled=\"\""), "task lists")
check(body.contains("<img src=\"docs/shot.png\""), "raw HTML images kept (READMEs use them)")
check(body.contains("<pre lang=\"swift\"><code>") || body.contains("<pre><code class=\"language-swift\">"), "code blocks")

let page = MarkdownRenderer.page(doc, title: "README <x>") { href in href.hasPrefix("../") ? "Outside this space's folder" : nil }
check(page.contains("default-src 'none'") && page.contains("img-src https: http: data: uherdr-asset:"), "CSP")
check(!MarkdownRenderer.contentSecurityPolicy.contains("script-src"), "no script source allowed at all")
check(page.contains("<meta name=\"referrer\" content=\"no-referrer\">"), "no referrer")
check(page.contains("<title>README &lt;x&gt;</title>"), "title escaped")
check(page.contains("<a class=\"disabled\" title=\"Outside this space&#39;s folder\" data-href=\"../../etc/passwd\"") ||
      page.contains("<a class=\"disabled\" title=\"Outside this space's folder\" data-href=\"../../etc/passwd\""), "outside links disabled with a reason")
check(!page.contains("<a href=\"../../etc/passwd\""), "a disabled link keeps no href")
check(page.contains("<a href=\"mailto:a@b.c\">"), "other links untouched")
check(MarkdownRenderer.slugify("Hello, World & More!") == "hello-world--more", "slugs like GitHub")
check(MarkdownRenderer.body("") == "", "empty document")
print("PASS: markdown: GitHub syntax (tables, strikethrough, autolinks, task lists, code), raw images kept, heading ids, page with CSP and no referrer, outside links disabled")
