import Combine
import Foundation
import Sparkle

/// Sparkle updates for release builds. The updater only starts when the bundle
/// carries a feed and public key (scripts/build-app.sh adds both), so `swift run`
/// and unconfigured builds never check.
@MainActor
final class AppUpdater: ObservableObject {
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return !(info["SUFeedURL"] as? String ?? "").isEmpty && !(info["SUPublicEDKey"] as? String ?? "").isEmpty
    }

    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController?

    private init() {
        guard Self.isConfigured else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheckForUpdates)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
