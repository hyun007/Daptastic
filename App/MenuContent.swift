import SwiftUI

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status)

        Button("Sync Now") {
            model.startSync()
            openWindow.bringToFront(WindowID.sync)
        }
        .disabled(!model.canSync)

        if case .idle = model.phase {} else {
            Button("Show Progress") { openWindow.bringToFront(WindowID.sync) }
        }

        Divider()

        Button("Settings…") { openWindow.bringToFront(WindowID.settings) }
            .keyboardShortcut(",")
        Button("Quit Daptastic") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var status: String {
        if !model.isConfigured { return "Not set up" }
        if model.isBusy { return "Syncing…" }
        if let volume = model.targetVolume { return "Card connected: \(volume.name)" }
        return "Card not connected"
    }
}
