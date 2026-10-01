import AppKit
import Sparkle

/// Sparkle updates, adapted to a menu-bar app. An update found by a scheduled check goes to
/// `onUpdateFound` (a notification) rather than a window, which for a menu-bar app — often just
/// opened at login — would land behind everything. Clicking it calls `checkForUpdates()`, which
/// shows the update. "Check for Updates…" always shows Sparkle's window directly.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    var onUpdateFound: (_ version: String) -> Void = { _ in }
    /// Whether `onUpdateFound` can reach the user; if not, Sparkle shows its window as usual.
    var canNotify: () -> Bool = { false }
    var onUpdateSeen: () -> Void = {}

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Call once `canNotify` can answer: Sparkle checks within moments of starting.
    func start() {
        controller.startUpdater()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate (called on the main thread)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Sparkle counts any check right after launch as "in focus", even a background launch at
        // login, so notify whenever notifications work.
        !MainActor.assumeIsolated { canNotify() }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { onUpdateFound(version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { onUpdateSeen() }
    }
}
