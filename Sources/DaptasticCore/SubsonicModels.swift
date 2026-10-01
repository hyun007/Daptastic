import Foundation

/// A track as returned by Subsonic (`Child` in the spec).
public struct Song: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let album: String?
    public let albumId: String?
    public let artist: String?
    public let track: Int?
    public let discNumber: Int?
    public let year: Int?
    public let size: Int64?
    public let suffix: String?
    public let contentType: String?
    /// Server-side path. Only the real on-disk path if Navidrome's "Report Real Path" is on
    /// for this client; otherwise Navidrome synthesises one from tags.
    public let path: String?
    public let duration: Int?
    public let bitRate: Int?
}

public struct Album: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let artist: String?
    public let artistId: String?
    public let year: Int?
    public let songCount: Int?
    public let song: [Song]?

    public var songs: [Song] { song ?? [] }
}

public struct ArtistRef: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let albumCount: Int?
}

public struct Starred: Codable, Sendable {
    public let artist: [ArtistRef]?
    public let album: [Album]?
    public let song: [Song]?

    public var artists: [ArtistRef] { artist ?? [] }
    public var albums: [Album] { album ?? [] }
    public var songs: [Song] { song ?? [] }
}

public struct PlaylistSummary: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let songCount: Int?
    public let owner: String?
}

public struct Playlist: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let songCount: Int?
    public let entry: [Song]?

    public var entries: [Song] { entry ?? [] }
}

/// The in-body error object. Subsonic returns this with HTTP 200.
public struct SubsonicError: Error, Codable, Sendable, Equatable, LocalizedError {
    public let code: Int
    public let message: String?

    public var errorDescription: String? {
        "Subsonic error \(code): \(message ?? "no message")"
    }
}

struct SongsContainer: Decodable {
    let song: [Song]?
}

struct PlaylistsContainer: Decodable {
    let playlist: [PlaylistSummary]?
}

struct ResponseBody: Decodable {
    let status: String
    let error: SubsonicError?
    let starred2: Starred?
    let album: Album?
    let playlists: PlaylistsContainer?
    let playlist: Playlist?
    let randomSongs: SongsContainer?
}

struct Envelope: Decodable {
    let response: ResponseBody

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}
