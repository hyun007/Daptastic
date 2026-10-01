import SwiftUI

@main
struct DaptasticApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }

        Window("Daptastic", id: WindowID.sync) {
            SyncView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        Window("Daptastic Settings", id: WindowID.settings) {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        Window("Set Up Daptastic", id: WindowID.setup) {
            SetupView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        // First launch opens setup, until the app is configured.
        .defaultLaunchBehavior(model.isConfigured ? .suppressed : .presented)
    }
}

/// The menu-bar icon. Unlike the menu's content, it is always alive, so it is where model
/// requests to open the sync window are turned into `openWindow` calls.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(glyph)  // Template images: macOS tints them for light and dark menu bars.
            .onChange(of: model.windowRequest) { openWindow.bringToFront(WindowID.sync) }
    }

    private var glyph: String {
        switch model.phase {
        case .preparing, .syncing: "MenuBarSyncing"
        // The same states that send a "needs you" notification.
        case .confirmDeletes, .wontFit, .failed: "MenuBarAttention"
        default: "MenuBarIdle"
        }
    }
}

enum WindowID {
    static let sync = "sync"
    static let settings = "settings"
    static let setup = "setup"
}

extension OpenWindowAction {
    /// A menu-bar-only app is never frontmost on its own, so bring the window forward.
    func bringToFront(_ id: String) {
        callAsFunction(id: id)
        NSApp.activate()
    }
}
