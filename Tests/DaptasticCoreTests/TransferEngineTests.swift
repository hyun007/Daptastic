import Foundation
import Testing

@testable import DaptasticCore

/// Serves canned `download` responses keyed by song id.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let mimeType: String; let body: Data }
    nonisolated(unsafe) static var responses: [String: Response] = [:]
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value ?? ""
        let stub = Self.lock.withLock { Self.responses[id] }
        guard let stub else { return client!.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": stub.mimeType, "Content-Length": "\(stub.body.count)"])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Several chunks, to exercise streaming.
        stride(from: 0, to: stub.body.count, by: 1000).forEach {
            client!.urlProtocol(self, didLoad: stub.body[$0..<min($0 + 1000, stub.body.count)])
        }
        client!.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct TransferEngineTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "daptastic-test-\(UUID().uuidString)")
    let engine: TransferEngine

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = SubsonicClient(credentials: .init(
            serverURL: URL(string: "http://stub.test")!, username: "u", password: "p"))
        engine = TransferEngine(client: client, musicRoot: root, session: URLSession(configuration: config))
    }

    func track(_ id: String, _ path: String, bytes: Data, mimeType: String = "audio/flac") -> DesiredSet.Track {
        StubProtocol.lock.withLock { StubProtocol.responses[id] = .init(mimeType: mimeType, body: bytes) }
        let song = Song(
            id: id, title: id, album: nil, albumId: nil, artist: nil, track: nil, discNumber: nil, year: nil,
            size: Int64(bytes.count), suffix: nil, contentType: nil, path: nil, duration: nil, bitRate: nil)
        return .init(song: song, relativePath: path)
    }

    func put(_ path: String, _ data: Data) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func sync(_ tracks: [DesiredSet.Track], confirm: Bool = false) async throws -> SyncResult {
        let desired = DesiredSet(tracks: tracks, playlists: [], starredSongIDs: [])
        let plan = try SyncPlanner.plan(
            desired: desired, deviceFiles: try DeviceScanner.scan(root: root),
            manifest: try SyncManifest.load(musicRoot: root))
        return try await engine.execute(plan: plan, desired: desired, deletesConfirmed: confirm)
    }

    @Test func transfersByteIdenticalAndRecordsManifest() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<5000).map { UInt8($0 % 251) })
        let path = "Artist/2000 - Album/CD 01/01 - Song’s.flac"
        let result = try await sync([track("s1", path, bytes: bytes)])

        #expect(result.transferred == 1)
        #expect(try Data(contentsOf: root.appending(path: path)) == bytes)
        #expect(try DeviceScanner.scan(root: root).map(\.relativePath) == [path])
        let manifest = try SyncManifest.load(musicRoot: root)
        #expect(manifest.files == [path: 5000])
        #expect(manifest.lastSyncTrackCount == 1)
    }

    @Test func largeFileIsWrittenInOrderAcrossBlocksAndFlushes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Larger than the 8 MB flush interval, and not a multiple of the 1 MB block size.
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<(9 * 1_048_576 + 12_345)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let result = try await sync([track("big", "Artist/2000 - Album/01 - Big.flac", bytes: bytes)])

        #expect(result.transferred == 1)
        #expect(try Data(contentsOf: root.appending(path: "Artist/2000 - Album/01 - Big.flac")) == bytes)
    }

    @Test func subsonicErrorBodyIsNotWrittenToCard() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = #"<subsonic-response status="failed"><error code="70" message="Song not found"/></subsonic-response>"#
        await #expect(throws: SubsonicError(code: 70, message: "Song not found")) {
            // Claimed size matches the body, so only the content type gives it away.
            try await sync([track("s1", "a.flac", bytes: Data(xml.utf8), mimeType: "text/xml")])
        }
        #expect(try DeviceScanner.scan(root: root).isEmpty)
    }

    @Test func truncatedTransferLeavesNothingBehind() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var t = track("s1", "a.flac", bytes: Data(count: 100))
        t = .init(song: Song(
            id: "s1", title: "", album: nil, albumId: nil, artist: nil, track: nil, discNumber: nil, year: nil,
            size: 200, suffix: nil, contentType: nil, path: nil, duration: nil, bitRate: nil), relativePath: "a.flac")
        await #expect(throws: TransferError.self) { try await sync([t]) }
        #expect(try DeviceScanner.scan(root: root).isEmpty)
    }

    @Test func updateReplacesInPlace() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try put("a.flac", Data(count: 10))
        let bytes = Data(repeating: 7, count: 3000)
        _ = try await sync([track("s1", "a.flac", bytes: bytes)])
        #expect(try Data(contentsOf: root.appending(path: "a.flac")) == bytes)
    }

    @Test func deletesPruneEmptyDirectoriesAndKeepUserFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Four kept, one gone: a 20% shrink, under the confirmation threshold.
        let keep = (1...4).map { track("k\($0)", "Keep/2000 - A/0\($0) - K.flac", bytes: Data(count: 10)) }
        let gone = track("g", "Gone/1990 - B/01 - G.flac", bytes: Data(count: 10))
        _ = try await sync(keep + [gone])
        try put("Gone/1990 - B/._01 - G.flac", Data(count: 1))
        try put("Mine/memo.mp3", Data(count: 1))

        let result = try await sync(keep)
        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Gone").path))
        let kept = keep.map(\.relativePath)
        #expect(try DeviceScanner.scan(root: root).map(\.relativePath).sorted() == kept + ["Mine/memo.mp3"])
        #expect(try SyncManifest.load(musicRoot: root).files.keys.sorted() == kept)
    }

    @Test func shrinkWithholdsDeletesUnlessConfirmed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = (0..<4).map { track("s\($0)", "\($0).flac", bytes: Data(count: 10)) }
        _ = try await sync(tracks)

        let withheld = try await sync([tracks[0]])
        #expect(withheld.deleted == 0 && withheld.withheldDeletes == 3)
        #expect(try DeviceScanner.scan(root: root).count == 4)
        // Withheld files stay in the manifest so they can be deleted once confirmed.
        #expect(try SyncManifest.load(musicRoot: root).files.count == 4)

        // Still withheld on the next run: the baseline must not have moved.
        #expect(try await sync([tracks[0]]).withheldDeletes == 3)

        let confirmed = try await sync([tracks[0]], confirm: true)
        #expect(confirmed.deleted == 3)
        #expect(try DeviceScanner.scan(root: root).map(\.relativePath) == ["0.flac"])
    }

    @Test func adoptsMatchingFilesAlreadyOnCard() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try put("a.flac", Data(count: 10))
        let result = try await sync([track("s1", "a.flac", bytes: Data(count: 10))])
        #expect(result.transferred == 0)
        #expect(try SyncManifest.load(musicRoot: root).files == ["a.flac": 10])
    }

    @Test func staleTemporariesAreRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try put("a.flac" + DeviceScanner.temporarySuffix, Data(count: 5))
        _ = try await sync([])
        #expect(try DeviceScanner.scan(root: root).isEmpty)
    }
}
