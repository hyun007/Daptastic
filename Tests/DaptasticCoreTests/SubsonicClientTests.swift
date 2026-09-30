import Foundation
import Testing

@testable import DaptasticCore

struct SubsonicClientTests {
    @Test func tokenMatchesSpecExample() {
        // From the Subsonic API docs.
        #expect(SubsonicClient.token(password: "sesame", salt: "c19b2d") == "26719a1196d2a940705a59634eb18eab")
    }

    @Test func errorInHTTP200BodyThrows() {
        let json = """
            {"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}
            """
        #expect(throws: SubsonicError(code: 40, message: "Wrong username or password")) {
            try SubsonicClient.decode(Data(json.utf8))
        }
    }

    @Test func failedStatusWithoutErrorObjectThrows() {
        let json = #"{"subsonic-response":{"status":"failed","version":"1.16.1"}}"#
        #expect(throws: SubsonicClientError.self) { try SubsonicClient.decode(Data(json.utf8)) }
    }

    @Test func nonJSONThrows() {
        #expect(throws: SubsonicClientError.self) { try SubsonicClient.decode(Data("<html/>".utf8)) }
    }

    @Test func decodesAlbumWithNonASCIIPaths() throws {
        let json = """
            {"subsonic-response":{"status":"ok","version":"1.16.1","album":{
              "id":"al1","name":"Get the Balance Right!","artist":"Depeche Mode","year":1983,"songCount":1,
              "song":[{"id":"s1","title":"Café “Mix”","track":1,"size":31457280,"suffix":"flac",
                       "path":"Depeche Mode/1983 - Get the Balance Right!/01 - Café “Mix”.flac"}]}}}
            """
        let album = try #require(try SubsonicClient.decode(Data(json.utf8)).album)
        #expect(album.songs.first?.path == "Depeche Mode/1983 - Get the Balance Right!/01 - Café “Mix”.flac")
        #expect(album.songs.first?.size == 31_457_280)
    }

    @Test func emptyStarredDecodes() throws {
        let json = #"{"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{}}}"#
        let starred = try #require(try SubsonicClient.decode(Data(json.utf8)).starred2)
        #expect(starred.albums.isEmpty && starred.songs.isEmpty)
    }

    @Test func urlCarriesAuthAndParams() throws {
        let client = SubsonicClient(credentials: .init(
            serverURL: URL(string: "http://example.test:4533")!, username: "u1", password: "pw"))
        let url = client.downloadURL(songID: "abc")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(url.path == "/rest/download")
        #expect(dict["id"] == "abc")
        #expect(dict["u"] == "u1")
        #expect(dict["f"] == nil)
        #expect(dict["t"] == SubsonicClient.token(password: "pw", salt: dict["s"]!))
        #expect(client.downloadRequest(songID: "abc").value(forHTTPHeaderField: "User-Agent") == "Daptastic")
    }
}

struct LibraryPathTests {
    @Test func stripsRoot() throws {
        #expect(try LibraryPath.relative("/music/Beastie Boys/1992 - Check Your Head/CD 01/19 - In 3’s.mp3", root: "/music")
            == "Beastie Boys/1992 - Check Your Head/CD 01/19 - In 3’s.mp3")
        #expect(try LibraryPath.relative("/music/A/1999 - B/01 - C.flac", root: "/music/") == "A/1999 - B/01 - C.flac")
    }

    @Test func rejectsPathsOutsideRoot() {
        // A synthesised (Report Real Path off) path, a sibling directory, and a traversal.
        for path in ["Bruce Springsteen/Born to Run/01 - Thunder Road.flac", "/musicx/A/B/C.flac", "/music/../etc/x.flac"] {
            #expect(throws: LibraryPathError.outsideRoot(path: path, root: "/music")) {
                try LibraryPath.relative(path, root: "/music")
            }
        }
    }
}

struct SyncSettingsTests {
    @Test func nothingIsBuiltIn() {
        #expect(SyncSettings().serverURL == nil && SyncSettings().username.isEmpty && !SyncSettings().hasServer)
    }

    @Test func serverURLValidation() {
        #expect(SyncSettings.serverURL(from: " http://10.0.0.2:4533 ")?.absoluteString == "http://10.0.0.2:4533")
        #expect(SyncSettings.serverURL(from: "https://navidrome.example") != nil)
        for bad in ["", "navidrome.local", "http://", "ftp://host", "not a url"] {
            #expect(SyncSettings.serverURL(from: bad) == nil, "\(bad)")
        }
    }

    @Test func savedSettingsStillDecode() throws {
        let json = #"{"username":"u","libraryRoot":"/music","musicFolder":"","serverURL":"http://1.2.3.4:4533"}"#
        let settings = try JSONDecoder().decode(SyncSettings.self, from: Data(json.utf8))
        #expect(settings.serverURL?.absoluteString == "http://1.2.3.4:4533" && settings.hasServer)
    }
}
