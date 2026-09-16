import Foundation

public typealias ThemeOverrides = [String: ColorValue]

public struct ThemePalette: Codable, Equatable, Sendable {
    public var colors: ThemeOverrides

    public init(colors: ThemeOverrides) {
        self.colors = colors
    }

    public static let semanticRoles = [
        "window_bg",
        "sidebar_bg",
        "panel_bg",
        "text",
        "secondary_text",
        "border",
        "focus",
        "selection",
        "active_row",
        "status_done",
        "status_working",
        "status_blocked",
        "status_unseen",
        "status_notification",
        "status_interrupted",
        "special_text",
    ]
}
