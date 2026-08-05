import Foundation
import Sparkle

/// Wraps Sparkle so the rest of the app sees one object: "can I check?" and
/// "check now". Updates are verified against the EdDSA public key baked into
/// Info.plist, so a tampered download is refused even though the app itself
/// is only ad-hoc signed.
///
/// Sparkle needs a real .app bundle. Running from `swift run` there isn't one,
/// so the updater simply stays dormant instead of logging failures.
@MainActor
final class UpdateController: ObservableObject {
    /// False while an update check is already running, or when there's no
    /// bundle to update (development runs).
    @Published private(set) var canCheck = false

    /// Whether Sparkle checks on its own. Sparkle persists this itself.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var isAvailable: Bool { controller != nil }

    private let controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    init() {
        // A feed URL only exists in the packaged app; without it Sparkle has
        // nothing to check and would just complain on every launch.
        let bundled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        guard let bundled, !bundled.isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
