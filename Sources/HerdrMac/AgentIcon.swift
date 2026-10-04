import SwiftUI
import AppKit

/// Official agent marks, bundled by herdr agent id (see
/// Resources/AgentIcons/SOURCES.md). Agents without one show ✦.
@MainActor
enum AgentIcon {
    nonisolated static let resourceBundleName = "HerdrMac_HerdrMac.bundle"

    /// Packaged apps keep resource bundles in Contents/Resources; command-line
    /// builds keep them beside the executable. SwiftPM's Bundle.module is not
    /// used: it stops the app when the bundle is missing.
    nonisolated static let directory: URL? = {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for base in candidates.compactMap({ $0 }) {
            // Bundle resolves both the flat and the Contents/Resources layout.
            if let bundle = Bundle(url: base.appendingPathComponent(resourceBundleName)),
               let folder = bundle.url(forResource: "AgentIcons", withExtension: nil) { return folder }
        }
        return nil
    }()

    /// White-only marks: drawn in the text colour so they show in light mode too.
    nonisolated static let templateMarks: Set<String> = ["codex", "copilot", "pi"]

    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    /// herdr agent ids are short lowercase names; anything else has no icon.
    static func fileName(for agent: String?) -> String? {
        guard let id = agent?.lowercased(), !id.isEmpty, id.count <= 32,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return id + ".png"
    }

    static func image(for agent: String?, in directory: URL? = directory) -> NSImage? {
        guard let name = fileName(for: agent), let directory else { return nil }
        if let image = cache[name] { return image }
        guard !missing.contains(name) else { return nil }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(name)) else {
            missing.insert(name)
            return nil
        }
        image.isTemplate = templateMarks.contains(String(name.dropLast(4)))
        cache[name] = image
        return image
    }
}

/// An agent's mark at a fixed point size, or ✦ when it has none.
struct AgentIconView: View {
    let agent: String?
    let size: CGFloat

    var body: some View {
        if let image = AgentIcon.image(for: agent) {
            Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 3 / 14))
                .accessibilityLabel(agent ?? "Agent")
        } else {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
                .accessibilityLabel(agent ?? "Agent")
        }
    }
}

extension AgentIcon {
    /// One entry per agent pane, in pane order; at most `limit` are drawn.
    nonisolated static func stack(_ agents: [String], limit: Int = 3) -> (shown: [String], extra: Int) {
        let shown = Array(agents.prefix(limit))
        return (shown, agents.count - shown.count)
    }
}

/// A tab's agents as overlapping marks, with "+N" past the limit.
struct AgentIconStack: View {
    let agents: [String]
    var size: CGFloat = 12
    var background: Color = .clear

    var body: some View {
        let (shown, extra) = AgentIcon.stack(agents)
        HStack(spacing: 2) {
            HStack(spacing: -size * 0.4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, agent in
                    AgentIconView(agent: agent, size: size)
                        .padding(1)
                        .background(background, in: RoundedRectangle(cornerRadius: size * 4 / 14))
                        .zIndex(Double(shown.count - index))
                }
            }
            if extra > 0 {
                Text("+\(extra)").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agents.joined(separator: ", "))
    }
}
