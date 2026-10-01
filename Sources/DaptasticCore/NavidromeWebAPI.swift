import Foundation

public enum NavidromeWebAPIError: Error, LocalizedError, Equatable {
    case loginRejected(status: Int)
    case httpStatus(Int)
    case unexpectedResponse
    case noPlayer

    public var errorDescription: String? {
        switch self {
        case .loginRejected(let status): "Navidrome's web login was refused (HTTP \(status))"
        case .httpStatus(let status): "Navidrome returned HTTP \(status)"
        case .unexpectedResponse: "Navidrome's web API answered in an unexpected format"
        case .noPlayer: "Navidrome hasn't registered this app as a player yet"
        }
    }
}

/// Navidrome's own web-UI API (`/auth/login`, `/api/*`) — what its web pages use, not the
/// Subsonic API and not a documented contract. Everything built on it must fail soft.
public struct NavidromeWebAPI: Sendable {
    public struct RealPathResult: Sendable, Equatable {
        /// This app's players found for the user.
        public let players: Int
        /// How many had Report Real Path off and were switched on.
        public let enabled: Int
    }

    let serverURL: URL
    let username: String
    let password: String
    let session: URLSession

    public init(serverURL: URL, username: String, password: String, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.session = session
    }

    /// Turns on Report Real Path for every player of this app owned by the user. Players are
    /// keyed by client + User-Agent, so there can be several; any user may edit their own.
    /// Each record is sent back whole with only `reportRealPath` changed.
    public func enableRealPaths(client: String = SubsonicClient.clientName) async throws -> RealPathResult {
        let token = try await login()
        let (data, _) = try await send(request("api/player", token: token))
        guard let players = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NavidromeWebAPIError.unexpectedResponse
        }
        // Admins see every user's players; keep this user's.
        let ours = players.filter {
            $0["client"] as? String == client && ($0["userName"] as? String).map { $0 == username } ?? true
        }
        guard !ours.isEmpty else { throw NavidromeWebAPIError.noPlayer }

        var enabled = 0
        for var player in ours where player["reportRealPath"] as? Bool != true {
            guard let id = player["id"] as? String else { throw NavidromeWebAPIError.unexpectedResponse }
            player["reportRealPath"] = true
            var put = request("api/player/\(id)", token: token)
            put.httpMethod = "PUT"
            put.setValue("application/json", forHTTPHeaderField: "Content-Type")
            put.httpBody = try JSONSerialization.data(withJSONObject: player)
            _ = try await send(put)
            enabled += 1
        }
        return RealPathResult(players: ours.count, enabled: enabled)
    }

    func login() async throws -> String {
        var request = URLRequest(url: serverURL.appending(path: "auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NavidromeWebAPIError.loginRejected(status: status) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String
        else { throw NavidromeWebAPIError.unexpectedResponse }
        return token
    }

    private func request(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw NavidromeWebAPIError.httpStatus(status) }
        return (data, response)
    }
}
