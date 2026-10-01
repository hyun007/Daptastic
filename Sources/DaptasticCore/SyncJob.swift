import Foundation

public enum SyncJobError: Error, LocalizedError {
    case wontFit(shortfall: Int64)

    public var errorDescription: String? {
        switch self {
        case .wontFit(let bytes):
            "Not enough space on the card: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) short"
        }
    }
}

/// One sync, end to end: `prepare` reads the server and the card without changing anything;
/// `run` transfers, deletes, then writes playlists. Shared by the app and the CLI.
public struct SyncJob: Sendable {
    public struct Outcome: Sendable {
        public let sync: SyncResult
        public let playlists: PlaylistWriteResult
    }

    public let desired: DesiredSet
    public let plan: SyncPlan
    public let freeBytes: Int64
    let client: SubsonicClient
    let settings: SyncSettings
    let volume: URL

    public static func prepare(client: SubsonicClient, settings: SyncSettings, volume: URL) async throws -> SyncJob {
        let root = settings.musicRoot(onVolume: volume)
        let desired = try await DesiredSetBuilder.build(client: client, libraryRoot: settings.libraryRoot)
        // A music folder that does not exist yet simply has nothing in it.
        let deviceFiles = FileManager.default.fileExists(atPath: root.path) ? try DeviceScanner.scan(root: root) : []
        let plan = try SyncPlanner.plan(
            desired: desired, deviceFiles: deviceFiles, manifest: try SyncManifest.load(musicRoot: root))
        return SyncJob(
            desired: desired, plan: plan, freeBytes: try DeviceScanner.availableCapacity(at: volume),
            client: client, settings: settings, volume: volume)
    }

    /// Deletes only free space if they will actually run.
    public func preflight(deletesConfirmed: Bool) -> SyncPlan.Preflight {
        plan.preflight(freeBytes: freeBytes, applyingDeletes: !plan.requiresDeleteConfirmation || deletesConfirmed)
    }

    /// Refuses up front if the pre-flight fails. Cancel the calling task to stop.
    public func run(
        deletesConfirmed: Bool,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> Outcome {
        if case .shortfall(let bytes, _) = preflight(deletesConfirmed: deletesConfirmed) {
            throw SyncJobError.wontFit(shortfall: bytes)
        }
        Spotlight.writeMarker(on: volume)
        let sync = try await TransferEngine(client: client, musicRoot: settings.musicRoot(onVolume: volume))
            .execute(plan: plan, desired: desired, deletesConfirmed: deletesConfirmed, progress: progress)
        let playlists = try PlaylistWriter(volume: volume, settings: settings).write(desired: desired)
        return Outcome(sync: sync, playlists: playlists)
    }
}

/// Passes on at most one update per `interval`, plus every file's final update.
public final class ProgressThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private let handler: @Sendable (TransferProgress) -> Void
    private let lock = NSLock()
    private var last = Date.distantPast

    public init(interval: TimeInterval = 0.1, _ handler: @escaping @Sendable (TransferProgress) -> Void) {
        self.interval = interval
        self.handler = handler
    }

    public func report(_ progress: TransferProgress) {
        let now = Date()
        let due = lock.withLock {
            guard progress.fileBytes == progress.fileTotal || now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
        }
        if due { handler(progress) }
    }
}
