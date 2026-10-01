import DaptasticCore
import SwiftUI

/// First-run setup: Navidrome sign-in (which also switches on Report Real Path), picking the
/// card, and launch at login. Opens on its own until the app is configured.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case welcome, server, device, preferences, done
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = Step.welcome
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connection = ConnectionState.idle
    @State private var opensAtLogin = true
    @State private var wantsNotifications = true
    @State private var checksForUpdates = true
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepDots(current: step.rawValue, count: Step.allCases.count)
                .padding(.bottom, 20)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 24)
            footer
        }
        .padding(28)
        .frame(width: 540, height: 500)
        .bringsWindowToFrontOnAppear()
        .onAppear {
            server = model.settings.serverURL?.absoluteString ?? ""
            username = model.settings.username
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Welcome to Daptastic").font(.largeTitle.bold())
                Text("Daptastic copies your starred albums, starred tracks and playlists from Navidrome to your digital audio player — original, lossless files, and only what changed since the last sync.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Setup takes a minute: sign in to Navidrome, plug in your player, done.")
                    .foregroundStyle(.secondary)
            }

        case .server:
            VStack(alignment: .leading, spacing: 14) {
                title("Connect to Navidrome", "Daptastic signs in with your Navidrome account. The password is kept in your Keychain.")
                Form {
                    TextField("Server", text: $server, prompt: Text("http://navidrome.local:4533"))
                    TextField("Username", text: $username, prompt: Text("Required"))
                    SecureField("Password", text: $password, prompt: Text(model.hasPassword ? "Saved in Keychain" : "Required"))
                }
                .formStyle(.columns)
                .disabled(connection == .connecting || connection == .waitingForPermission)
                .onSubmit(connect)
                // Changed details need a fresh sign-in. (Connecting clears the password, so only
                // a newly typed one counts.)
                .onChange(of: [server, username]) { connection = .idle }
                .onChange(of: password) { if !password.isEmpty { connection = .idle } }
                ConnectionStatus(state: connection, playersURL: model.navidromePlayersURL, retry: connect)
            }

        case .device:
            VStack(alignment: .leading, spacing: 14) {
                title("Plug in your player", "Connect your DAP with USB in storage mode, or put its SD card in your Mac.")
                if model.volumes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for a card…").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Card", selection: cardSelection) {
                        if model.targetVolume == nil { Text("Choose…").tag(String?.none) }
                        ForEach(model.volumes) { Text(label(for: $0)).tag(String?.some($0.id)) }
                    }
                    .fixedSize()
                }
                if let volume = model.targetVolume {
                    SpotlightStatusView(volume: volume)
                }
                DisclosureGroup("Advanced") {
                    @Bindable var model = model
                    Form {
                        TextField("Music folder", text: $model.settings.musicFolder, prompt: Text("Card root"))
                    }
                    .formStyle(.columns)
                    .padding(.top, 6)
                    Text("Where music goes on the card. Playlists always go in playlist_data/ at the card root.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear(perform: autoSelectCard)
            .onChange(of: model.volumes) { autoSelectCard() }

        case .preferences:
            VStack(alignment: .leading, spacing: 14) {
                title("Almost done", "")
                Toggle("Open Daptastic at login", isOn: $opensAtLogin)
                Text("So plugging in your player offers to sync without opening the app first.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Notify me when my player is plugged in and when a sync finishes", isOn: $wantsNotifications)
                    .padding(.top, 8)
                Text("macOS will ask you to allow notifications. Without them, Daptastic shows a window instead.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    .padding(.top, 8)
                if let loginItemError {
                    Text(loginItemError).font(.callout).foregroundStyle(.red)
                }
            }

        case .done:
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("You're all set").font(.largeTitle.bold())
                Text(model.targetVolume.map { "“\($0.name)” is connected — sync it now, or any time from the menu bar." }
                     ?? "Plug in your player and Daptastic will offer to sync. You can also sync from the menu bar icon.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { move(-1) }
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Get Started") { move(1) }.keyboardShortcut(.defaultAction)
            case .server:
                if case .connected(let report) = connection {
                    if case .needsManualStep = report.realPaths {
                        Button("Continue Anyway") { move(1) }
                    } else {
                        Button("Continue") { move(1) }.keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canConnect)
                }
            case .device:
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.targetVolume == nil && !model.hasChosenCard)
            case .preferences:
                Button("Continue", action: applyPreferences).keyboardShortcut(.defaultAction)
            case .done:
                Button("Close", action: finish)
                if model.canSync {
                    Button("Sync Now") {
                        finish()
                        model.startSync()
                        openWindow.bringToFront(WindowID.sync)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: Actions

    private var canConnect: Bool {
        SyncSettings.serverURL(from: server) != nil && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (!password.isEmpty || model.hasPassword)
            && connection != .connecting && connection != .waitingForPermission
    }

    private func connect() {
        guard canConnect else { return }
        connection = .connecting
        Task {
            do {
                connection = .connected(try await model.connect(
                    server: server, username: username, password: password,
                    waitingForPermission: { connection = .waitingForPermission }))
                password = ""
            } catch AppModel.SetupError.localNetworkBlocked {
                connection = .localNetworkBlocked
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private func move(_ delta: Int) {
        step = Step(rawValue: step.rawValue + delta) ?? step
    }

    private func autoSelectCard() {
        if !model.hasChosenCard, model.volumes.count == 1 { model.choose(model.volumes[0]) }
    }

    private func applyPreferences() {
        do {
            if opensAtLogin != (model.loginItemStatus == .enabled) { try model.setOpensAtLogin(opensAtLogin) }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
            return
        }
        model.updater.automaticallyChecks = checksForUpdates
        Task {
            if wantsNotifications && model.notificationStatus == .notDetermined { await model.requestNotifications() }
            move(1)
        }
    }

    private func finish() {
        dismissWindow(id: WindowID.setup)
    }

    // MARK: Pieces

    private var cardSelection: Binding<String?> {
        Binding {
            model.targetVolume?.id
        } set: { id in
            if let volume = model.volumes.first(where: { $0.id == id }) { model.choose(volume) }
        }
    }

    private func label(for volume: MountedVolume) -> String {
        guard let free = volume.availableBytes, let total = volume.totalBytes else { return volume.name }
        return "\(volume.name) — \(free.formattedBytes) free of \(total.formattedBytes)"
    }

    private func title(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.bold())
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum ConnectionState: Equatable {
    case idle, connecting, waitingForPermission, localNetworkBlocked
    case connected(ServerSetup.Report)
    case failed(String)
}

/// The result of signing in, including whether real paths are on. Shared with Settings.
struct ConnectionStatus: View {
    let state: ConnectionState
    let playersURL: URL?
    let retry: () -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .waitingForPermission:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("macOS is asking whether Daptastic may use your local network — choose **Allow**.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .localNetworkBlocked:
            VStack(alignment: .leading, spacing: 6) {
                row("xmark.octagon.fill", .red, AppModel.SetupError.localNetworkBlocked.localizedDescription)
                HStack {
                    Link("Open Local Network Settings", destination: LocalNetwork.settingsURL)
                    Button("Try Again", action: retry)
                }
            }
        case .failed(let message):
            row("xmark.octagon.fill", .red, message)
        case .connected(let report):
            VStack(alignment: .leading, spacing: 6) {
                row("checkmark.circle.fill", .green, "Signed in")
                realPaths(report.realPaths)
                if let root = report.libraryRoot {
                    row("folder", .secondary, "Library root: \(root)")
                }
            }
        }
    }

    @ViewBuilder private func realPaths(_ state: ServerSetup.RealPaths) -> some View {
        switch state {
        case .alreadyOn:
            row("checkmark.circle.fill", .green, "Navidrome reports real file paths")
        case .enabledAutomatically:
            row("checkmark.circle.fill", .green, "Turned on “Report Real Path” for Daptastic in Navidrome")
        case .enabledUnverified:
            row("checkmark.circle.fill", .green, "Turned on “Report Real Path” (your library looks empty, so it isn't checked yet)")
        case .needsManualStep(let reason):
            VStack(alignment: .leading, spacing: 6) {
                row("exclamationmark.triangle.fill", .orange, "Couldn't turn on “Report Real Path” automatically (\(reason)).")
                Text("In Navidrome, open Settings → Players, choose “daptastic [Daptastic]” and turn on Report Real Path. Daptastic needs real file paths to mirror your library.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let playersURL { Link("Open Navidrome Players", destination: playersURL) }
                    Button("Check Again", action: retry)
                }
            }
        }
    }

    private func row(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.default, value: current)
    }
}
