import AppKit
import HerdrCore
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var store: AppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var overrideScope: AppearanceOverrideScope = .common

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 15) {
            Picker("Appearance", selection: modeBinding) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)

            Picker("Theme source", selection: Binding(get: { store.themeSource }, set: { source in
                if source == .herdrConfig && store.lastGoodImportedSettings == nil {
                    Task { await store.reloadHerdrConfig() }
                } else { store.setThemeSource(source) }
            })) {
                Text("Native").tag(AppearanceThemeSource.native)
                Text("Herdr config").tag(AppearanceThemeSource.herdrConfig)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Choose File…", action: chooseConfigFile)
                Button("Reload") { Task { await store.reloadHerdrConfig() } }
                    .disabled(store.isLoadingConfig)
                if store.isLoadingConfig { ProgressView().controlSize(.small) }
            }
            Text(store.herdrConfigPath ?? AppearanceStore.defaultHerdrConfigURL.path)
                .font(.caption).textSelection(.enabled)
            if let diagnostic = store.importDiagnostic, !diagnostic.isEmpty {
                Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let messages = store.lastGoodImportedSettings?.diagnostics, !messages.isEmpty {
                Text(messages.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
            }
            if store.themeSource == .herdrConfig, let imported = store.lastGoodImportedSettings {
                Text("Imported theme: \(imported.themeName) • \(imported.autoSwitch ? "Auto-switch" : "Fixed")")
                    .font(.caption)
                if imported.autoSwitch, imported.lightName != nil || imported.darkName != nil {
                    Text("Light: \(imported.lightName ?? imported.themeName) • Dark: \(imported.darkName ?? imported.themeName)")
                        .font(.caption)
                }
                Text("Read-only import. Local overrides apply after imported colors. The terminal theme uses this app’s embedded ANSI palette; there is no outer terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Picker("Theme", selection: unifiedPresetBinding) {
                    if store.unifiedPreset == nil {
                        Text("Custom (mixed)").tag("")
                    }
                    ForEach(BuiltInThemes.names, id: \.self) { Text(themeLabel($0)).tag($0) }
                }
                Picker("Light theme", selection: lightPresetBinding) {
                    ForEach(BuiltInThemes.names, id: \.self) { Text(themeLabel($0)).tag($0) }
                }
                Picker("Dark theme", selection: darkPresetBinding) {
                    ForEach(BuiltInThemes.names, id: \.self) { Text(themeLabel($0)).tag($0) }
                }
            }
            .disabled(store.themeSource == .herdrConfig)

            HStack {
                Text("Terminal text").font(.callout)
                Slider(value: fontSizeBinding, in: 10...22, step: 1)
                Text("\(Int(store.fontSize)) pt")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 38)
            }

            Divider()
            HStack {
                Text("UI color overrides").font(.headline)
                Spacer()
                Picker("Section", selection: $overrideScope) {
                    Text("Common").tag(AppearanceOverrideScope.common)
                    Text("Light").tag(AppearanceOverrideScope.light)
                    Text("Dark").tag(AppearanceOverrideScope.dark)
                }
                .labelsHidden()
                .frame(width: 180)
                Button("Reset section") { store.resetNativeOverrides(scope: overrideScope) }
                    .disabled(store.nativeOverrides[overrideScope].isEmpty)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    ForEach(AppearanceStore.supportedOverrideRoles, id: \.self) { role in
                        HStack {
                            ColorPicker(roleLabel(role), selection: colorBinding(for: role), supportsOpacity: false)
                            if store.nativeOverrides[overrideScope][role] != nil {
                                Button {
                                    store.setNativeOverride(nil, for: role, scope: overrideScope)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Use the theme value")
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 210)

            Text("Theme changes preview immediately. Terminal programs keep their existing ANSI colors.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        }
        .frame(maxHeight: 620)
    }

    private func chooseConfigFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let initial = store.herdrConfigPath.map { URL(fileURLWithPath: $0) } ?? AppearanceStore.defaultHerdrConfigURL
        panel.directoryURL = initial.deletingLastPathComponent()
        panel.nameFieldStringValue = initial.lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await store.loadHerdrConfig(url: url) }
        }
    }

    private var modeBinding: Binding<AppearanceMode> {
        Binding(get: { store.mode }, set: store.setMode)
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { store.fontSize }, set: store.setFontSize)
    }

    private var unifiedPresetBinding: Binding<String> {
        Binding(
            get: { store.unifiedPreset ?? "" },
            set: { selection in
                guard !selection.isEmpty else { return }
                try? store.setPreset(selection)
            }
        )
    }

    private var lightPresetBinding: Binding<String> {
        Binding(get: { store.lightPreset }, set: store.setLightPreset)
    }

    private var darkPresetBinding: Binding<String> {
        Binding(get: { store.darkPreset }, set: store.setDarkPreset)
    }

    private func colorBinding(for role: String) -> Binding<Color> {
        Binding(
            get: {
                if case let .rgb(red, green, blue) = store.nativeOverrides[overrideScope][role] {
                    return Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
                }
                return NativePalette(palette: paletteForDisplayedSection).color(role)
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                store.setNativeOverride(
                    .rgb(component(converted.redComponent), component(converted.greenComponent), component(converted.blueComponent)),
                    for: role,
                    scope: overrideScope
                )
            }
        )
    }

    private var paletteForDisplayedSection: ThemePalette {
        switch overrideScope {
        case .light: store.resolvedSnapshot.light
        case .dark: store.resolvedSnapshot.dark
        case .common:
            NativePalette(snapshot: store.resolvedSnapshot, colorScheme: colorScheme).palette
        }
    }

    private func component(_ value: CGFloat) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }

    private func themeLabel(_ value: String) -> String {
        value.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private func roleLabel(_ value: String) -> String {
        value.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }
}
