import DaptasticCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var password = ""
    @State private var connection = ConnectionState.idle
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open at login", isOn: Binding {
                    model.loginItemStatus == .enabled
                } set: { on in
                    do {
                        try model.setOpensAtLogin(on)
                        loginItemError = nil
                    } catch {
                        loginItemError = error.localizedDescription
                    }
                })
            } footer: {
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                } else if model.loginItemStatus == .requiresApproval {
                    Text("Approve Daptastic in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("So plugging in the DAP prompts to sync without starting the app yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                NotificationStatusRow()
            }

            Section("Navidrome") {
                TextField("Server", text: $server, prompt: Text("http://navidrome.local:4533"))
                    .onChange(of: server) { commitServer() }
                TextField("Username", text: $model.settings.username, prompt: Text("Required"))
                SecureField("Password", text: $password,
                            prompt: Text(model.hasPassword ? "Saved in Keychain" : "Required"))
                Button("Test Connection", action: test)
                    .disabled(SyncSettings.serverURL(from: server) == nil || model.settings.username.isEmpty
                              || (password.isEmpty && !model.hasPassword)
                              || connection == .connecting || connection == .waitingForPermission)
                ConnectionStatus(state: connection, playersURL: model.navidromePlayersURL, retry: test)
            }

            Section {
                Picker("Card", selection: cardSelection) {
                    if !model.hasChosenCard { Text("Choose…").tag(String?.none) }
                    ForEach(model.volumes) { Text($0.name).tag(String?.some($0.id)) }
                    if model.hasChosenCard && model.targetVolume == nil {
                        Text("\(model.settings.volumeName ?? "Saved card") (not connected)").tag(String?.some(savedTag))
                    }
                }
                if let volume = model.targetVolume {
                    SpotlightStatusView(volume: volume)
                }
                TextField("Music folder", text: $model.settings.musicFolder, prompt: Text("Card root"))
            } header: {
                Text("Device")
            } footer: {
                Text("Connect the DAP in USB storage mode to choose its card. Playlists always go in playlist_data/ at the card root.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                TextField("Library root on server", text: $model.settings.libraryRoot)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { server = model.settings.serverURL?.absoluteString ?? "" }
    }

    private var savedTag: String { "saved" }

    private var cardSelection: Binding<String?> {
        Binding {
            model.targetVolume?.id ?? (model.hasChosenCard ? savedTag : nil)
        } set: { id in
            if let volume = model.volumes.first(where: { $0.id == id }) { model.choose(volume) }
        }
    }

    /// Saves as you type, once the text is a usable URL; clearing the field clears it.
    private func commitServer() {
        if let url = SyncSettings.serverURL(from: server) {
            if url != model.settings.serverURL { model.settings.serverURL = url }
        } else if server.trimmingCharacters(in: .whitespaces).isEmpty {
            model.settings.serverURL = nil
        }
    }

    /// The same sign-in as setup, so it also switches Report Real Path on if needed.
    private func test() {
        connection = .connecting
        Task {
            do {
                connection = .connected(try await model.connect(
                    server: server, username: model.settings.username, password: password,
                    waitingForPermission: { connection = .waitingForPermission }))
                password = ""
            } catch AppModel.SetupError.localNetworkBlocked {
                connection = .localNetworkBlocked
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }
}

/// Whether notifications are on, with the way to turn them on.
private struct NotificationStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            switch model.notificationStatus {
            case .authorized, .provisional, .ephemeral:
                Label("Notifications are on", systemImage: "bell.badge")
                Spacer()
                Button("Send Test Notification", action: model.sendTestNotification)
            case .denied:
                Label("Notifications are off for Daptastic", systemImage: "bell.slash")
                Spacer()
                Link("Open Notification Settings", destination: URL(string:
                    "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=cc.jofam.daptastic")!)
            default:
                Label("Notifications aren't set up", systemImage: "bell")
                Spacer()
                Button("Turn On") { Task { await model.requestNotifications() } }
            }
        }
        .task { await model.refreshNotificationStatus() }
    }
}
