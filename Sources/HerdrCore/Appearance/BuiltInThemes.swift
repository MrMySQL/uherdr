import Foundation

public enum BuiltInThemeError: Error, Equatable, Sendable, LocalizedError {
    case unknownTheme(String)
    case terminalRequiresPaletteSource

    public var errorDescription: String? {
        switch self {
        case let .unknownTheme(name):
            return "Unknown built-in theme: \(name)"
        case .terminalRequiresPaletteSource:
            return "The terminal theme must be resolved from the embedded terminal palette"
        }
    }
}

public enum BuiltInThemes {
    /// Concrete palettes only. Upstream's symbolic `terminal` theme is a
    /// separate palette source and is intentionally absent.
    public static let names = [
        "catppuccin", "catppuccin-latte", "dracula", "gruvbox", "gruvbox-light",
        "kanagawa", "kanagawa-lotus", "nord", "one-dark", "one-light", "rose-pine",
        "rose-pine-dawn", "solarized", "solarized-light", "tokyo-night",
        "tokyo-night-day", "uherdr", "vesper",
    ]

    /// Returns the exact named preset without appearance sibling selection.
    /// Use this for imported themes when upstream auto-switching is disabled.
    public static func palette(named name: String) throws -> ThemePalette {
        let canonical = canonicalName(name)
        if canonical == "terminal" {
            throw BuiltInThemeError.terminalRequiresPaletteSource
        }
        guard let palette = palettes[canonical] else {
            throw BuiltInThemeError.unknownTheme(name)
        }
        return palette
    }

    /// Returns the light or dark sibling for paired theme families. Unpaired
    /// presets keep their exact palette for either appearance.
    public static func palette(named name: String, variant: ThemeVariant) throws -> ThemePalette {
        let canonical = canonicalName(name)
        if canonical == "terminal" {
            throw BuiltInThemeError.terminalRequiresPaletteSource
        }
        let selected: String
        switch canonical {
        case "catppuccin", "catppuccin-latte":
            selected = variant == .light ? "catppuccin-latte" : "catppuccin"
        case "tokyo-night", "tokyo-night-day":
            selected = variant == .light ? "tokyo-night-day" : "tokyo-night"
        case "gruvbox", "gruvbox-light":
            selected = variant == .light ? "gruvbox-light" : "gruvbox"
        case "one-dark", "one-light":
            selected = variant == .light ? "one-light" : "one-dark"
        case "solarized", "solarized-light":
            selected = variant == .light ? "solarized-light" : "solarized"
        case "kanagawa", "kanagawa-lotus":
            selected = variant == .light ? "kanagawa-lotus" : "kanagawa"
        case "rose-pine", "rose-pine-dawn":
            selected = variant == .light ? "rose-pine-dawn" : "rose-pine"
        default:
            selected = canonical
        }
        guard let palette = palettes[selected] else {
            throw BuiltInThemeError.unknownTheme(name)
        }
        return palette
    }

    private static let upstreamRoles = [
        "accent", "panel_bg", "sidebar_bg", "active_row_bg", "selection_bg",
        "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text",
        "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach",
    ]

