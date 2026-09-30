import DaptasticCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var password = ""
    @State private var connection = Connection.untested
    @State private var loginItemError: String?

    enum Connection: Equatable {
        case untested, testing, ok
        case failed(String)
    }

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

            Section("Navidrome") {
                TextField("Server", text: $server, prompt: Text("http://navidrome.local:4533"))
                    .onChange(of: server) { commitServer() }
                TextField("Username", text: $model.settings.username, prompt: Text("Required"))
                SecureField("Password", text: $password,
                            prompt: Text(model.hasPassword ? "Saved in Keychain" : "Required"))
                HStack {
                    Button("Test Connection", action: test)
                        .disabled(SyncSettings.serverURL(from: server) == nil || model.settings.username.isEmpty
                                  || (password.isEmpty && !model.hasPassword)
                                  || connection == .testing)
                    connectionStatus
                }
            }

            Section {
                Picker("Card", selection: cardSelection) {
                    if !model.hasChosenCard { Text("Choose…").tag(String?.none) }
                    ForEach(model.volumes) { Text($0.name).tag(String?.some($0.id)) }
                    if model.hasChosenCard && model.targetVolume == nil {
                        Text("\(model.settings.volumeName ?? "Saved card") (not connected)").tag(String?.some(savedTag))
                    }
                }
                TextField("Music folder", text: $model.settings.musicFolder, prompt: Text("Card root"))
            } header: {
                Text("Device")
            } footer: {
                Text("Connect the DAP in USB storage mode to choose its card. Playlists always go in playlist_data/ at the card root.\n\nTip: add the card to System Settings → Spotlight → Search Privacy. Spotlight indexing the card can slow syncing to a third.")
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

    @ViewBuilder private var connectionStatus: some View {
        switch connection {
        case .untested: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
        }
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

    private func test() {
        commitServer()
        connection = .testing
        Task {
            do {
                try await model.testConnection(password: password)
                password = ""
                connection = .ok
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }
}
