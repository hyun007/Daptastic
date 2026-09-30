import Foundation

public enum SyncPlannerError: Error, LocalizedError, Equatable {
    case missingSize(path: String)
    /// Paths that are distinct on the server but identical on a case-insensitive card.
    case pathCollision([String])

    public var errorDescription: String? {
        switch self {
        case .missingSize(let path): "The server reported no size for \(path)"
        case .pathCollision(let paths): "These paths collide on a case-insensitive card: \(paths.joined(separator: ", "))"
        }
    }
}

public struct SyncPlan: Sendable {
    public struct Transfer: Sendable {
        public let track: DesiredSet.Track
        /// The on-device file this replaces, if any; nil for a new file.
        public let replacing: DeviceFile?

        public var size: Int64 { track.song.size ?? 0 }
    }

    public struct AlbumSize: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
    }

    public enum Preflight: Sendable, Equatable {
        case fits(needed: Int64, available: Int64)
        case shortfall(bytes: Int64, largestAlbums: [AlbumSize])
    }

    public let transfers: [Transfer]
    /// Manifest-listed files no longer desired. Only ever files this app wrote.
    public let deletes: [DeviceFile]
    public let staleTemporaries: [DeviceFile]
    public let unchangedCount: Int
    /// Deleting needs the user's OK: the desired set is empty, or >30% smaller than last sync.
    public let requiresDeleteConfirmation: Bool
    /// Every desired album by total size, largest first — what to un-star if it will not fit.
    public let albumsBySize: [AlbumSize]

    public var adds: [Transfer] { transfers.filter { $0.replacing == nil } }
    public var updates: [Transfer] { transfers.filter { $0.replacing != nil } }

    /// Assumes stale temporaries and (if applied) deletes are removed before transferring.
    /// Headroom for the largest file covers an update's temp copy coexisting with the original.
    public func preflight(freeBytes: Int64, applyingDeletes: Bool) -> Preflight {
        let freed = staleTemporaries.reduce(0) { $0 + $1.size }
            + (applyingDeletes ? deletes.reduce(0) { $0 + $1.size } : 0)
        let growth = transfers.reduce(0) { $0 + max(0, $1.size - ($1.replacing?.size ?? 0)) }
        let needed = growth + (transfers.map(\.size).max() ?? 0)
        let available = freeBytes + freed
        return needed <= available
            ? .fits(needed: needed, available: available)
            : .shortfall(bytes: needed - available, largestAlbums: Array(albumsBySize.prefix(10)))
    }
}

public enum SyncPlanner {
    public static let shrinkThreshold = 0.7

    /// Compares by relative path and size. Paths are matched case- and
    /// normalisation-insensitively, because exFAT is case-insensitive and macOS may hand
    /// names back decomposed.
    public static func plan(desired: DesiredSet, deviceFiles: [DeviceFile], manifest: SyncManifest) throws -> SyncPlan {
        var staleTemporaries: [DeviceFile] = []
        var onDevice: [String: DeviceFile] = [:]
        for file in deviceFiles {
            if file.relativePath.hasSuffix(DeviceScanner.temporarySuffix) {
                staleTemporaries.append(file)
            } else {
                onDevice[key(file.relativePath)] = file
            }
        }

        var desiredKeys: [String: String] = [:]
        var collisions: [String] = []
        var transfers: [SyncPlan.Transfer] = []
        var unchanged = 0
        for track in desired.tracks {
            guard let size = track.song.size else { throw SyncPlannerError.missingSize(path: track.relativePath) }
            let k = key(track.relativePath)
            if let other = desiredKeys.updateValue(track.relativePath, forKey: k) {
                collisions += [other, track.relativePath]
                continue
            }
            switch onDevice[k] {
            case nil: transfers.append(.init(track: track, replacing: nil))
            case let file? where file.size != size: transfers.append(.init(track: track, replacing: file))
            case .some: unchanged += 1
            }
        }
        guard collisions.isEmpty else { throw SyncPlannerError.pathCollision(collisions) }

        let deletes = manifest.files.keys
            .filter { desiredKeys[key($0)] == nil }
            .compactMap { onDevice[key($0)] }
            .sorted { $0.relativePath < $1.relativePath }

        let shrunk = desired.tracks.isEmpty
            || manifest.lastSyncTrackCount.map { Double(desired.tracks.count) < Double($0) * shrinkThreshold } ?? false

        return SyncPlan(
            transfers: transfers,
            deletes: deletes,
            staleTemporaries: staleTemporaries,
            unchangedCount: unchanged,
            requiresDeleteConfirmation: !deletes.isEmpty && shrunk,
            albumsBySize: albumsBySize(desired)
        )
    }

    static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func albumsBySize(_ desired: DesiredSet) -> [SyncPlan.AlbumSize] {
        var sizes: [String: Int64] = [:]
        var names: [String: String] = [:]
        for track in desired.tracks {
            let song = track.song
            let id = song.albumId ?? (track.relativePath as NSString).deletingLastPathComponent
            sizes[id, default: 0] += song.size ?? 0
            names[id] = names[id] ?? "\(song.artist ?? "Unknown") — \(song.album ?? "Unknown")"
        }
        return sizes
            .map { SyncPlan.AlbumSize(name: names[$0.key]!, bytes: $0.value) }
            .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }
}
