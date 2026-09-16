import AppKit
import HerdrCore
import SwiftUI

struct NativePalette {
    let palette: ThemePalette

    init(palette: ThemePalette) {
        self.palette = palette
    }

    init(snapshot: ResolvedAppearanceSnapshot, colorScheme: ColorScheme) {
        let variant: ThemeVariant
        switch snapshot.mode {
        case .light: variant = .light
        case .dark: variant = .dark
        case .system: variant = colorScheme == .dark ? .dark : .light
        }
        palette = snapshot.palette(for: variant)
    }

    func color(_ role: String) -> Color {
        Color(nsColor: nsColor(role))
    }

    /// Reset keeps the existing native styling at each use site (including its
    /// opacity); explicit theme colors are already complete surface colors.
    func color(_ role: String, fallback: @autoclosure () -> Color) -> Color {
        guard case .rgb = palette.colors[role] else { return fallback() }
        return color(role)
    }

    func nsColor(_ role: String, fallback: @autoclosure () -> NSColor) -> NSColor {
        guard case .rgb = palette.colors[role] else { return fallback() }
        return nsColor(role)
    }

    func nsColor(_ role: String) -> NSColor {
        guard case let .rgb(red, green, blue) = palette.colors[role] else {
            return Self.nativeFallback(for: role)
        }
        return NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    static func nativeFallback(for role: String) -> NSColor {
        switch role {
        case "window_bg", "surface_dim": .windowBackgroundColor
        case "sidebar_bg": .underPageBackgroundColor
        case "panel_bg", "surface0": .controlBackgroundColor
        case "surface1", "border", "overlay0", "overlay1": .separatorColor
        case "active_row", "active_row_bg": .unemphasizedSelectedContentBackgroundColor
        case "selection", "selection_bg": .selectedContentBackgroundColor
        case "text": .labelColor
        case "secondary_text", "subtext0": .secondaryLabelColor
        case "status_done", "green": .systemGreen
        case "status_working", "yellow": .systemYellow
        case "status_blocked", "red": .systemRed
        case "status_unseen", "blue": .systemBlue
        case "status_notification", "teal": .systemTeal
        case "status_interrupted", "peach": .systemOrange
        case "special_text", "mauve": .systemPurple
        default: .controlAccentColor
        }
    }
}

private struct ResolvedAppearanceEnvironmentKey: EnvironmentKey {
    static let defaultValue = ResolvedAppearanceSnapshot(
        mode: .system,
        fontSize: 13,
        source: .native,
        light: try! BuiltInThemes.palette(named: "uherdr", variant: .light),
        dark: try! BuiltInThemes.palette(named: "uherdr", variant: .dark)
    )
}

extension EnvironmentValues {
    var resolvedAppearance: ResolvedAppearanceSnapshot {
        get { self[ResolvedAppearanceEnvironmentKey.self] }
        set { self[ResolvedAppearanceEnvironmentKey.self] = newValue }
    }
}
