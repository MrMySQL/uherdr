import AppKit
import HerdrCore
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var store: AppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var overrideScope: AppearanceOverrideScope = .common

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Picker("Appearance", selection: modeBinding) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)

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
