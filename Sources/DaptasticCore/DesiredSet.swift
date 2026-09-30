import Foundation

/// Everything that should be on the device, as reported by the server.
public struct DesiredSet: Codable, Sendable {
    public struct Track: Codable, Sendable {
        public let song: Song
        /// Relative to the library root; mirrored as-is onto the device.
        public let relativePath: String
    }

    public struct NamedPlaylist: Codable, Sendable {
        public let name: String
        /// Ordered; may repeat a song.
        public let songIDs: [String]
    }

    /// Deduplicated by song id, in first-seen order.
    public let tracks: [Track]
    public let playlists: [NamedPlaylist]
    /// Ordered as the server returns them; becomes the "starred tracks" playlist.
    public let starredSongIDs: [String]

    public var totalBytes: Int64 { tracks.reduce(0) { $0 + ($1.song.size ?? 0) } }
}

public enum DesiredSetBuilder {
    /// Starred albums (expanded to every track) ∪ starred tracks ∪ every playlist's tracks.
    /// Starred artists are ignored: one star could pull in hundreds of albums.
    /// Throws if any song's path is missing or outside `libraryRoot`.
    public static func build(client: SubsonicClient, libraryRoot: String = LibraryPath.defaultRoot) async throws -> DesiredSet {
        var songs: [Song] = []
        var seen: Set<String> = []
        func add(_ song: Song) {
            if seen.insert(song.id).inserted { songs.append(song) }
        }

        let starred = try await client.starred()
        for albumRef in starred.albums {
            try await client.album(id: albumRef.id).songs.forEach(add)
        }
        starred.songs.forEach(add)

        var playlists: [DesiredSet.NamedPlaylist] = []
        for summary in try await client.playlists() {
            let playlist = try await client.playlist(id: summary.id)
            playlist.entries.forEach(add)
            playlists.append(.init(name: playlist.name, songIDs: playlist.entries.map(\.id)))
        }

        let tracks = try songs.map { song in
            guard let path = song.path else { throw LibraryPathError.missingPath(songID: song.id) }
            return DesiredSet.Track(song: song, relativePath: try LibraryPath.relative(path, root: libraryRoot))
        }
        return DesiredSet(tracks: tracks, playlists: playlists, starredSongIDs: starred.songs.map(\.id))
    }
}
