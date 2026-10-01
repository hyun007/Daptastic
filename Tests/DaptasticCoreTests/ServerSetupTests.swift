import Foundation
import Testing

@testable import DaptasticCore

/// A fake Navidrome: routes by path, records requests.
final class FakeNavidrome: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body: String }
    nonisolated(unsafe) static var routes: [String: [Reply]] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func reset(_ routes: [String: [Reply]]) {
        lock.withLock {
            self.routes = routes
            requests = []
        }
    }

    static func recorded(_ path: String, method: String = "GET") -> [URLRequest] {
        lock.withLock { requests.filter { $0.url?.path == path && ($0.httpMethod ?? "GET") == method } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {  // URLSession moves bodies into streams.
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 {
                data.append(buffer, count: n)
            }
            request.httpBody = data
        }
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        let reply: Reply? = Self.lock.withLock {
            Self.requests.append(request)
            guard var queue = Self.routes[key], !queue.isEmpty else { return nil }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]  // The last reply repeats.
            Self.routes[key] = queue
            return next
        }
        let status = reply?.status ?? 404
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Data((reply?.body ?? "").utf8))
        client!.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let ok = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
private func songs(_ path: String?) -> String {
    let list = path.map { #"[{"id":"s","title":"t","path":"\#($0)"}]"# } ?? "[]"
    return #"{"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":\#(list)}}}"#
}
private let login = FakeNavidrome.Reply(body: #"{"token":"tok","id":"u1","isAdmin":true}"#)
private let players = FakeNavidrome.Reply(body: """
    [{"id":"p1","client":"daptastic","userName":"me","reportRealPath":false,"maxBitRate":0,"name":"daptastic [Daptastic]"},
     {"id":"p2","client":"daptastic","userName":"me","reportRealPath":true},
     {"id":"p3","client":"Amperfy","userName":"me","reportRealPath":false},
     {"id":"p4","client":"daptastic","userName":"someone-else","reportRealPath":false}]
    """)

@Suite(.serialized)
struct ServerSetupTests {
    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeNavidrome.self]
        return URLSession(configuration: config)
    }()
    let server = URL(string: "http://nd.test")!

    var client: SubsonicClient {
        SubsonicClient(credentials: .init(serverURL: server, username: "me", password: "pw"), session: session)
    }
    var web: NavidromeWebAPI { NavidromeWebAPI(serverURL: server, username: "me", password: "pw", session: session) }

    @Test func enablesOnlyThisUsersPlayersThatAreOff() async throws {
        FakeNavidrome.reset(["POST /auth/login": [login], "GET /api/player": [players], "PUT /api/player/p1": [.init(body: "{}")]])
        let result = try await web.enableRealPaths()

        #expect(result == .init(players: 2, enabled: 1))
        let puts = FakeNavidrome.lock.withLock { FakeNavidrome.requests.filter { $0.httpMethod == "PUT" } }
        #expect(puts.map { $0.url!.path } == ["/api/player/p1"])
        #expect(puts[0].value(forHTTPHeaderField: "X-ND-Authorization") == "Bearer tok")
        // The whole record goes back, with only reportRealPath changed.
        let body = try #require(try JSONSerialization.jsonObject(with: puts[0].httpBody!) as? [String: Any])
        #expect(body["reportRealPath"] as? Bool == true)
        #expect(body["name"] as? String == "daptastic [Daptastic]" && body["maxBitRate"] as? Int == 0)
        let loginBody = try #require(try JSONSerialization.jsonObject(with: FakeNavidrome.recorded("/auth/login", method: "POST")[0].httpBody!) as? [String: String])
        #expect(loginBody == ["username": "me", "password": "pw"])
    }

    @Test func webLoginRejected() async {
        FakeNavidrome.reset(["POST /auth/login": [.init(status: 401, body: "")]])
        await #expect(throws: NavidromeWebAPIError.loginRejected(status: 401)) { try await web.enableRealPaths() }
    }

    @Test func noPlayerYet() async {
        FakeNavidrome.reset(["POST /auth/login": [login], "GET /api/player": [.init(body: "[]")]])
        await #expect(throws: NavidromeWebAPIError.noPlayer) { try await web.enableRealPaths() }
    }

    @Test func alreadyOnSkipsTheWebAPI() async throws {
        FakeNavidrome.reset(["GET /rest/ping": [.init(body: ok)],
                             "GET /rest/getRandomSongs": [.init(body: songs("/music/A/2000 - B/01 - C.flac"))]])
        let report = try await ServerSetup.connect(client: client, webAPI: web, currentRoot: "/music")
        #expect(report == .init(realPaths: .alreadyOn, libraryRoot: "/music"))
        #expect(FakeNavidrome.recorded("/auth/login", method: "POST").isEmpty)
    }

    @Test func switchesItOnAndDetectsTheRoot() async throws {
        FakeNavidrome.reset([
            "GET /rest/ping": [.init(body: ok)],
            "GET /rest/getRandomSongs": [.init(body: songs("A/B/01-01 - C.flac")),
                                         .init(body: songs("/data/lib/A/2000 - B/CD 01/01 - C.flac"))],
            "POST /auth/login": [login], "GET /api/player": [players], "PUT /api/player/p1": [.init(body: "{}")],
        ])
        let report = try await ServerSetup.connect(client: client, webAPI: web, currentRoot: "/music")
        #expect(report == .init(realPaths: .enabledAutomatically, libraryRoot: "/data/lib"))
    }

    @Test func fallsBackToManualWhenTheWebAPIFails() async throws {
        FakeNavidrome.reset(["GET /rest/ping": [.init(body: ok)],
                             "GET /rest/getRandomSongs": [.init(body: songs("A/B/C.flac"))],
                             "POST /auth/login": [.init(status: 500, body: "")]])
        let report = try await ServerSetup.connect(client: client, webAPI: web, currentRoot: "/music")
        guard case .needsManualStep = report.realPaths else { Issue.record("expected manual step: \(report)"); return }
    }

    @Test func badCredentialsThrow() async {
        FakeNavidrome.reset(["GET /rest/ping": [.init(body: #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#)]])
        await #expect(throws: SubsonicError.self) {
            try await ServerSetup.connect(client: client, webAPI: web, currentRoot: "/music")
        }
    }

    @Test func libraryRootDetection() {
        #expect(LibraryPath.root(of: "/music/A/2000 - B/01 - C.flac", current: "/music") == "/music")
        #expect(LibraryPath.root(of: "/srv/media/music/A/2000 - B/01 - C.flac", current: "/music") == "/srv/media/music")
        #expect(LibraryPath.root(of: "/lib/A/2000 - B/CD 02/01 - C.flac", current: "/music") == "/lib")
        #expect(LibraryPath.root(of: "A/B/C.flac", current: "/music") == nil)
    }
}

struct LocalNetworkTests {
    @Test func recognisesTheLocalNetworkBlock() {
        let path = "satisfied (Path is satisfied)… unsatisfied (Local network prohibited), interface: en0"
        let blocked = URLError(.notConnectedToInternet, userInfo: ["_NSURLErrorNWPathKey": path])
        #expect(LocalNetwork.isBlocked(blocked))
        let nested = URLError(.notConnectedToInternet, userInfo: [NSUnderlyingErrorKey: NSError(
            domain: "kCFErrorDomainCFNetwork", code: -1009, userInfo: ["_NSURLErrorNWPathKey": path])])
        #expect(LocalNetwork.isBlocked(nested))
    }

    @Test func otherFailuresAreNotTheBlock() {
        #expect(!LocalNetwork.isBlocked(URLError(.notConnectedToInternet)))
        #expect(!LocalNetwork.isBlocked(URLError(.cannotFindHost)))
        #expect(!LocalNetwork.isBlocked(SubsonicError(code: 40, message: nil)))
    }
}
