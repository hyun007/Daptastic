import AppKit
import DaptasticCore
import Observation
import Security
import ServiceManagement
import UserNotifications

@Observable
final class AppModel {
    enum Phase {
        case idle
        /// The card was just plugged in; asking whether to sync.
        case cardConnected(MountedVolume)
        case preparing
        /// The desired set is empty or shrank >30%; the user decides whether deletes run.
        case confirmDeletes(SyncJob)
        case wontFit(shortfall: Int64, albums: [SyncPlan.AlbumSize])
        case syncing(TransferProgress?)
        case finished(SyncJob.Outcome)
        case failed(String)
        case cancelled
    }

    var settings = SyncSettings.load() {
        didSet {
            try? settings.save()
            if settings.username != oldValue.username {
                cachedPassword = nil
                refreshCredentials()
            }
        }
    }
    private(set) var phase: Phase = .idle {
        didSet { notifyIfNeeded() }
    }
    private(set) var volumes: [MountedVolume] = []
    private(set) var hasPassword = false
    private(set) var loginItemStatus = SMAppService.mainApp.status
    private(set) var notificationStatus = UNAuthorizationStatus.notDetermined
    private let notifier = Notifier()
    let updater = Updater()
    /// Bumped to ask the UI to bring the sync window forward (see `MenuBarLabel`).
    private(set) var windowRequest = 0
    /// Set when the card disappears mid-sync, so the failure says why.
    private var cardDisconnected = false
    /// A volume this app is remounting itself; its mount must not prompt to sync.
    private var remountingVolumeID: String?
    private var task: Task<Void, Never>?
    /// Read from the Keychain at most once per launch; each read can raise an access prompt.
    private var cachedPassword: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        refreshCredentials()
        refreshVolumes()
        notifier.onAction = { [weak self] kind, action in self?.handleNotification(kind, action) }
        updater.canNotify = { [weak self] in self?.notificationsEnabled ?? false }
        updater.onUpdateFound = { [weak self] version in
            self?.notifier.post(.updateAvailable, title: "Daptastic \(version) is available",
                                body: "Click to see what's new and install it.")
        }
        updater.onUpdateSeen = { [weak self] in self?.notifier.remove(.updateAvailable) }
        Task {
            await refreshNotificationStatus()
            updater.start()  // Only now can it tell whether to notify.
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeMounted(url) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeUnmounted(url) }
        })
    }

    // MARK: Volume events

    /// Prompts once per mount of the chosen card. Other volumes, and a card that is already
    /// mounted when the app launches, never prompt.
    private func volumeMounted(_ url: URL?) {
        refreshVolumes()
        guard isConfigured, !isBusy, let url, let volume = MountedVolume(url: url), isTarget(volume) else { return }
        if volume.id == remountingVolumeID { return }
        if case .confirmDeletes = phase { return }  // Don't clobber a pending decision.
        phase = .cardConnected(volume)
        // Permission can change in System Settings at any time; check now, not at launch.
        Task {
            await refreshNotificationStatus()
            guard case .cardConnected = phase else { return }
            if notificationsEnabled {
                notifier.post(.cardConnected, title: "“\(volume.name)” connected",
                              body: "Sync your starred music and playlists?")
            } else {
                windowRequest += 1  // No notifications: fall back to the window.
            }
        }
    }

    private func volumeUnmounted(_ url: URL?) {
        let wasTarget = targetVolume.map { $0.url.standardizedFileURL == url?.standardizedFileURL } ?? false
        refreshVolumes()
        guard wasTarget else { return }
        notifier.remove(.cardConnected)
        switch phase {
        case .preparing, .syncing:
            cardDisconnected = true
            task?.cancel()
        case .cardConnected, .confirmDeletes:
            phase = .idle
        default:
            break
        }
    }

    // MARK: State

    var isBusy: Bool {
        switch phase {
        case .preparing, .syncing: true
        default: false
        }
    }

    var hasChosenCard: Bool { settings.volumeUUID != nil || settings.volumeName != nil }
    var isConfigured: Bool { settings.hasServer && hasPassword && hasChosenCard }
    var targetVolume: MountedVolume? { volumes.first(where: isTarget) }
    var canSync: Bool { isConfigured && targetVolume != nil && !isBusy }

    func isTarget(_ volume: MountedVolume) -> Bool {
        if let uuid = settings.volumeUUID { return volume.uuid == uuid }
        return volume.name == settings.volumeName
    }

    func refreshVolumes() {
        volumes = MountedVolume.removable()
    }

    func refreshCredentials() {
        hasPassword = !settings.username.isEmpty && Keychain.hasPassword(account: settings.username)
    }

    // MARK: Notifications

    var notificationsEnabled: Bool {
        notificationStatus == .authorized || notificationStatus == .provisional
    }

    func refreshNotificationStatus() async {
        notificationStatus = await notifier.status()
    }

    func requestNotifications() async {
        _ = await notifier.requestPermission()
        await refreshNotificationStatus()
    }

    func sendTestNotification() {
        notifier.post(.needsAttention, title: "Daptastic notifications are working",
                      body: "You'll hear from Daptastic when your player is plugged in and when a sync finishes.")
    }

    private func handleNotification(_ kind: Notifier.Kind, _ action: Notifier.Action) {
        switch (kind, action) {
        case (.cardConnected, .sync): startSync()  // In the background; the menu bar shows it.
        case (.syncFinished, .eject): eject()
        case (.updateAvailable, _): updater.checkForUpdates()
        default: windowRequest += 1
        }
    }

    /// How a sync ended, or that it needs a decision. A sync started from a notification has no
    /// window open, so this is how you find out.
    private func notifyIfNeeded() {
        let phase = phase
        Task {
            await refreshNotificationStatus()
            if notificationsEnabled { notify(phase) }
        }
    }

    private func notify(_ phase: Phase) {
        switch phase {
        case .finished(let outcome):
            notifier.remove(.needsAttention)
            notifier.post(.syncFinished, title: "Sync complete", body: Self.summary(outcome))
        case .confirmDeletes(let job):
            notifier.post(.needsAttention, title: "Confirm before deleting",
                          body: "\(Self.count(job.plan.deletes.count, "track")) are no longer starred. Click to review before Daptastic deletes them.")
        case .wontFit(let shortfall, _):
            notifier.post(.needsAttention, title: "Not enough space on the card",
                          body: "It needs \(shortfall.formattedBytes) more. Click to see the largest albums.")
        case .failed(let message):
            notifier.post(.needsAttention, title: "Sync failed", body: message)
        default:
            break
        }
    }

    static func summary(_ outcome: SyncJob.Outcome) -> String {
        let s = outcome.sync, p = outcome.playlists
        var parts: [String] = []
        if s.transferred > 0 { parts.append("Copied \(count(s.transferred, "track")) (\(s.transferredBytes.formattedBytes))") }
        if s.deleted > 0 { parts.append("removed \(count(s.deleted, "track"))") }
        if !p.written.isEmpty || !p.removed.isEmpty {
            let names = (p.written + p.removed).map { ($0 as NSString).deletingPathExtension }
            parts.append("updated \(names.count == 1 ? "playlist" : "playlists") \(names.joined(separator: ", "))")
        }
        var summary = parts.isEmpty ? "Already up to date." : parts.joined(separator: "; ") + "."
        if summary.first?.isLowercase == true { summary = summary.prefix(1).uppercased() + summary.dropFirst() }
        if s.withheldDeletes > 0 {
            summary += " Kept \(count(s.withheldDeletes, "un-starred track")) until you confirm."
        }
        return summary
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: Setup

    /// Registers the app itself as a login item, so the plug-in prompt works without
    /// launching it by hand. Registers whatever copy is running — install it first.
    func setOpensAtLogin(_ on: Bool) throws {
        defer { loginItemStatus = SMAppService.mainApp.status }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Also tells Spotlight to skip the card; see `stopSpotlight`.
    func choose(_ volume: MountedVolume) {
        settings.volumeUUID = volume.uuid
        settings.volumeName = volume.name
        Spotlight.writeMarker(on: volume.url)
    }

    /// Whether Spotlight is indexing the card right now; nil if macOS won't say.
    func isSpotlightIndexing(_ volume: MountedVolume) async -> Bool? {
        let url = volume.url
        return await Task.detached { Spotlight.isIndexing(url) }.value
    }

    /// Writes the no-index marker and remounts the card (it stays plugged in) so Spotlight
    /// picks the marker up. Indexing otherwise makes syncing about 3× slower.
    func stopSpotlight(on volume: MountedVolume) async throws {
        Spotlight.writeMarker(on: volume.url)
        remountingVolumeID = volume.id
        defer {
            refreshVolumes()
            // The mount notification arrives after remount returns; let it pass first.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if remountingVolumeID == volume.id { remountingVolumeID = nil }
            }
        }
        _ = try await VolumeRemount.remount(volume.url)
    }

    /// Signs in, makes sure Navidrome reports real paths to this app (switching Report Real Path
    /// on if it can), and adopts the library root it sees. Saves the server and username, and
    /// the password once it has worked. An empty `password` reuses the saved one.
    ///
    /// If macOS is holding the connection for its Local Network permission prompt, calls
    /// `waitingForPermission` and retries every 2 s for up to a minute, so answering Allow is
    /// all it takes.
    func connect(
        server: String, username: String, password: String,
        waitingForPermission: () -> Void = {}
    ) async throws -> ServerSetup.Report {
        guard let url = SyncSettings.serverURL(from: server) else { throw SetupError.invalidServer }
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else { throw SetupError.noServer }
        if username != settings.username { cachedPassword = nil }
        settings.serverURL = url
        settings.username = username
        let password = password.isEmpty ? try savedPassword() : password

        let client = try client(password: password)
        let webAPI = NavidromeWebAPI(serverURL: url, username: username, password: password)
        var report: ServerSetup.Report
        var attempts = 0
        while true {
            do {
                report = try await ServerSetup.connect(client: client, webAPI: webAPI, currentRoot: settings.libraryRoot)
                break
            } catch where LocalNetwork.isBlocked(error) {
                attempts += 1
                guard attempts < 30 else { throw SetupError.localNetworkBlocked }
                waitingForPermission()
                try await Task.sleep(for: .seconds(2))
            }
        }
        // The permission prompt takes focus from a menu-bar app; take it back.
        if attempts > 0 { NSApp.activate() }
        if password != cachedPassword {
            try Keychain.setPassword(password, account: username)
            cachedPassword = password
        }
        refreshCredentials()
        if let root = report.libraryRoot, root != settings.libraryRoot { settings.libraryRoot = root }
        return report
    }

    /// Navidrome's Players page, for the manual Report Real Path step.
    var navidromePlayersURL: URL? {
        // Built as a string: appending(path:) would percent-encode the fragment's "#".
        settings.serverURL.flatMap { URL(string: $0.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/app/#/player") }
    }

    private func savedPassword() throws -> String {
        if let cachedPassword { return cachedPassword }
        guard let password = try Keychain.password(account: settings.username) else {
            throw KeychainError.status(errSecItemNotFound)
        }
        cachedPassword = password
        return password
    }

    private func client(password: String) throws -> SubsonicClient {
        guard let url = settings.serverURL, !settings.username.isEmpty else { throw SetupError.noServer }
        return SubsonicClient(credentials: .init(serverURL: url, username: settings.username, password: password))
    }

    enum SetupError: LocalizedError {
        case noServer, invalidServer, localNetworkBlocked
        var errorDescription: String? {
            switch self {
            case .localNetworkBlocked:
                "macOS isn't letting Daptastic use your local network. Turn Daptastic on in System Settings → Privacy & Security → Local Network, then connect again."
            case .noServer: "Enter the Navidrome server and username in Settings."
            case .invalidServer: "Enter the server as a full address, like http://navidrome.local:4533."
            }
        }
    }

    // MARK: Sync

    func startSync() {
        guard !isBusy else { return }
        guard let volume = targetVolume else { return phase = .failed("The card isn't connected.") }
        guard let password = try? savedPassword() else {
            return phase = .failed("No password saved. Open Settings and test the connection.")
        }
        guard let client = try? client(password: password) else {
            return phase = .failed(SetupError.noServer.localizedDescription)
        }
        let settings = settings
        cardDisconnected = false
        notifier.remove(.cardConnected)
        phase = .preparing
        task = Task {
            do {
                let job = try await SyncJob.prepare(client: client, settings: settings, volume: volume.url)
                if job.plan.requiresDeleteConfirmation {
                    phase = .confirmDeletes(job)
                } else {
                    try await run(job, deletesConfirmed: false)
                }
            } catch {
                finish(with: error)
            }
        }
    }

    /// Answers `.confirmDeletes`: `delete` runs the deletes; otherwise they are withheld.
    func resolveDeletes(_ job: SyncJob, delete: Bool) {
        task = Task {
            do { try await run(job, deletesConfirmed: delete) } catch { finish(with: error) }
        }
    }

    func cancel() {
        if case .confirmDeletes = phase { phase = .idle }
        task?.cancel()
    }

    func dismiss() {
        if !isBusy { phase = .idle }
    }

    func eject() {
        guard let volume = targetVolume else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            phase = .idle
        } catch {
            phase = .failed("Couldn't eject \(volume.name): \(error.localizedDescription)")
        }
    }

    private func run(_ job: SyncJob, deletesConfirmed: Bool) async throws {
        if case .shortfall(let bytes, let albums) = job.preflight(deletesConfirmed: deletesConfirmed) {
            return phase = .wontFit(shortfall: bytes, albums: albums)
        }
        phase = .syncing(nil)
        let throttle = ProgressThrottle { [weak self] progress in
            Task { @MainActor in self?.update(progress) }
        }
        phase = .finished(try await job.run(deletesConfirmed: deletesConfirmed, progress: throttle.report))
    }

    private func update(_ progress: TransferProgress) {
        // Late updates can arrive after the sync has ended; ignore them.
        if case .syncing = phase { phase = .syncing(progress) }
    }

    private func finish(with error: Error) {
        if cardDisconnected {
            return phase = .failed("The card was disconnected during the sync. Finished files were kept; reconnect it and sync again to resume.")
        }
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        phase = cancelled ? .cancelled : .failed(error.localizedDescription)
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
