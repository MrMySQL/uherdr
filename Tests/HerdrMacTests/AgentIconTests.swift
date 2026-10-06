import AppKit

@main struct AgentIconTests {
    // Agent ids herdr 0.9.3 detects (its agent-detection manifests).
    static let herdrAgents = ["agy", "amp", "claude", "cline", "codex", "copilot", "cursor", "devin", "droid", "gemini",
                              "grok", "hermes", "kilo", "kimi", "kiro", "letta", "maki", "muse", "opencode", "pi", "qodercli", "qwen"]
    // No official mark was found for these; they keep ✦.
    static let fallbacks: Set<String> = ["muse"]

    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the AgentIcons resource folder") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let icons = Set(files.filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
        precondition(icons.count == 21, "Expected 21 bundled marks, found \(icons.count)")
        for id in herdrAgents {
            let image = AgentIcon.image(for: id, in: folder)
            precondition((image == nil) == fallbacks.contains(id), "\(id): mark present must match the fallback list")
        }
        precondition(icons.subtracting(herdrAgents).isEmpty, "Every mark is for an agent herdr detects")
        // Each mark is sharp enough for 14 pt on Retina and no larger than needed.
        for id in icons {
            guard let rep = NSImage(contentsOf: folder.appendingPathComponent(id + ".png"))?.representations.first else {
                preconditionFailure("\(id).png does not load")
            }
            precondition((48...64).contains(rep.pixelsWide) && rep.pixelsWide == rep.pixelsHigh, "\(id).png is \(rep.pixelsWide)×\(rep.pixelsHigh)")
        }
        // Exactly the white-only marks are drawn in the text colour.
        var whiteOnly: Set<String> = []
        for id in icons {
            let rep = NSBitmapImageRep(data: try! Data(contentsOf: folder.appendingPathComponent(id + ".png")))!
            var opaque = 0, light = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent >= 0.1 else { continue }
                opaque += 1
                if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.85 { light += 1 }
            } }
            if opaque > 0 && light == opaque { whiteOnly.insert(id) }
        }
        precondition(whiteOnly == AgentIcon.templateMarks, "Template marks \(AgentIcon.templateMarks) must equal the white-only marks \(whiteOnly)")
        precondition(AgentIcon.image(for: "codex", in: folder)?.isTemplate == true && AgentIcon.image(for: "claude", in: folder)?.isTemplate == false)
        // Every mark has a recorded official source, and every source has a mark.
        let sources = (try? String(contentsOf: folder.appendingPathComponent("SOURCES.md"), encoding: .utf8)) ?? ""
        let listed = Set(sources.split(separator: "\n").compactMap { line -> String? in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("| "), cells.count >= 4, cells[3].hasPrefix("https://"), cells[0] != "id" else { return nil }
            return cells[0]
        })
        precondition(listed == icons, "SOURCES.md must list exactly the bundled marks: \(listed.symmetricDifference(icons))")
        // Lookup ignores case, and odd ids never reach the file system.
        precondition(AgentIcon.image(for: "Claude", in: folder) != nil)
        for id: String? in [nil, "", "../claude", "claude/../codex", "cla ude", String(repeating: "a", count: 40)] {
            precondition(AgentIcon.image(for: id, in: folder) == nil, "\(id ?? "nil") must have no icon")
        }
        precondition(AgentIcon.image(for: "claude", in: nil) == nil, "A missing resource folder falls back to ✦")
        // Tabs stack one mark per agent pane, three at most, then "+N".
        precondition(AgentIcon.stack([]) == ([], 0))
        precondition(AgentIcon.stack(["claude", "codex"]) == (["claude", "codex"], 0))
        precondition(AgentIcon.stack(["claude", "claude", "codex", "gemini", "pi"]) == (["claude", "claude", "codex"], 2))
        print("PASS: every herdr agent has an official mark or the ✦ fallback, with sources and Retina sizes")
    }
}
