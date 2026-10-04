import Foundation
import HerdrCore

/// The user's shortcuts, saved in preferences. Menus observe it; open
/// terminals re-apply their key bindings when it posts `didChange`.
@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()
    static let didChange = Notification.Name("dev.herdr.native.shortcutsChanged")

    @Published private(set) var bindings: ShortcutBindings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = ShortcutBindings.load(from: defaults)
    }

    func update(_ change: (inout ShortcutBindings) -> Void) {
        var next = bindings
        change(&next)
        guard next != bindings else { return }
        bindings = next
        next.save(to: defaults)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
