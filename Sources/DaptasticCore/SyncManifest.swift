import Foundation

/// What this app has written to the device. Stored on the device itself, so it travels with
/// the card. Only files listed here are ever deleted — anything else on the card is left alone.
public struct SyncManifest: Codable, Sendable, Equatable {
    public var version = 1
    /// Relative path → size, for every file this app wrote.
    public var files: [String: Int64] = [:]
    /// Size of the desired set at the last successful sync; drives the shrink guard.
    public var lastSyncTrackCount: Int?
    public var lastSyncDate: Date?
    /// Filenames in `playlist_data/` this app wrote. Optional so older manifests still decode.
    public var playlists: [String]?

    public init() {}

    public static func url(musicRoot: URL) -> URL {
        musicRoot.appending(path: ".daptastic/manifest.json")
    }

    /// An empty manifest if none exists yet.
    public static func load(musicRoot: URL) throws -> SyncManifest {
        let url = url(musicRoot: musicRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return SyncManifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncManifest.self, from: Data(contentsOf: url))
    }

    public func save(musicRoot: URL) throws {
        let url = Self.url(musicRoot: musicRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
