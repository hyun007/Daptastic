import Foundation

/// User preferences. Non-secret only — the password lives in the Keychain.
public struct SyncSettings: Codable, Sendable, Equatable {
    /// Nothing is built in: the server and username come from Settings (or CLI flags).
    public var serverURL: URL?
    public var username = ""
    /// Navidrome's library root as it appears in real paths.
    public var libraryRoot = LibraryPath.defaultRoot
    /// Where music goes, relative to the card's volume root. Empty means the card root.
    public var musicFolder = ""
    /// The DAP's card, by volume UUID; its name is only for display.
    public var volumeUUID: String?
    public var volumeName: String?

    public init() {}

    public var hasServer: Bool { serverURL != nil && !username.isEmpty }

    /// An http(s) URL with a host, or nil. `URL(string:)` alone accepts almost anything.
    public static func serverURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }

    public func musicRoot(onVolume volume: URL) -> URL {
        let folder = musicFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty ? volume : volume.appending(path: folder, directoryHint: .isDirectory)
    }

    static let defaultsKey = "syncSettings"
    public static let suiteName = "cc.jofam.daptastic"

    /// The app's own defaults domain. Inside the app (whose bundle ID is `suiteName`) that is
    /// `.standard` — a suite named after the app's own bundle ID is not allowed — and the CLI
    /// reaches the same domain through the suite.
    public static var sharedDefaults: UserDefaults {
        Bundle.main.bundleIdentifier == suiteName ? .standard : UserDefaults(suiteName: suiteName)!
    }

    public static func load(from defaults: UserDefaults = sharedDefaults) -> SyncSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(SyncSettings.self, from: data)
        else { return SyncSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults = sharedDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
