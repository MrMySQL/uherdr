import Foundation

public enum ThemeResolver {
    public static func resolve(base: ThemePalette, layers: [ThemeOverrides]) -> ThemePalette {
        var resolved = base.colors
        for layer in layers {
            for (role, value) in layer {
                switch value {
                case .reset:
                    if let baseValue = base.colors[role] {
                        resolved[role] = baseValue
                    } else {
                        resolved.removeValue(forKey: role)
                    }
                case .rgb:
                    resolved[role] = value
                }
            }
            updateNormalizedRoles(in: &resolved, from: layer, base: base.colors)
        }
        return ThemePalette(colors: resolved)
    }

    private static let normalizedRoleSources = [
        "window_bg": "surface_dim",
        "secondary_text": "subtext0",
        "border": "surface1",
        "focus": "accent",
        "selection": "selection_bg",
        "active_row": "active_row_bg",
        "status_done": "green",
        "status_working": "yellow",
        "status_blocked": "red",
        "status_unseen": "blue",
        "status_notification": "teal",
        "status_interrupted": "peach",
        "special_text": "mauve",
    ]

    private static func updateNormalizedRoles(
        in resolved: inout ThemeOverrides,
        from layer: ThemeOverrides,
        base: ThemeOverrides
    ) {
        for (role, source) in normalizedRoleSources
        where base[role] != nil && layer[source] != nil && layer[role] == nil {
            if layer[source] == .reset {
                resolved[role] = base[role]
            } else {
                resolved[role] = resolved[source]
            }
        }
    }
}
