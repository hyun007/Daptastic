import Foundation

public struct PlaylistWriteResult: Sendable, Equatable {
    public var written: [String] = []
    public var unchanged: [String] = []
    public var removed: [String] = []
    /// Names that clash with a file in `playlist_data/` this app did not write.
    public var skipped: [String] = []
}

/// Writes one `.m3u8` per Navidrome playlist, plus one for starred tracks, into
/// `playlist_data/` at the card root. Format verified on the V1: `#EXTM3U`, UTF-8 NFC, LF,
/// entries relative to the playlist file (`../Artist/…`), order and repeats preserved.
public struct PlaylistWriter: Sendable {
    public static let directoryName = "playlist_data"
    public static let starredName = "Starred Tracks"

    let volume: URL
    let musicRoot: URL
    let musicFolder: String

    public init(volume: URL, settings: SyncSettings) {
        self.volume = volume
        self.musicRoot = settings.musicRoot(onVolume: volume)
        self.musicFolder = settings.musicFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var directory: URL { volume.appending(path: Self.directoryName, directoryHint: .isDirectory) }

    /// Run after a successful transfer, so every entry already exists on the card. Only
    /// playlists recorded in the manifest are overwritten or removed.
    public func write(desired: DesiredSet) throws -> PlaylistWriteResult {
        var manifest = try SyncManifest.load(musicRoot: musicRoot)
        // Compare by key throughout: on exFAT "Jammin.m3u8" and "jammin.m3u8" are one file.
        let owned = manifest.playlists ?? []
        let ownedKeys = Set(owned.map(SyncPlanner.key))
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(atPath: directory.path)
        for name in contents where name.hasSuffix(DeviceScanner.temporarySuffix) {
            try? fm.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
        }
        let existing = Set(contents.map(SyncPlanner.key))

        let paths = Dictionary(desired.tracks.map { ($0.song.id, $0.relativePath) }, uniquingKeysWith: { a, _ in a })
        var result = PlaylistWriteResult()
        var kept: [String] = []
        for (filename, songIDs) in Self.filenames(for: desired) {
            if existing.contains(SyncPlanner.key(filename)) && !ownedKeys.contains(SyncPlanner.key(filename)) {
                result.skipped.append(filename)
                continue
            }
            let body = "#EXTM3U\n" + songIDs.compactMap { paths[$0] }.map { entry(for: $0) + "\n" }.joined()
            let data = Data(body.precomposedStringWithCanonicalMapping.utf8)
            let url = directory.appending(path: filename, directoryHint: .notDirectory)
            if (try? Data(contentsOf: url)) == data {
                result.unchanged.append(filename)
            } else {
                try writeAtomically(data, to: url)
                result.written.append(filename)
            }
            kept.append(filename)
        }

        let keptKeys = Set(kept.map(SyncPlanner.key))
        for filename in owned.sorted() where !keptKeys.contains(SyncPlanner.key(filename)) {
            try? fm.removeItem(at: directory.appending(path: filename, directoryHint: .notDirectory))
            result.removed.append(filename)
        }

        manifest.playlists = kept.sorted()
        try manifest.save(musicRoot: musicRoot)
        return result
    }

    func entry(for relativePath: String) -> String {
        "../" + (musicFolder.isEmpty ? "" : musicFolder + "/") + relativePath
    }

    /// Navidrome playlists in server order, then starred tracks. Empty playlists are dropped.
    /// Names are made filesystem-safe and unique case-insensitively.
    static func filenames(for desired: DesiredSet) -> [(String, [String])] {
        let named = desired.playlists.map { ($0.name, $0.songIDs) } + [(starredName, desired.starredSongIDs)]
        var taken: Set<String> = []
        var result: [(String, [String])] = []
        for (name, songIDs) in named where !songIDs.isEmpty {
            let base = safeName(name)
            var candidate = base
            var n = 2
            while taken.contains(SyncPlanner.key(candidate)) {
                candidate = "\(base) (\(n))"
                n += 1
            }
            taken.insert(SyncPlanner.key(candidate))
            result.append((candidate + ".m3u8", songIDs))
        }
        return result
    }

    /// Playlist names are free text in Navidrome, unlike library filenames, so they do need
    /// cleaning for exFAT.
    static func safeName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(name.unicodeScalars.map { illegal.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Playlist" : cleaned
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = URL(filePath: url.path + DeviceScanner.temporarySuffix)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(code)
        }
    }
}
