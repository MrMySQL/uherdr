import Foundation
import GhosttyKit
import GhosttyTerminal
import HerdrCore

/// One fixed configuration shared by engine creation and the read-only UI palette source.
/// Reading it may initialize the wrapper singleton; it creates no surface or shell
/// and never changes an active engine configuration.
@MainActor
enum EmbeddedTerminalPalette {
    static let theme = TerminalTheme(
        light: TerminalConfiguration.alabaster.background("#fafaf7").foreground("#212926"),
        dark: TerminalConfiguration().background("#0e1113").foreground("#dbe3de")
    )

    private static let light = read(theme.light)
    private static let dark = read(theme.dark)

    static func palette(for variant: ThemeVariant) -> ThemePalette? {
        variant == .light ? light : dark
    }

    private static func read(_ configuration: TerminalConfiguration) -> ThemePalette? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uherdr-palette-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        do { try configuration.rendered.write(to: url, atomically: true, encoding: .utf8) }
        catch { return nil }
        // The wrapper owns process-global initialization. Its public singleton
        // performs that once, without creating a terminal surface or Herdr session.
        _ = GhosttyTerminal.TerminalController.shared
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, url.path)
        ghostty_config_finalize(config)
        guard ghostty_config_diagnostics_count(config) == 0 else { return nil }
        var palette = ghostty_config_palette_s()
        guard ghostty_config_get(config, &palette, "palette", 7) else { return nil }
        let colors: [ColorValue] = withUnsafeBytes(of: &palette.colors) { bytes in
            bytes.bindMemory(to: ghostty_config_color_s.self).map { .rgb($0.r, $0.g, $0.b) }
        }
        // Pinned Herdr src/app/state.rs::Theme::terminal; resets use NativePalette fallbacks.
        let roles: ThemeOverrides = [
            "accent": colors[4], "panel_bg": .reset, "sidebar_bg": .reset,
            "active_row_bg": colors[8], "selection_bg": .reset, "surface0": .reset,
            "surface1": colors[8], "surface_dim": colors[8], "overlay0": colors[7],
            "overlay1": colors[15], "text": .reset, "subtext0": colors[7], "mauve": colors[7],
            "green": colors[2], "yellow": colors[3], "red": colors[9], "blue": colors[4],
            "teal": colors[6], "peach": colors[3],
        ]
        // Seed semantic keys so the common resolver normalizes every upstream role.
        let keys = Set(ThemePalette.semanticRoles + HerdrAppearanceConfig.colorRoles)
        let base = ThemePalette(colors: Dictionary(uniqueKeysWithValues: keys.map { ($0, ColorValue.reset) }))
        return ThemeResolver.resolve(base: base, layers: [roles])
    }
}
