import CryptoKit
import Foundation

public struct SubsonicCredentials: Sendable {
    public var serverURL: URL
    public var username: String
    public var password: String

    public init(serverURL: URL, username: String, password: String) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
    }
}

public enum SubsonicClientError: Error, LocalizedError {
    case httpStatus(Int)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "HTTP \(code) from server"
        case .malformedResponse(let detail): "Malformed Subsonic response: \(detail)"
        }
    }
}

public struct SubsonicClient: Sendable {
    public static let apiVersion = "1.16.1"
    public static let clientName = "daptastic"
    /// Navidrome keys players on client name *and* User-Agent, and "Report Real Path" is a
    /// per-player setting. A fixed User-Agent keeps the app and CLI on one player that
    /// survives OS and app updates.
    public static let userAgent = "Daptastic"

    let credentials: SubsonicCredentials
    let session: URLSession

    public init(credentials: SubsonicCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: Endpoints

    public func ping() async throws {
        _ = try await call("ping")
    }

    public func starred() async throws -> Starred {
        guard let starred = try await call("getStarred2").starred2 else {
            throw SubsonicClientError.malformedResponse("getStarred2 without starred2")
        }
        return starred
    }

    public func album(id: String) async throws -> Album {
        guard let album = try await call("getAlbum", ["id": id]).album else {
            throw SubsonicClientError.malformedResponse("getAlbum without album")
        }
        return album
    }

    public func playlists() async throws -> [PlaylistSummary] {
        guard let container = try await call("getPlaylists").playlists else {
            throw SubsonicClientError.malformedResponse("getPlaylists without playlists")
        }
        return container.playlist ?? []
    }

    public func playlist(id: String) async throws -> Playlist {
        guard let playlist = try await call("getPlaylist", ["id": id]).playlist else {
            throw SubsonicClientError.malformedResponse("getPlaylist without playlist")
        }
        return playlist
    }

    /// The path the server reports for one random song, or nil if the library is empty.
    /// Absolute means Report Real Path is on for this player; relative means made-up paths.
    public func sampleSongPath() async throws -> String? {
        try await call("getRandomSongs", ["size": "1"]).randomSongs?.song?.first?.path
    }

    /// Original file bytes, never transcoded. The only transfer endpoint; see CLAUDE.md.
    public func downloadURL(songID: String) -> URL {
        url(for: "download", ["id": songID], json: false)
    }

    public func downloadRequest(songID: String) -> URLRequest {
        request(downloadURL(songID: songID))
    }

    // MARK: Plumbing

    func call(_ endpoint: String, _ params: [String: String] = [:]) async throws -> ResponseBody {
        let (data, response) = try await session.data(for: request(url(for: endpoint, params, json: true)))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubsonicClientError.httpStatus(http.statusCode)
        }
        return try Self.decode(data)
    }

    /// Decodes an envelope and throws the in-body error if `status` is not "ok".
    static func decode(_ data: Data) throws -> ResponseBody {
        let body: ResponseBody
        do {
            body = try JSONDecoder().decode(Envelope.self, from: data).response
        } catch {
            throw SubsonicClientError.malformedResponse(String(describing: error))
        }
        if let error = body.error { throw error }
        guard body.status == "ok" else {
            throw SubsonicClientError.malformedResponse("status \(body.status) without error object")
        }
        return body
    }

    func url(for endpoint: String, _ params: [String: String], json: Bool) -> URL {
        let salt = Self.makeSalt()
        var items = [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "t", value: Self.token(password: credentials.password, salt: salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
        ]
        if json { items.append(URLQueryItem(name: "f", value: "json")) }
        items += params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        var components = URLComponents(
            url: credentials.serverURL.appending(path: "rest/\(endpoint)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = items
        return components.url!
    }

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func makeSalt() -> String {
        (0..<12).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}
