import Combine
import Foundation
import HerdrCore

enum AppearanceThemeSource: String, Codable, Equatable, Sendable {
    case native
    case herdrConfig
}

enum AppearanceOverrideScope: String, CaseIterable, Codable, Hashable, Sendable {
    case common
    case light
    case dark
}

struct NativeAppearanceOverrides: Codable, Equatable, Sendable {
    var common: ThemeOverrides = [:]
    var light: ThemeOverrides = [:]
    var dark: ThemeOverrides = [:]

    subscript(scope: AppearanceOverrideScope) -> ThemeOverrides {
        get {
            switch scope {
            case .common: common
            case .light: light
            case .dark: dark
            }
        }
        set {
            switch scope {
            case .common: common = newValue
            case .light: light = newValue
            case .dark: dark = newValue
            }
        }
    }
}

/// The normalized, last-known-good subset loaded from a Herdr configuration.
/// Task 4 owns parsing and diagnostics; this value is the persistence boundary.
typealias ImportedAppearanceSettings = HerdrAppearanceConfig

struct ResolvedAppearanceSnapshot: Equatable, Sendable {
    let mode: AppearanceMode
    let fontSize: Double
    let source: AppearanceThemeSource
    let light: ThemePalette
    let dark: ThemePalette

    func palette(for variant: ThemeVariant) -> ThemePalette {
        variant == .light ? light : dark
    }
}

@MainActor
final class AppearanceStore: ObservableObject {
    enum PreferenceKey {
        static let mode = "appearance"
        static let fontSize = "fontSize"
        static let themeSource = "appearance.themeSource"
        static let lightPreset = "appearance.lightPreset"
        static let darkPreset = "appearance.darkPreset"
        static let nativeOverrides = "appearance.nativeOverrides"
        static let herdrConfigPath = "appearance.herdrConfigPath"
        static let lastGoodImportedSettings = "appearance.lastGoodImportedSettings"
    }

    static let supportedOverrideRoles = HerdrAppearanceConfig.colorRoles

    private(set) var mode: AppearanceMode
    private(set) var fontSize: Double
    private(set) var themeSource: AppearanceThemeSource
    private(set) var lightPreset: String
    private(set) var darkPreset: String
    private(set) var nativeOverrides: NativeAppearanceOverrides
    private(set) var lastGoodImportedSettings: ImportedAppearanceSettings?
    private(set) var resolvedSnapshot: ResolvedAppearanceSnapshot
    private(set) var revision = 0
    private(set) var herdrConfigPath: String?
    private(set) var importDiagnostic: String?
    private(set) var isLoadingConfig = false
    private var loadGeneration = 0
    static let defaultHerdrConfigURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/herdr/config.toml")

    var unifiedPreset: String? {
        guard lightPreset == darkPreset else { return nil }
        return lightPreset
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        herdrConfigPath = defaults.string(forKey: PreferenceKey.herdrConfigPath)
        mode = defaults.string(forKey: PreferenceKey.mode).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        if let number = defaults.object(forKey: PreferenceKey.fontSize) as? NSNumber,
           number.doubleValue.isFinite, (10...22).contains(number.doubleValue) {
            fontSize = number.doubleValue
        } else {
            fontSize = 13
        }
        themeSource = defaults.string(forKey: PreferenceKey.themeSource)
            .flatMap(AppearanceThemeSource.init(rawValue:)) ?? .native
        lightPreset = Self.validPreset(defaults.string(forKey: PreferenceKey.lightPreset)) ?? "uherdr"
        darkPreset = Self.validPreset(defaults.string(forKey: PreferenceKey.darkPreset)) ?? "uherdr"
        nativeOverrides = Self.decode(NativeAppearanceOverrides.self, from: defaults, key: PreferenceKey.nativeOverrides)
            .map(Self.sanitized) ?? NativeAppearanceOverrides()
        lastGoodImportedSettings = Self.decode(
            ImportedAppearanceSettings.self,
            from: defaults,
            key: PreferenceKey.lastGoodImportedSettings
        ).flatMap(Self.validImportedSettings)
        if themeSource == .herdrConfig && lastGoodImportedSettings == nil {
            themeSource = .native
        }
        resolvedSnapshot = Self.resolve(
            mode: mode,
            fontSize: fontSize,
            source: themeSource,
            lightPreset: lightPreset,
            darkPreset: darkPreset,
            nativeOverrides: nativeOverrides,
            imported: lastGoodImportedSettings
        )
    }

    func setMode(_ mode: AppearanceMode) {
        guard self.mode != mode else { return }
        publishChange {
            self.mode = mode
            refreshSnapshot()
        }
        defaults.set(mode.rawValue, forKey: PreferenceKey.mode)
    }

    func setFontSize(_ size: Double) {
        let value = min(22, max(10, size))
        guard fontSize != value else { return }
        publishChange {
            fontSize = value
            refreshSnapshot()
        }
        defaults.set(value, forKey: PreferenceKey.fontSize)
    }

