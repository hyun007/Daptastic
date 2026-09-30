import AppKit
import DaptasticCore
import Observation
import Security
import ServiceManagement

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
    private(set) var phase: Phase = .idle
    private(set) var volumes: [MountedVolume] = []
    private(set) var hasPassword = false
    private(set) var loginItemStatus = SMAppService.mainApp.status
    /// Bumped to ask the UI to bring the sync window forward (see `MenuBarLabel`).
    private(set) var windowRequest = 0
    /// Set when the card disappears mid-sync, so the failure says why.
    private var cardDisconnected = false
    private var task: Task<Void, Never>?
    /// Read from the Keychain at most once per launch; each read can raise an access prompt.
    private var cachedPassword: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        refreshCredentials()
        refreshVolumes()
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
        if case .confirmDeletes = phase { return }  // Don't clobber a pending decision.
        phase = .cardConnected(volume)
        windowRequest += 1
    }

    private func volumeUnmounted(_ url: URL?) {
        let wasTarget = targetVolume.map { $0.url.standardizedFileURL == url?.standardizedFileURL } ?? false
        refreshVolumes()
        guard wasTarget else { return }
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

    // MARK: Setup

    /// Registers the app itself as a login item, so the plug-in prompt works without
    /// launching it by hand. Registers whatever copy is running — install it first.
    func setOpensAtLogin(_ on: Bool) throws {
        defer { loginItemStatus = SMAppService.mainApp.status }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    func choose(_ volume: MountedVolume) {
        settings.volumeUUID = volume.uuid
        settings.volumeName = volume.name
    }

    /// Pings with `password`, saving it only if that works; with an empty `password`, tests
    /// the saved one without rewriting it.
    func testConnection(password: String) async throws {
        guard !password.isEmpty else {
            return try await client(password: try savedPassword()).ping()
        }
        try await client(password: password).ping()
        try Keychain.setPassword(password, account: settings.username)
        cachedPassword = password
        refreshCredentials()
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
        case noServer
        var errorDescription: String? { "Enter the Navidrome server and username in Settings." }
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
