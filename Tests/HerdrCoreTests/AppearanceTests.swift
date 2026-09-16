import Foundation
import HerdrCore

enum AppearanceTests {
    static func run() throws {
        try testColorParsing()
        try testColorParsingRejectsInvalidInput()
        testResolutionPrecedenceAndReset()
        try testNormalizedRoleResolution()
        try testCodableValuesRoundTrip()
        try testBuiltInCatalogAndAppearancePairs()
        print("PASS: 6 appearance color, resolution, Codable, and catalog tests")
    }

    private static func testColorParsing() throws {
        let shortHex = try ColorValue.parse("#abc")
        let longHex = try ColorValue.parse(" #10A0fF ")
        let rgb = try ColorValue.parse("rgb(0, 255, 42)")
        let purple = try ColorValue.parse("purple")
        let lightCyan = try ColorValue.parse("light_cyan")
        precondition(shortHex == .rgb(170, 187, 204))
        precondition(longHex == .rgb(16, 160, 255))
        precondition(rgb == .rgb(0, 255, 42))
        precondition(purple == .rgb(128, 0, 128))
        precondition(lightCyan == .rgb(0, 255, 255))
        for alias in ["reset", "default", "none", "transparent"] {
            let value = try ColorValue.parse(alias)
            precondition(value == .reset, "reset alias failed: \(alias)")
        }
    }

    private static func testColorParsingRejectsInvalidInput() throws {
        for invalid in ["rgb(256, 0, 0)", "rgb(-1, 0, 0)", "rgb(1, 2)", "#12", "#abcd", "#gg0000", "chartreuse", ""] {
            do {
                _ = try ColorValue.parse(invalid)
                preconditionFailure("Expected invalid color to throw: \(invalid)")
            } catch is ColorValueParseError {
                // Expected: invalid and unknown colors are rejected atomically.
            } catch {
                preconditionFailure("Unexpected error for \(invalid): \(error)")
            }
        }
    }

    private static func testResolutionPrecedenceAndReset() {
        let base = ThemePalette(colors: ["accent": .rgb(1, 2, 3), "text": .rgb(4, 5, 6)])
        let result = ThemeResolver.resolve(base: base, layers: [
            ["accent": .rgb(10, 20, 30)],
            ["accent": .rgb(40, 50, 60)],
        ])
        precondition(result.colors["accent"] == .rgb(40, 50, 60))

        let reset = ThemeResolver.resolve(base: base, layers: [[
            "accent": .rgb(10, 20, 30),
        ], [
            "accent": .reset,
        ]])
        precondition(reset == base)

        let importedThenNative = ThemeResolver.resolve(base: base, layers: [
            ["accent": .rgb(10, 20, 30), "text": .rgb(11, 21, 31)],
            ["accent": .rgb(40, 50, 60)],
        ])
        precondition(importedThenNative.colors["accent"] == .rgb(40, 50, 60))
        precondition(importedThenNative.colors["text"] == .rgb(11, 21, 31))
    }

    private static func testNormalizedRoleResolution() throws {
        let base = try BuiltInThemes.palette(named: "catppuccin")
        let overridden = ThemeResolver.resolve(base: base, layers: [[
            "accent": .rgb(1, 2, 3),
            "red": .rgb(4, 5, 6),
        ]])
        precondition(overridden.colors["focus"] == .rgb(1, 2, 3))
        precondition(overridden.colors["status_blocked"] == .rgb(4, 5, 6))

        let reset = ThemeResolver.resolve(base: base, layers: [[
            "accent": .rgb(1, 2, 3),
        ], [
            "accent": .reset,
        ]])
        precondition(reset.colors["focus"] == base.colors["focus"])
    }

    private static func testCodableValuesRoundTrip() throws {
        let original = ThemePalette(colors: ["accent": .rgb(1, 2, 3), "sidebar_bg": .reset])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemePalette.self, from: data)
        let modeData = try JSONEncoder().encode(AppearanceMode.system)
        let mode = try JSONDecoder().decode(AppearanceMode.self, from: modeData)
        precondition(decoded == original)
        precondition(mode == .system)
    }

    private static func testBuiltInCatalogAndAppearancePairs() throws {
        let expectedNames = [
            "catppuccin", "catppuccin-latte", "dracula", "gruvbox", "gruvbox-light",
            "kanagawa", "kanagawa-lotus", "nord", "one-dark", "one-light", "rose-pine",
            "rose-pine-dawn", "solarized", "solarized-light", "tokyo-night",
            "tokyo-night-day", "uherdr", "vesper",
        ]
        precondition(BuiltInThemes.names == expectedNames)

        let catppuccinDark = try BuiltInThemes.palette(named: "catppuccin", variant: .dark)
        let catppuccinLight = try BuiltInThemes.palette(named: "catppuccin", variant: .light)
        let exactLatte = try BuiltInThemes.palette(named: "catppuccin-latte")
        precondition(exactLatte == catppuccinLight)
        precondition(exactLatte != catppuccinDark)
        precondition(catppuccinDark.colors["accent"] == .rgb(137, 180, 250))
        precondition(catppuccinDark.colors["status_blocked"] == .rgb(243, 139, 168))
        precondition(catppuccinLight.colors["accent"] == .rgb(30, 102, 245))
        precondition(catppuccinLight.colors["window_bg"] == .rgb(230, 233, 239))

        let fixturePairs: [(String, ColorValue, ColorValue)] = [
            ("catppuccin", .rgb(137, 180, 250), .rgb(30, 102, 245)),
            ("tokyo-night", .rgb(122, 162, 247), .rgb(46, 125, 233)),
            ("gruvbox", .rgb(215, 153, 33), .rgb(7, 102, 120)),
            ("one-dark", .rgb(97, 175, 239), .rgb(64, 120, 242)),
            ("solarized", .rgb(38, 139, 210), .rgb(38, 139, 210)),
            ("kanagawa", .rgb(126, 156, 216), .rgb(77, 105, 155)),
            ("rose-pine", .rgb(196, 167, 231), .rgb(144, 122, 169)),
        ]
        for (name, darkAccent, lightAccent) in fixturePairs {
            let dark = try BuiltInThemes.palette(named: name, variant: .dark)
            let light = try BuiltInThemes.palette(named: name, variant: .light)
            precondition(dark.colors["accent"] == darkAccent)
            precondition(light.colors["accent"] == lightAccent)
        }

        for name in BuiltInThemes.names {
            for variant in [ThemeVariant.light, .dark] {
                let palette = try BuiltInThemes.palette(named: name, variant: variant)
                for role in ThemePalette.semanticRoles {
                    precondition(palette.colors[role] != nil, "\(name) \(variant) omitted \(role)")
                }
            }
        }

        let alias = try BuiltInThemes.palette(named: "Catppuccin_Mocha", variant: .dark)
        precondition(alias == catppuccinDark)
        do {
            _ = try BuiltInThemes.palette(named: "terminal", variant: .dark)
            preconditionFailure("terminal must be resolved from the embedded terminal palette")
        } catch BuiltInThemeError.terminalRequiresPaletteSource {
            // Expected: upstream terminal colors are symbolic, not an RGB preset.
        } catch {
            preconditionFailure("Unexpected terminal error: \(error)")
        }
        do {
            _ = try BuiltInThemes.palette(named: "missing", variant: .dark)
            preconditionFailure("Unknown themes must throw")
        } catch BuiltInThemeError.unknownTheme {
            // Expected.
        } catch {
            preconditionFailure("Unexpected unknown-theme error: \(error)")
        }
    }
}
