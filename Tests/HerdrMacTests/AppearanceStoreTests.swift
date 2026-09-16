import Combine
import Darwin
import Foundation
import HerdrCore
@testable import HerdrMac

@main
struct AppearanceStoreTests {
    @MainActor
    static func main() async throws {
        testLegacyMigrationAndSecondInitialization()
        testInvalidPersistenceIsPreservedUntilAnEdit()
        try testResolutionAndNoOpPublication()
        try testMainPresetSelection()
        try testImportedFixedThemeResolutionBoundary()
        testSharedSessionAndDevicePublication()
        try await testReadOnlyImportAndLastGoodState()
        try testExplicitNamesAndTerminalSource()
        print("PASS: appearance migration, import atomicity, bounded regular-file loading, unchanged TOML, offline persistence, source precedence, terminal palette, shared publication, and device isolation")
    }

    @MainActor
    private static func testReadOnlyImportAndLastGoodState() async throws {
        let suite = "uherdr.import.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("[theme]\nname = 'nord'\nfuture = true\n[theme.custom]\naccent = '#123456'\n[ui.sidebar.spaces]\nrows = [['workspace']]".utf8)
        try data.write(to: url)
        let store = AppearanceStore(defaults: defaults)
        await store.loadHerdrConfig(url: url)
        precondition(store.themeSource == .herdrConfig && store.herdrConfigPath == url.path)
        precondition(store.resolvedSnapshot.dark.colors["accent"] == .rgb(18, 52, 86))
        let unchanged = try Data(contentsOf: url)
        precondition(unchanged == data, "Import must never write the source TOML")
        await store.reloadHerdrConfig()
        let reloadedBytes = try Data(contentsOf: url)
        precondition(reloadedBytes == data, "Reload must never write the source TOML")
        precondition(store.lastGoodImportedSettings?.sidebar != nil)
        precondition(store.lastGoodImportedSettings?.diagnostics?.count == 2)
        store.setNativeOverride(.rgb(1, 2, 3), for: "accent", scope: .common)
        precondition(store.resolvedSnapshot.dark.colors["accent"] == .rgb(1, 2, 3))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let beforeUnreadable = store.resolvedSnapshot
        await store.reloadHerdrConfig()
        precondition(store.resolvedSnapshot == beforeUnreadable && store.importDiagnostic?.contains(url.path) == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let lastGood = store.lastGoodImportedSettings
        let snapshot = store.resolvedSnapshot
        for invalid in [Data("[theme]\nname = 'oops'".utf8), Data(repeating: 35, count: 1_048_577), Data([0xff])] {
            try invalid.write(to: url)
            await store.reloadHerdrConfig()
            precondition(store.lastGoodImportedSettings == lastGood && store.resolvedSnapshot == snapshot)
            precondition(store.importDiagnostic?.contains(url.path) == true)
        }
        try FileManager.default.removeItem(at: url)
        await store.reloadHerdrConfig()
        precondition(store.lastGoodImportedSettings == lastGood && store.resolvedSnapshot == snapshot)
        // A FIFO must be rejected without waiting for a writer.
        precondition(mkfifo(url.path, 0o600) == 0)
        await store.reloadHerdrConfig()
        precondition(store.lastGoodImportedSettings == lastGood && store.resolvedSnapshot == snapshot)
        try FileManager.default.removeItem(at: url)
        // A directory is not a readable configuration file.
        await store.loadHerdrConfig(url: FileManager.default.temporaryDirectory)
        precondition(store.lastGoodImportedSettings == lastGood && store.resolvedSnapshot == snapshot)
        precondition(store.herdrConfigPath == url.path, "Failed file selection must preserve last-good path")
        let restarted = AppearanceStore(defaults: defaults)
        precondition(restarted.lastGoodImportedSettings == lastGood && restarted.resolvedSnapshot == snapshot)
        // Cancellation and later source selections supersede suspended I/O.
        try data.write(to: url)
        let pending = Task { await store.loadHerdrConfig(url: url) }
        await Task.yield()
        store.setThemeSource(.native)
        await pending.value
        precondition(store.themeSource == .native)
    }

    @MainActor
    private static func testExplicitNamesAndTerminalSource() throws {
        try withDefaults { defaults in
            let store = AppearanceStore(defaults: defaults)
            try store.applyImportedSettings(ImportedAppearanceSettings(
                themeName: "catppuccin", autoSwitch: true,
                lightName: "catppuccin", darkName: "catppuccin-latte"))
            precondition(store.resolvedSnapshot.light.colors["accent"] == .rgb(137, 180, 250))
            precondition(store.resolvedSnapshot.dark.colors["accent"] == .rgb(30, 102, 245))
            try store.applyImportedSettings(ImportedAppearanceSettings(themeName: "terminal", autoSwitch: false))
            let snapshot = store.resolvedSnapshot
            precondition(snapshot.light.colors["accent"] != snapshot.dark.colors["accent"])
            precondition(snapshot.light.colors["panel_bg"] == .reset)
            precondition(snapshot.dark.colors["text"] == .reset)
            let before = EmbeddedTerminalPalette.theme
            store.setNativeOverride(.rgb(20, 30, 40), for: "accent", scope: .common)
            precondition(EmbeddedTerminalPalette.theme == before)
            precondition(store.resolvedSnapshot.dark.colors["accent"] == .rgb(20, 30, 40))
        }
    }

    @MainActor
    private static func testMainPresetSelection() throws {
        try withDefaults { defaults in
            let store = AppearanceStore(defaults: defaults)
            var publications = 0
            let observation = store.objectWillChange.sink { publications += 1 }
            defer { observation.cancel() }

            precondition(store.unifiedPreset == "uherdr")
            store.setLightPreset("nord")
            precondition(store.unifiedPreset == nil)
            precondition(publications == 1)

            try store.setPreset("dracula")
            precondition(store.unifiedPreset == "dracula")
            precondition(store.lightPreset == "dracula" && store.darkPreset == "dracula")
            precondition(store.resolvedSnapshot.light.colors["accent"] == .rgb(189, 147, 249))
            precondition(store.resolvedSnapshot.dark.colors["accent"] == .rgb(189, 147, 249))
            precondition(publications == 2)

            try store.setPreset("dracula")
            precondition(publications == 2, "Repeated main preset selection must stay silent")
        }
    }

    @MainActor
    private static func testImportedFixedThemeResolutionBoundary() throws {
        try withDefaults { defaults in
            let store = AppearanceStore(defaults: defaults)
            try store.applyImportedSettings(ImportedAppearanceSettings(
                themeName: "nord",
                autoSwitch: false,
                commonOverrides: ["accent": .rgb(4, 5, 6)],
                lightOverrides: ["accent": .rgb(7, 8, 9)],
                darkOverrides: ["accent": .rgb(10, 11, 12)]
            ))
            precondition(store.themeSource == .herdrConfig)
            precondition(store.resolvedSnapshot.light.colors["accent"] == .rgb(4, 5, 6))
            precondition(store.resolvedSnapshot.dark.colors["accent"] == .rgb(4, 5, 6))
        }
    }

    @MainActor
    private static func testLegacyMigrationAndSecondInitialization() {
        withDefaults { defaults in
            defaults.set("dark", forKey: "appearance")
            defaults.set(17.0, forKey: "fontSize")

            let first = AppearanceStore(defaults: defaults)
            precondition(first.mode == .dark)
            precondition(first.fontSize == 17)
            precondition(first.lightPreset == "uherdr" && first.darkPreset == "uherdr")
            precondition(first.themeSource == .native)

            let second = AppearanceStore(defaults: defaults)
            precondition(second.mode == .dark)
            precondition(second.fontSize == 17)
            precondition(second.lightPreset == "uherdr" && second.darkPreset == "uherdr")
        }
    }

    @MainActor
    private static func testInvalidPersistenceIsPreservedUntilAnEdit() {
        withDefaults { defaults in
            defaults.set("sepia", forKey: "appearance")
            defaults.set(99.0, forKey: "fontSize")
            defaults.set("missing-theme", forKey: AppearanceStore.PreferenceKey.lightPreset)
            defaults.set("missing-source", forKey: AppearanceStore.PreferenceKey.themeSource)
            let invalidImported = Data("not-json".utf8)
            defaults.set(invalidImported, forKey: AppearanceStore.PreferenceKey.lastGoodImportedSettings)

            let store = AppearanceStore(defaults: defaults)
            precondition(store.mode == .system && store.fontSize == 13)
            precondition(store.lightPreset == "uherdr" && store.themeSource == .native)
            precondition(store.lastGoodImportedSettings == nil)
            precondition(defaults.string(forKey: "appearance") == "sepia")
            precondition(defaults.double(forKey: "fontSize") == 99)
            precondition(defaults.string(forKey: AppearanceStore.PreferenceKey.lightPreset) == "missing-theme")
            precondition(defaults.string(forKey: AppearanceStore.PreferenceKey.themeSource) == "missing-source")
            precondition(defaults.data(forKey: AppearanceStore.PreferenceKey.lastGoodImportedSettings) == invalidImported)

            store.setMode(.dark)
            store.setFontSize(18)
            store.setLightPreset("nord")
            precondition(defaults.string(forKey: "appearance") == "dark")
            precondition(defaults.double(forKey: "fontSize") == 18)
            precondition(defaults.string(forKey: AppearanceStore.PreferenceKey.lightPreset) == "nord")
        }
        withDefaults { defaults in
            let invalidSettings = ImportedAppearanceSettings(themeName: "missing-theme")
            let savedData = try! JSONEncoder().encode(invalidSettings)
            defaults.set(AppearanceThemeSource.herdrConfig.rawValue, forKey: AppearanceStore.PreferenceKey.themeSource)
            defaults.set(savedData, forKey: AppearanceStore.PreferenceKey.lastGoodImportedSettings)

            let store = AppearanceStore(defaults: defaults)
            precondition(store.themeSource == .native && store.lastGoodImportedSettings == nil)
            precondition(defaults.string(forKey: AppearanceStore.PreferenceKey.themeSource) == AppearanceThemeSource.herdrConfig.rawValue)
            precondition(defaults.data(forKey: AppearanceStore.PreferenceKey.lastGoodImportedSettings) == savedData)
        }
    }

    @MainActor
    private static func testResolutionAndNoOpPublication() throws {
        try withDefaults { defaults in
            let store = AppearanceStore(defaults: defaults)
            var publications = 0
            let observation = store.objectWillChange.sink { publications += 1 }
            defer { observation.cancel() }
            let originalSnapshot = store.resolvedSnapshot

            store.setMode(.system)
            try store.setPreset("uherdr")
            store.resetNativeOverrides()
            precondition(publications == 0, "No-op appearance edits must not publish")
            precondition(store.resolvedSnapshot == originalSnapshot)

            store.setMode(.dark)
            precondition(publications == 1)
            precondition(store.resolvedSnapshot != originalSnapshot)
            store.setMode(.dark)
            precondition(publications == 1)

            try store.setPreset("nord")
            precondition(publications == 2)
            precondition(store.resolvedSnapshot.dark.colors["accent"] == .rgb(136, 192, 208))
            try store.setPreset("nord")
            precondition(publications == 2)

            store.setNativeOverride(.rgb(1, 2, 3), for: "accent", scope: .dark)
            precondition(publications == 3)
            precondition(store.resolvedSnapshot.dark.colors["accent"] == .rgb(1, 2, 3))
            store.setNativeOverride(.rgb(1, 2, 3), for: "accent", scope: .dark)
            precondition(publications == 3)
            store.resetNativeOverrides(scope: .light)
            precondition(publications == 3)
            store.resetNativeOverrides(scope: .dark)
            precondition(publications == 4)
            store.resetNativeOverrides(scope: .dark)
            precondition(publications == 4)
        }
    }

    @MainActor
    private static func testSharedSessionAndDevicePublication() {
        withDefaults { defaults in
            let appearance = AppearanceStore(defaults: defaults)
            let firstProfile = DeviceProfile(name: "First", kind: .local, socketPath: "/tmp/appearance-first.sock", executable: "/tmp/herdr")
            let secondProfile = DeviceProfile(name: "Second", kind: .local, socketPath: "/tmp/appearance-second.sock", executable: "/tmp/herdr")
            let devices = DeviceStore(defaults: defaults, profiles: [firstProfile, secondProfile], appearance: appearance)
            let first = devices.sessions[0]
            let second = devices.sessions[1]
            precondition(first.appearanceStore === appearance && second.appearanceStore === appearance)

            var firstPublications = 0
            var secondPublications = 0
            var devicePublications = 0
            let firstObservation = first.objectWillChange.sink { firstPublications += 1 }
            let secondObservation = second.objectWillChange.sink { secondPublications += 1 }
            let deviceObservation = devices.objectWillChange.sink { devicePublications += 1 }
            defer {
                firstObservation.cancel()
                secondObservation.cancel()
                deviceObservation.cancel()
                devices.stop()
            }

            appearance.setMode(.dark)
            precondition(firstPublications == 1 && secondPublications == 1)
            precondition(devicePublications == 1)
            appearance.setMode(.dark)
            precondition(firstPublications == 1 && secondPublications == 1 && devicePublications == 1)

            first.fontSize = 17
            try! appearance.setPreset("nord")
            appearance.setNativeOverride(.rgb(1, 2, 3), for: "accent", scope: .common)
            let savedAppearance = appearancePreferences(in: defaults)
            devices.select(second)
            precondition(second.appearance == "dark" && second.fontSize == 17)
            precondition(NSDictionary(dictionary: appearancePreferences(in: defaults)).isEqual(to: savedAppearance))
        }
    }

    private static func appearancePreferences(in defaults: UserDefaults) -> [String: Any] {
        defaults.dictionaryRepresentation().filter { key, _ in
            key == "appearance" || key == "fontSize" || key.hasPrefix("appearance.")
        }
    }

    private static func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "uherdr.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