    private static func c(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> ColorValue {
        .rgb(red, green, blue)
    }

    private static var x: ColorValue { .reset }

    private static func normalized(_ values: [ColorValue]) -> ThemePalette {
        precondition(values.count == upstreamRoles.count)
        var colors = Dictionary(uniqueKeysWithValues: zip(upstreamRoles, values))
        colors["window_bg"] = colors["surface_dim"]
        colors["secondary_text"] = colors["subtext0"]
        colors["border"] = colors["surface1"]
        colors["focus"] = colors["accent"]
        colors["selection"] = colors["selection_bg"]
        colors["active_row"] = colors["active_row_bg"]
        colors["status_done"] = colors["green"]
        colors["status_working"] = colors["yellow"]
        colors["status_blocked"] = colors["red"]
        colors["status_unseen"] = colors["blue"]
        colors["status_notification"] = colors["teal"]
        colors["status_interrupted"] = colors["peach"]
        colors["special_text"] = colors["mauve"]
        return ThemePalette(colors: colors)
    }

    // Values are copied from Herdr's Palette constructors at the revision
    // recorded in docs/theme-provenance.md, in `upstreamRoles` order.
    private static let palettes: [String: ThemePalette] = [
        "catppuccin": normalized([
            c(137, 180, 250), c(24, 24, 37), x, c(30, 30, 46), c(49, 50, 68),
            c(49, 50, 68), c(69, 71, 90), c(30, 30, 46), c(108, 112, 134), c(127, 132, 156),
            c(205, 214, 244), c(166, 173, 200), c(203, 166, 247), c(166, 227, 161), c(249, 226, 175),
            c(243, 139, 168), c(137, 180, 250), c(148, 226, 213), c(250, 179, 135),
        ]),
        "catppuccin-latte": normalized([
            c(30, 102, 245), c(239, 241, 245), x, c(230, 233, 239), c(189, 208, 245),
            c(204, 208, 218), c(188, 192, 204), c(230, 233, 239), c(156, 160, 176), c(140, 143, 161),
            c(76, 79, 105), c(108, 111, 133), c(136, 57, 239), c(64, 160, 43), c(223, 142, 29),
            c(210, 15, 57), c(30, 102, 245), c(23, 146, 153), c(254, 100, 11),
        ]),
        "tokyo-night": normalized([
            c(122, 162, 247), c(26, 27, 38), x, c(35, 38, 54), c(45, 54, 80),
            c(36, 40, 59), c(65, 72, 104), c(26, 27, 38), c(86, 95, 137), c(105, 113, 150),
            c(192, 202, 245), c(169, 177, 214), c(187, 154, 247), c(158, 206, 106), c(224, 175, 104),
            c(247, 118, 142), c(122, 162, 247), c(125, 207, 255), c(255, 158, 100),
        ]),
        "tokyo-night-day": normalized([
            c(46, 125, 233), c(225, 226, 231), x, c(210, 211, 218), c(182, 202, 231),
            c(196, 200, 218), c(168, 174, 203), c(210, 211, 218), c(137, 144, 179), c(104, 112, 154),
            c(55, 96, 191), c(97, 114, 176), c(120, 71, 189), c(88, 117, 57), c(140, 108, 62),
            c(245, 42, 101), c(46, 125, 233), c(17, 140, 116), c(177, 92, 0),
        ]),
        "dracula": normalized([
            c(189, 147, 249), c(40, 42, 54), x, c(55, 60, 82), c(70, 63, 93),
            c(68, 71, 90), c(98, 114, 164), c(40, 42, 54), c(98, 114, 164), c(130, 140, 180),
            c(248, 248, 242), c(210, 210, 220), c(255, 121, 198), c(80, 250, 123), c(241, 250, 140),
            c(255, 85, 85), c(139, 233, 253), c(139, 233, 253), c(255, 184, 108),
        ]),
        "nord": normalized([
            c(136, 192, 208), c(46, 52, 64), x, c(67, 76, 94), c(64, 80, 93),
            c(59, 66, 82), c(67, 76, 94), c(46, 52, 64), c(76, 86, 106), c(100, 110, 130),
            c(236, 239, 244), c(216, 222, 233), c(180, 142, 173), c(163, 190, 140), c(235, 203, 139),
            c(191, 97, 106), c(129, 161, 193), c(143, 188, 187), c(208, 135, 112),
        ]),
        "gruvbox": normalized([
            c(215, 153, 33), c(40, 40, 40), x, c(50, 49, 48), c(75, 63, 39),
            c(60, 56, 54), c(80, 73, 69), c(40, 40, 40), c(146, 131, 116), c(168, 153, 132),
            c(235, 219, 178), c(213, 196, 161), c(211, 134, 155), c(184, 187, 38), c(250, 189, 47),
            c(251, 73, 52), c(131, 165, 152), c(142, 192, 124), c(254, 128, 25),
        ]),
        "gruvbox-light": normalized([
            c(7, 102, 120), c(251, 241, 199), x, c(242, 229, 188), c(235, 219, 178),
            c(235, 219, 178), c(213, 196, 161), c(242, 229, 188), c(146, 131, 116), c(124, 111, 100),
            c(60, 56, 54), c(80, 73, 69), c(143, 63, 113), c(121, 116, 14), c(181, 118, 20),
            c(157, 0, 6), c(7, 102, 120), c(66, 123, 88), c(175, 58, 3),
        ]),
        "one-dark": normalized([
            c(97, 175, 239), c(40, 44, 52), x, c(49, 54, 64), c(51, 70, 89),
            c(44, 49, 58), c(62, 68, 81), c(40, 44, 52), c(92, 99, 112), c(115, 122, 135),
            c(171, 178, 191), c(150, 156, 168), c(198, 120, 221), c(152, 195, 121), c(229, 192, 123),
            c(224, 108, 117), c(97, 175, 239), c(86, 182, 194), c(209, 154, 102),
        ]),
        "one-light": normalized([
            c(64, 120, 242), c(250, 250, 250), x, c(216, 219, 226), c(205, 219, 248),
            c(240, 240, 241), c(229, 229, 230), c(245, 245, 246), c(160, 161, 167), c(104, 107, 119),
            c(56, 58, 66), c(104, 107, 119), c(166, 38, 164), c(80, 161, 79), c(193, 132, 1),
            c(228, 86, 73), c(64, 120, 242), c(1, 132, 188), c(152, 104, 1),
        ]),
        "solarized": normalized([
            c(38, 139, 210), c(0, 43, 54), x, c(22, 75, 87), c(8, 62, 85),
            c(7, 54, 66), c(88, 110, 117), c(0, 43, 54), c(88, 110, 117), c(101, 123, 131),
            c(147, 161, 161), c(131, 148, 150), c(211, 54, 130), c(133, 153, 0), c(181, 137, 0),
            c(220, 50, 47), c(38, 139, 210), c(42, 161, 152), c(203, 75, 22),
        ]),
        "solarized-light": normalized([
            c(38, 139, 210), c(253, 246, 227), x, c(238, 232, 213), c(201, 220, 223),
            c(238, 232, 213), c(147, 161, 161), c(238, 232, 213), c(147, 161, 161), c(88, 110, 117),
            c(101, 123, 131), c(131, 148, 150), c(211, 54, 130), c(133, 153, 0), c(181, 137, 0),
            c(220, 50, 47), c(38, 139, 210), c(42, 161, 152), c(203, 75, 22),
        ]),
        "kanagawa": normalized([
            c(126, 156, 216), c(31, 31, 40), x, c(54, 54, 70), c(50, 56, 75),
            c(42, 42, 55), c(54, 54, 70), c(31, 31, 40), c(114, 113, 105), c(135, 134, 125),
            c(220, 215, 186), c(200, 195, 170), c(149, 127, 184), c(118, 148, 106), c(192, 163, 110),
            c(195, 64, 67), c(126, 156, 216), c(127, 180, 202), c(255, 160, 102),
        ]),
        "kanagawa-lotus": normalized([
            c(77, 105, 155), c(242, 236, 188), x, c(213, 206, 163), c(220, 213, 172),
            c(220, 213, 172), c(201, 203, 209), c(213, 206, 163), c(160, 156, 172), c(138, 137, 128),
            c(84, 84, 100), c(67, 67, 108), c(98, 76, 131), c(111, 137, 78), c(119, 113, 63),
            c(200, 64, 83), c(77, 105, 155), c(78, 140, 162), c(204, 109, 0),
        ]),
        "rose-pine": normalized([
            c(196, 167, 231), c(25, 23, 36), x, c(38, 35, 58), c(59, 52, 75),
            c(31, 29, 46), c(38, 35, 58), c(38, 35, 58), c(110, 106, 134), c(144, 140, 170),
            c(224, 222, 244), c(200, 197, 220), c(196, 167, 231), c(49, 116, 143), c(246, 193, 119),
            c(235, 111, 146), c(49, 116, 143), c(156, 207, 216), c(234, 154, 151),
        ]),
        "rose-pine-dawn": normalized([
            c(144, 122, 169), c(250, 244, 237), x, c(227, 217, 207), c(242, 233, 225),
            c(242, 233, 225), c(255, 250, 243), c(242, 233, 225), c(152, 147, 165), c(121, 117, 147),
            c(70, 66, 97), c(121, 117, 147), c(144, 122, 169), c(40, 105, 131), c(234, 157, 52),
            c(180, 99, 122), c(40, 105, 131), c(86, 148, 159), c(215, 130, 126),
        ]),
        "vesper": normalized([
            c(255, 199, 153), c(26, 26, 26), x, c(16, 16, 16), c(35, 35, 35),
            c(35, 35, 35), c(40, 40, 40), c(16, 16, 16), c(92, 92, 92), c(126, 126, 126),
            c(255, 255, 255), c(160, 160, 160), c(255, 209, 168), c(153, 255, 228), c(255, 199, 153),
            c(255, 128, 128), c(176, 176, 176), c(102, 221, 204), c(255, 199, 153),
        ]),
        "uherdr": normalized([
            c(87, 186, 148), x, x, x, x,
            x, x, x, x, x,
            x, x, c(87, 186, 148), c(87, 186, 148), c(50, 173, 230),
            c(255, 149, 0), c(87, 186, 148), c(50, 173, 230), c(255, 149, 0),
        ]),
    ]

    private static func canonicalName(_ name: String) -> String {
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "catppuccin-mocha": return "catppuccin"
        case "latte", "light": return "catppuccin-latte"
        case "tokyonight": return "tokyo-night"
        case "tokyo-day", "tokyonight-day": return "tokyo-night-day"
        case "gruvbox-dark": return "gruvbox"
        case "onedark": return "one-dark"
        case "onelight": return "one-light"
        case "solarized-dark": return "solarized"
        case "lotus": return "kanagawa-lotus"
        case "rosepine": return "rose-pine"
        case "rosepine-dawn", "dawn": return "rose-pine-dawn"
        default: return normalized
        }
    }
}
