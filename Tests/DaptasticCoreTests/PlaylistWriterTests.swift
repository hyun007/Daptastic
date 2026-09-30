import Foundation
import Testing

@testable import DaptasticCore

struct PlaylistWriterTests {
    let volume = FileManager.default.temporaryDirectory.appending(path: "daptastic-test-\(UUID().uuidString)")

    func desired(playlists: [(String, [String])], starred: [String] = []) -> DesiredSet {
        let paths = [
            "a": "Led Zeppelin/1973 - Houses of the Holy/06 - D\u{2019}yer Mak\u{2019}er.flac",
            "b": "Led Zeppelin/1971 - IV/CD 01/04 - Stairway to Heaven.flac",
            "c": "Beyonce\u{301}/2003 - X/01 - Y.flac",  // NFD from the server; must be written NFC
        ]
        let tracks = paths.sorted { $0.key < $1.key }.map { id, path in
            DesiredSet.Track(song: Song(
                id: id, title: id, album: nil, albumId: nil, artist: nil, track: nil, discNumber: nil, year: nil,
                size: 1, suffix: nil, contentType: nil, path: nil, duration: nil, bitRate: nil), relativePath: path)
        }
        return DesiredSet(tracks: tracks, playlists: playlists.map { .init(name: $0.0, songIDs: $0.1) }, starredSongIDs: starred)
    }

    func writer(musicFolder: String = "") -> PlaylistWriter {
        var settings = SyncSettings()
        settings.musicFolder = musicFolder
        return PlaylistWriter(volume: volume, settings: settings)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: volume.appending(path: "playlist_data/\(name)"), encoding: .utf8)
    }

    @Test func writesVerifiedV1Format() throws {
        defer { try? FileManager.default.removeItem(at: volume) }
        let result = try writer().write(desired: desired(playlists: [("jammin", ["b", "a", "c", "b"])], starred: ["a"]))

        #expect(result.written == ["jammin.m3u8", "Starred Tracks.m3u8"])
        let body = try read("jammin.m3u8")
        #expect(body == """
            #EXTM3U
            ../Led Zeppelin/1971 - IV/CD 01/04 - Stairway to Heaven.flac
            ../Led Zeppelin/1973 - Houses of the Holy/06 - D\u{2019}yer Mak\u{2019}er.flac
            ../Beyonc\u{E9}/2003 - X/01 - Y.flac
            ../Led Zeppelin/1971 - IV/CD 01/04 - Stairway to Heaven.flac

            """)
        #expect(!body.contains("\r"))
        #expect(body.unicodeScalars.contains("\u{E9}") && !body.unicodeScalars.contains("\u{301}"))
        #expect(try read("Starred Tracks.m3u8").hasSuffix("../Led Zeppelin/1973 - Houses of the Holy/06 - D\u{2019}yer Mak\u{2019}er.flac\n"))
    }

    @Test func prefixesMusicFolder() throws {
        defer { try? FileManager.default.removeItem(at: volume) }
        _ = try writer(musicFolder: "/Music/").write(desired: desired(playlists: [("p", ["c"])]))
        #expect(try read("p.m3u8") == "#EXTM3U\n../Music/Beyonc\u{E9}/2003 - X/01 - Y.flac\n")
        // The manifest lives in the music root.
        #expect(try SyncManifest.load(musicRoot: volume.appending(path: "Music")).playlists == ["p.m3u8"])
    }

    @Test func namesAreSafeAndUnique() {
        #expect(PlaylistWriter.safeName("AC/DC: Best?") == "AC_DC_ Best_")
        #expect(PlaylistWriter.safeName(" ...") == "Playlist")
        let names = PlaylistWriter.filenames(for: desired(
            playlists: [("Mix", ["a"]), ("mix", ["b"]), ("Empty", []), ("Starred Tracks", ["c"])], starred: ["a"]))
        #expect(names.map(\.0) == ["Mix.m3u8", "mix (2).m3u8", "Starred Tracks.m3u8", "Starred Tracks (2).m3u8"])
    }

    @Test func leavesOtherFilesAloneAndRemovesOwnStale() throws {
        defer { try? FileManager.default.removeItem(at: volume) }
        let dir = volume.appending(path: "playlist_data")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: dir.appending(path: "Road Trip.m3u8"))

        let first = try writer().write(desired: desired(playlists: [("Road Trip", ["a"]), ("Old", ["b"])]))
        #expect(first.skipped == ["Road Trip.m3u8"] && first.written == ["Old.m3u8"])
        #expect(try read("Road Trip.m3u8") == "mine")

        let second = try writer().write(desired: desired(playlists: [("Road Trip", ["a"])]))
        #expect(second.removed == ["Old.m3u8"])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Old.m3u8").path))
        #expect(try read("Road Trip.m3u8") == "mine")
    }

    @Test func unchangedIsNotRewritten() throws {
        defer { try? FileManager.default.removeItem(at: volume) }
        let set = desired(playlists: [("p", ["a"])])
        _ = try writer().write(desired: set)
        #expect(try writer().write(desired: set).unchanged == ["p.m3u8"])
    }

    @Test func caseOnlyRenameKeepsTheFile() throws {
        defer { try? FileManager.default.removeItem(at: volume) }
        _ = try writer().write(desired: desired(playlists: [("Jammin", ["a"])]))
        let result = try writer().write(desired: desired(playlists: [("jammin", ["a", "b"])]))

        #expect(result.skipped.isEmpty && result.removed.isEmpty)
        #expect(try read("jammin.m3u8").contains("Stairway"))
        #expect(try SyncManifest.load(musicRoot: volume).playlists == ["jammin.m3u8"])
    }
}
