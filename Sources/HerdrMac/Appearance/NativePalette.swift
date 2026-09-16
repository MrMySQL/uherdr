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

    /// Advisory only: never adjust the user's colors or upstream palette values.
    func contrastWarnings(colorScheme: ColorScheme) -> [String] {
        ["text", "secondary_text"].flatMap { foreground in
            ["panel_bg", "sidebar_bg", "active_row", "selection"].compactMap { background in
                let ratio = Self.contrastRatio(foreground: nsColor(foreground), background: nsColor(background), colorScheme: colorScheme)
                return ratio < 4.5 ? "\(foreground) / \(background): \(String(format: "%.2f", ratio)):1" : nil
            }
        }
    }

    static func contrastRatio(foreground: NSColor, background: NSColor, colorScheme: ColorScheme) -> Double {
        var result = 1.0
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            guard let fg = foreground.usingColorSpace(.sRGB), let bg = background.usingColorSpace(.sRGB) else { return }
            func luminance(_ color: NSColor, over background: NSColor) -> Double {
                let alpha = Double(color.alphaComponent)
                let front = [color.redComponent, color.greenComponent, color.blueComponent]
                let back = [background.redComponent, background.greenComponent, background.blueComponent]
                let blended: [Double] = (0..<3).map { Double(front[$0]) * alpha + Double(back[$0]) * (1 - alpha) }
                let channels: [Double] = blended.map { value in
                    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
            }
            let front = luminance(fg, over: bg), back = luminance(bg, over: bg)
            result = (max(front, back) + 0.05) / (min(front, back) + 0.05)
        }
        return result
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