    func setPreset(_ name: String) throws {
        _ = try BuiltInThemes.palette(named: name)
        invalidateLoad()
        guard lightPreset != name || darkPreset != name || themeSource != .native else { return }
        publishChange {
            lightPreset = name
            darkPreset = name
            themeSource = .native
            refreshSnapshot()
        }
        defaults.set(name, forKey: PreferenceKey.lightPreset)
        defaults.set(name, forKey: PreferenceKey.darkPreset)
        defaults.set(AppearanceThemeSource.native.rawValue, forKey: PreferenceKey.themeSource)
    }

    func setLightPreset(_ name: String) {
        invalidateLoad()
        guard Self.validPreset(name) != nil,
              lightPreset != name || themeSource != .native else { return }
        publishChange {
            lightPreset = name
            themeSource = .native
            refreshSnapshot()
        }
        defaults.set(name, forKey: PreferenceKey.lightPreset)
        defaults.set(AppearanceThemeSource.native.rawValue, forKey: PreferenceKey.themeSource)
    }

    func setDarkPreset(_ name: String) {
        invalidateLoad()
        guard Self.validPreset(name) != nil,
              darkPreset != name || themeSource != .native else { return }
        publishChange {
            darkPreset = name
            themeSource = .native
            refreshSnapshot()
        }
        defaults.set(name, forKey: PreferenceKey.darkPreset)
        defaults.set(AppearanceThemeSource.native.rawValue, forKey: PreferenceKey.themeSource)
    }

    func setNativeOverride(_ value: ColorValue?, for role: String, scope: AppearanceOverrideScope) {
        guard Self.supportedOverrideRoles.contains(role) else { return }
        var updated = nativeOverrides
        if let value { updated[scope][role] = value } else { updated[scope].removeValue(forKey: role) }
        guard updated != nativeOverrides else { return }
        publishChange {
            nativeOverrides = updated
            refreshSnapshot()
        }
        persist(nativeOverrides, key: PreferenceKey.nativeOverrides)
    }

    func resetNativeOverrides() {
        guard nativeOverrides != NativeAppearanceOverrides() else { return }
        publishChange {
            nativeOverrides = NativeAppearanceOverrides()
            refreshSnapshot()
        }
        defaults.removeObject(forKey: PreferenceKey.nativeOverrides)
    }

    func resetNativeOverrides(scope: AppearanceOverrideScope) {
        guard !nativeOverrides[scope].isEmpty else { return }
        publishChange {
            nativeOverrides[scope] = [:]
            refreshSnapshot()
        }
        persist(nativeOverrides, key: PreferenceKey.nativeOverrides)
    }

    func applyImportedSettings(_ settings: ImportedAppearanceSettings) throws {
        try HerdrAppearanceConfig.validateThemeName(settings.themeName)
        for name in [settings.lightName, settings.darkName].compactMap({ $0 }) {
            try HerdrAppearanceConfig.validateThemeName(name)
        }
        guard ![settings.themeName, settings.lightName, settings.darkName].compactMap({ $0 })
            .contains(where: { $0.lowercased() == "terminal" }) ||
            (EmbeddedTerminalPalette.palette(for: .light) != nil && EmbeddedTerminalPalette.palette(for: .dark) != nil) else {
            throw HerdrError.message("Could not read the embedded terminal ANSI palette")
        }
        var sanitized = settings
        sanitized.commonOverrides = Self.sanitized(settings.commonOverrides)
        sanitized.lightOverrides = Self.sanitized(settings.lightOverrides)
        sanitized.darkOverrides = Self.sanitized(settings.darkOverrides)
        guard lastGoodImportedSettings != sanitized || themeSource != .herdrConfig else { return }
        publishChange {
            lastGoodImportedSettings = sanitized
            themeSource = .herdrConfig
            refreshSnapshot()
        }
        persist(sanitized, key: PreferenceKey.lastGoodImportedSettings)
        defaults.set(AppearanceThemeSource.herdrConfig.rawValue, forKey: PreferenceKey.themeSource)
    }

    func setThemeSource(_ source: AppearanceThemeSource) {
        invalidateLoad()
        guard source != .herdrConfig || lastGoodImportedSettings != nil,
              themeSource != source else { return }
        publishChange {
            themeSource = source
            refreshSnapshot()
        }
        defaults.set(source.rawValue, forKey: PreferenceKey.themeSource)
    }

    func reloadHerdrConfig() async {
        await loadHerdrConfig(url: herdrConfigPath.map { URL(fileURLWithPath: $0) } ?? Self.defaultHerdrConfigURL)
    }

