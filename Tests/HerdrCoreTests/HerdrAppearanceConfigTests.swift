import Foundation
import HerdrCore

enum HerdrAppearanceConfigTests {
    static func run() throws {
        let input = """
        # Unrelated values, including TOML dates, must not affect appearance.
        [server]
        port = 9876
        date = 2026-09-16
        [theme]
        name = "catppuccin"
        auto_switch = true
        light_name = "nord"
        dark_name = "terminal"
        future = "ignored"
        [theme.custom]
        accent = "#123456"
        future_color = 123
        [theme.custom.light]
        accent = "#abcdef"
        [ui.sidebar.agents]
        rows = [["state_icon", { token = "$load", fg = "#abc", bold = false, rules = [{ gt = 80, dim = false, hide = true }] }]]
        [ui.sidebar.agents.rows_by_agent]
        codex = [["terminal_title"]]
        [ui.sidebar.spaces]
        row_gap = 65535
        rows = [["workspace"]]
        """
        let value = try HerdrAppearanceConfig.parse(input)
        precondition(value.themeName == "catppuccin" && value.autoSwitch)
        precondition(value.lightName == "nord" && value.darkName == "terminal")
        precondition(value.commonOverrides["accent"] == .rgb(18, 52, 86))
        precondition(value.lightOverrides["accent"] == .rgb(171, 205, 239))
        precondition(value.diagnostics?.count == 2)
        let rule = value.sidebar!.agents!.rows![0][1].rules[0]
        precondition(rule.hide == true && rule.style.dim == false)
        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(HerdrAppearanceConfig.self, from: data)
        precondition(restored == value)
        let defaults = try HerdrAppearanceConfig.parse("[server]\nport = 2")
        precondition(defaults.themeName == "catppuccin" && !defaults.autoSwitch)
        let forwardCompatible = try HerdrAppearanceConfig.parse("""
        [ui.sidebar.spaces]
        rows = [["workspace"]]
        future_nan = nan
        future_inf = inf
        [ui.sidebar.future]
        future_negative_inf = -inf
        """)
        precondition(forwardCompatible.sidebar?.spaces?.rows == [[SidebarOccurrence(token: "workspace")]])
        precondition(forwardCompatible.diagnostics == [
            "Unsupported ui.sidebar.future; ignored.",
            "Unsupported ui.sidebar.spaces.future_inf; ignored.",
            "Unsupported ui.sidebar.spaces.future_nan; ignored.",
        ])
        for (bad, path) in [
            ("[ui.sidebar.spaces]\nrow_gap = inf", "ui.sidebar.spaces.row_gap"),
            ("[ui.sidebar.spaces]\nrows = [[{ token = 'workspace', rules = [{ gt = nan }] }]]", "ui.sidebar.spaces.rows[0][0].rules[0]"),
        ] {
            do { _ = try HerdrAppearanceConfig.parse(bad); preconditionFailure("Accepted non-finite supported value: \(bad)") }
            catch { precondition(error.localizedDescription.contains(path), "Diagnostic did not identify \(path): \(error)") }
        }
        for bad in [
            "[ui.sidebar.agents]\nrows = [[\"unsupported_token\"]]",
            "[theme", "[theme]\nname = 'uherdr'", "[theme]\nname = 'typo'", "[theme]\nauto_switch = 'true'",
            "[theme.custom]\naccent = 'bad'", "[theme.custom]\naccent = 10",
            "[theme.custom.light]\naccent = 'bad'", "theme = 1", "theme = []",
            "[theme]\ncustom = 1", "[theme]\ncustom = []",
            "[theme.custom]\nlight = 1", "[theme.custom]\nlight = []",
            "[theme.custom]\ndark = 1", "[theme.custom]\ndark = []",
            "[ui]\nsidebar = 1", "[ui]\nsidebar = []",
            "[ui.sidebar]\nagents = 1", "[ui.sidebar]\nspaces = []",
            "[ui.sidebar.agents]\nrows_by_agent = []",
            "[ui.sidebar.agents]\nrows = 'bad'",
            "[ui.sidebar.agents]\nrows = [[{ token = 'machine', rules = [{ regex = 'x', bold = true }] }]]",
            "[ui.sidebar.spaces]\nrows = [[{ token = 'workspace', rules = [{ equals = 'x', contains = 'y' }] }]]",
            "[ui.sidebar.spaces]\nrows = [[{ token = 'workspace', rules = [{ gt = 3, ignore_case = false }] }]]",
            "[ui.sidebar.spaces]\nrows = [[{ token = 'workspace', rules = [{ equals = 3 }] }]]",
        ] {
            do { _ = try HerdrAppearanceConfig.parse(bad); preconditionFailure("Accepted invalid config: \(bad)") }
            catch { precondition(!error.localizedDescription.isEmpty) }
        }
        let atLimit = try HerdrAppearanceConfig.parse(String(repeating: "#", count: 1_048_576))
        precondition(atLimit.themeName == "catppuccin")
        do {
            _ = try HerdrAppearanceConfig.parse(String(repeating: "#", count: 1_048_577))
            preconditionFailure("Accepted oversized config")
        } catch {}
        print("PASS: Herdr TOML normalization, defaults, diagnostics, sidebar preservation, validation, and size limit")
    }
}
