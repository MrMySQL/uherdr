import HerdrCore
import SwiftUI

/// Receives immutable, already matched token runs; has no session/network knowledge.
struct SidebarRowView: View {
    let rows: [[SidebarTokenRun]]
    var rowGap: UInt16 = 0
    private static let maximumRenderedRowGap: UInt16 = 4
    @Environment(\.resolvedAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    private var palette: NativePalette { NativePalette(snapshot: appearance, colorScheme: colorScheme) }
    private var renderedRowSpacing: CGFloat {
        4 + CGFloat(min(rowGap, Self.maximumRenderedRowGap)) * 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: renderedRowSpacing) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    ForEach(rows[index].indices, id: \.self) { offset in
                        let run = rows[index][offset]
                        if offset > 0 {
                            Text(rows[index][offset - 1].token == "state_icon" || run.token == "git_status" ? " " : " · ")
                                .foregroundStyle(palette.color("secondary_text"))
                        }
                        token(run)
                    }
                }.lineLimit(1)
            }
        }.font(.system(size: 12)).accessibilityElement(children: .combine)
    }

    @ViewBuilder private func token(_ run: SidebarTokenRun) -> some View {
        Group {
            if run.token == "state_icon" {
                Image(systemName: icon(run.status)).accessibilityLabel(run.status.label)
            } else { Text(run.value) }
        }
        .fontWeight(run.style.bold == true ? .bold : .regular)
        .foregroundStyle(color(run))
        .opacity(run.style.dim == true ? 0.55 : 1)
    }
    private func color(_ run: SidebarTokenRun) -> Color {
        if case .rgb(let r, let g, let b) = run.style.foreground {
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
        guard run.token == "state_icon" || run.token == "state_text" else { return palette.color("text") }
        switch run.status {
        case .working: return palette.color("status_working")
        case .blocked: return palette.color("status_blocked")
        case .done: return palette.color("status_done")
        default: return palette.color("secondary_text")
        }
    }
    private func icon(_ status: AgentStatus) -> String {
        switch status {
        case .working: "arrow.triangle.2.circlepath"
        case .blocked: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "pause.circle"
        case .unknown: "questionmark.circle"
        }
    }
}
