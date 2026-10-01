import Foundation
import Testing

@testable import DaptasticCore

private func track(_ path: String, size: Int64?, album: String = "A") -> DesiredSet.Track {
    let song = Song(
        id: path, title: path, album: album, albumId: album, artist: "Artist", track: nil, discNumber: nil,
        year: nil, size: size, suffix: nil, contentType: nil, path: "/music/" + path, duration: nil, bitRate: nil)
    return DesiredSet.Track(song: song, relativePath: path)
}

private func desired(_ tracks: [DesiredSet.Track]) -> DesiredSet {
    DesiredSet(tracks: tracks, playlists: [], starredSongIDs: [])
}

private func manifest(_ files: [String: Int64], lastCount: Int? = nil) -> SyncManifest {
    var manifest = SyncManifest()
    manifest.files = files
    manifest.lastSyncTrackCount = lastCount
    return manifest
}

struct SyncPlannerTests {
    @Test func classifiesAddUpdateUnchanged() throws {
        let plan = try SyncPlanner.plan(
            desired: desired([track("a/1.flac", size: 10), track("a/2.flac", size: 20), track("a/3.flac", size: 30)]),
            deviceFiles: [.init(relativePath: "a/1.flac", size: 10), .init(relativePath: "a/2.flac", size: 5)],
            manifest: SyncManifest())
        #expect(plan.unchangedCount == 1)
        #expect(plan.updates.map(\.track.relativePath) == ["a/2.flac"])
        #expect(plan.updates.first?.replacing?.size == 5)
        #expect(plan.adds.map(\.track.relativePath) == ["a/3.flac"])
        #expect(plan.deletes.isEmpty)
    }

    @Test func matchesAcrossCaseAndUnicodeNormalisation() throws {
        let nfc = "Beyonc\u{E9}/1.flac"
        let nfdUpper = "BEYONCE\u{301}/1.flac"
        let plan = try SyncPlanner.plan(
            desired: desired([track(nfc, size: 10)]),
            deviceFiles: [.init(relativePath: nfdUpper, size: 10)],
            manifest: manifest([nfdUpper: 10]))
        #expect(plan.unchangedCount == 1)
        #expect(plan.transfers.isEmpty && plan.deletes.isEmpty)
    }

    @Test func deletesOnlyManifestListedFiles() throws {
        let plan = try SyncPlanner.plan(
            desired: desired([track("keep.flac", size: 1)]),
            deviceFiles: [
                .init(relativePath: "keep.flac", size: 1),
                .init(relativePath: "ours-unstarred.flac", size: 2),
                .init(relativePath: "users-own.mp3", size: 3),
            ],
            manifest: manifest(["keep.flac": 1, "ours-unstarred.flac": 2, "already-gone.flac": 4]))
        #expect(plan.deletes == [.init(relativePath: "ours-unstarred.flac", size: 2)])
    }

    @Test func separatesStaleTemporaries() throws {
        let temp = "a/1.flac" + DeviceScanner.temporarySuffix
        let plan = try SyncPlanner.plan(
            desired: desired([track("a/1.flac", size: 10)]),
            deviceFiles: [.init(relativePath: temp, size: 4)],
            manifest: SyncManifest())
        #expect(plan.staleTemporaries == [.init(relativePath: temp, size: 4)])
        #expect(plan.adds.count == 1)
    }

    @Test(arguments: [
        (desiredCount: 0, lastCount: 10, expected: true),   // empty desired set
        (desiredCount: 6, lastCount: 10, expected: true),   // shrank 40%
        (desiredCount: 7, lastCount: 10, expected: false),  // shrank exactly 30%
        (desiredCount: 9, lastCount: nil as Int?, expected: false),
    ])
    func shrinkGuard(desiredCount: Int, lastCount: Int?, expected: Bool) throws {
        let tracks = (0..<desiredCount).map { track("\($0).flac", size: 1) }
        let plan = try SyncPlanner.plan(
            desired: desired(tracks),
            deviceFiles: [.init(relativePath: "old.flac", size: 1)],
            manifest: manifest(["old.flac": 1], lastCount: lastCount))
        #expect(plan.requiresDeleteConfirmation == expected)
    }

    @Test func shrinkGuardIgnoredWhenNothingToDelete() throws {
        let plan = try SyncPlanner.plan(desired: desired([]), deviceFiles: [], manifest: manifest([:], lastCount: 100))
        #expect(!plan.requiresDeleteConfirmation)
    }

    @Test func caseCollisionThrows() {
        #expect(throws: SyncPlannerError.pathCollision(["a/X.flac", "a/x.flac"])) {
            try SyncPlanner.plan(
                desired: desired([track("a/X.flac", size: 1), track("a/x.flac", size: 1)]),
                deviceFiles: [], manifest: SyncManifest())
        }
    }

    @Test func missingSizeThrows() {
        #expect(throws: SyncPlannerError.missingSize(path: "a.flac")) {
            try SyncPlanner.plan(desired: desired([track("a.flac", size: nil)]), deviceFiles: [], manifest: SyncManifest())
        }
    }

    @Test func preflight() throws {
        // Adds 100 + 50, update 80 over 60 → growth 170, headroom 100 → needs 270.
        let plan = try SyncPlanner.plan(
            desired: desired([
                track("big/1.flac", size: 100, album: "Big"),
                track("small/1.flac", size: 50, album: "Small"),
                track("small/2.flac", size: 80, album: "Small"),
            ]),
            deviceFiles: [
                .init(relativePath: "small/2.flac", size: 60),
                .init(relativePath: "gone.flac", size: 40),
                .init(relativePath: "x" + DeviceScanner.temporarySuffix, size: 10),
            ],
            manifest: manifest(["gone.flac": 40]))

        #expect(plan.preflight(freeBytes: 260, applyingDeletes: false) == .fits(needed: 270, available: 270))
        #expect(plan.preflight(freeBytes: 220, applyingDeletes: true) == .fits(needed: 270, available: 270))
        #expect(plan.preflight(freeBytes: 200, applyingDeletes: false) == .shortfall(
            bytes: 60,
            largestAlbums: [.init(name: "Artist — Small", bytes: 130), .init(name: "Artist — Big", bytes: 100)]))
    }
}

struct DeviceScannerTests {
    @Test func scansRelativePathsSkippingHidden() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daptastic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "Artist/2000 - Album/CD 01/01 - Song’s.flac": 3,
            "Artist/2000 - Album/CD 01/._01 - Song’s.flac": 1,
            ".daptastic/manifest.json": 2,
            ".DS_Store": 1,
        ]
        for (path, size) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }

        #expect(try DeviceScanner.scan(root: root) == [.init(relativePath: "Artist/2000 - Album/CD 01/01 - Song’s.flac", size: 3)])
    }

    @Test func manifestRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daptastic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try SyncManifest.load(musicRoot: root) == SyncManifest())

        var manifest = manifest(["a/1.flac": 10], lastCount: 1)
        manifest.lastSyncDate = Date(timeIntervalSince1970: 1_800_000_000)
        try manifest.save(musicRoot: root)
        #expect(try SyncManifest.load(musicRoot: root) == manifest)
    }
}

struct SpotlightMarkerTests {
    @Test func createsMarkerOnceAtVolumeRoot() throws {
        let volume = FileManager.default.temporaryDirectory.appending(path: "daptastic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volume) }
        Spotlight.writeMarker(on: volume)
        Spotlight.writeMarker(on: volume)
        #expect(try FileManager.default.contentsOfDirectory(atPath: volume.path) == [".metadata_never_index"])
    }
}