    func loadHerdrConfig(url: URL) async {
        loadGeneration += 1
        let generation = loadGeneration
        publishChange { isLoadingConfig = true }
        do {
            let settings = try await HerdrConfigLoader.load(url: url)
            guard generation == loadGeneration, !Task.isCancelled else {
                if generation == loadGeneration { publishChange { isLoadingConfig = false } }
                return
            }
            try applyImportedSettings(settings)
            publishChange {
                herdrConfigPath = url.path
                importDiagnostic = settings.diagnostics?.joined(separator: "\n")
                isLoadingConfig = false
            }
            defaults.set(url.path, forKey: PreferenceKey.herdrConfigPath)
        } catch {
            guard generation == loadGeneration else { return }
            publishChange {
                importDiagnostic = "\(url.path): \(error.localizedDescription)"
                isLoadingConfig = false
            }
        }
    }

    private func invalidateLoad() {
        loadGeneration += 1
        if isLoadingConfig { publishChange { isLoadingConfig = false } }
    }

    private func publishChange(_ update: () -> Void) {
        revision += 1
        objectWillChange.send()
        update()
    }

    private func refreshSnapshot() {
        resolvedSnapshot = Self.resolve(
            mode: mode,
            fontSize: fontSize,
            source: themeSource,
            lightPreset: lightPreset,
            darkPreset: darkPreset,
            nativeOverrides: nativeOverrides,
            imported: lastGoodImportedSettings
        )
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? encoder.encode(value) { defaults.set(data, forKey: key) }
    }

    private static func resolve(
        mode: AppearanceMode,
        fontSize: Double,
        source: AppearanceThemeSource,
        lightPreset: String,
        darkPreset: String,
        nativeOverrides: NativeAppearanceOverrides,
        imported: ImportedAppearanceSettings?
    ) -> ResolvedAppearanceSnapshot {
        let light = resolvePalette(
            variant: .light,
            source: source,
            preset: lightPreset,
            nativeOverrides: nativeOverrides,
            imported: imported
        )
        let dark = resolvePalette(
            variant: .dark,
            source: source,
            preset: darkPreset,
            nativeOverrides: nativeOverrides,
            imported: imported
        )
        return ResolvedAppearanceSnapshot(mode: mode, fontSize: fontSize, source: source, light: light, dark: dark)
    }

    private static func resolvePalette(
        variant: ThemeVariant,
        source: AppearanceThemeSource,
        preset: String,
        nativeOverrides: NativeAppearanceOverrides,
        imported: ImportedAppearanceSettings?
    ) -> ThemePalette {
        let base: ThemePalette
        var layers: [ThemeOverrides] = []
        if source == .herdrConfig, let imported {
            let explicit = variant == .light ? imported.lightName : imported.darkName
            let name = imported.autoSwitch ? (explicit ?? imported.themeName) : imported.themeName
            if name.lowercased() == "terminal" {
                base = EmbeddedTerminalPalette.palette(for: variant) ?? fallbackPalette()
            } else {
                base = (try? imported.autoSwitch && explicit == nil
                    ? BuiltInThemes.palette(named: name, variant: variant)
                    : BuiltInThemes.palette(named: name)) ?? fallbackPalette()
            }
            layers.append(imported.commonOverrides)
            if imported.autoSwitch {
                layers.append(variant == .light ? imported.lightOverrides : imported.darkOverrides)
            }
        } else {
            base = (try? BuiltInThemes.palette(named: preset, variant: variant)) ?? fallbackPalette()
        }
        layers.append(nativeOverrides.common)
        layers.append(nativeOverrides[variant == .light ? .light : .dark])
        return ThemeResolver.resolve(base: base, layers: layers)
    }

    private static func fallbackPalette() -> ThemePalette {
        // The shipped default is compile-time data and is guaranteed by the core tests.
        try! BuiltInThemes.palette(named: "uherdr")
    }

    private static func validPreset(_ value: String?) -> String? {
        guard let value, (try? BuiltInThemes.palette(named: value)) != nil else { return nil }
        return value
    }

    private static func validImportedSettings(_ settings: ImportedAppearanceSettings) -> ImportedAppearanceSettings? {
        guard (try? HerdrAppearanceConfig.validateThemeName(settings.themeName)) != nil,
              [settings.lightName, settings.darkName].compactMap({ $0 }).allSatisfy({
                  (try? HerdrAppearanceConfig.validateThemeName($0)) != nil
              }) else { return nil }
        var result = settings
        result.commonOverrides = sanitized(settings.commonOverrides)
        result.lightOverrides = sanitized(settings.lightOverrides)
        result.darkOverrides = sanitized(settings.darkOverrides)
        return result
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func sanitized(_ overrides: NativeAppearanceOverrides) -> NativeAppearanceOverrides {
        NativeAppearanceOverrides(
            common: sanitized(overrides.common),
            light: sanitized(overrides.light),
            dark: sanitized(overrides.dark)
        )
    }

    private static func sanitized(_ overrides: ThemeOverrides) -> ThemeOverrides {
        overrides.filter { supportedOverrideRoles.contains($0.key) }
    }
}
