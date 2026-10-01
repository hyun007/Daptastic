import Foundation

/// First-run connection: checks the credentials, makes sure Navidrome reports real file paths
/// to this app (switching Report Real Path on itself if needed), and works out the library
/// root from a real path.
public enum ServerSetup {
    public enum RealPaths: Sendable, Equatable {
        case alreadyOn
        case enabledAutomatically
        /// Switched on, but the library is empty so it couldn't be checked.
        case enabledUnverified
        /// The user has to switch it on in Navidrome's Players page.
        case needsManualStep(reason: String)
    }

    public struct Report: Sendable, Equatable {
        public let realPaths: RealPaths
        /// The library root seen in a real path, when one was seen.
        public let libraryRoot: String?
    }

    /// Throws only if the credentials don't work; everything after that fails soft into
    /// `.needsManualStep`.
    public static func connect(client: SubsonicClient, webAPI: NavidromeWebAPI, currentRoot: String) async throws -> Report {
        try await client.ping()  // Also registers this app as a player.
        if let path = try await client.sampleSongPath(), path.hasPrefix("/") {
            return Report(realPaths: .alreadyOn, libraryRoot: LibraryPath.root(of: path, current: currentRoot))
        }

        do {
            do {
                _ = try await webAPI.enableRealPaths()
            } catch NavidromeWebAPIError.noPlayer {
                try await client.ping()
                _ = try await webAPI.enableRealPaths()
            }
        } catch {
            return Report(realPaths: .needsManualStep(reason: error.localizedDescription), libraryRoot: nil)
        }

        guard let path = try await client.sampleSongPath() else {
            return Report(realPaths: .enabledUnverified, libraryRoot: nil)
        }
        guard path.hasPrefix("/") else {
            return Report(realPaths: .needsManualStep(reason: "Navidrome still reports made-up paths"), libraryRoot: nil)
        }
        return Report(realPaths: .enabledAutomatically, libraryRoot: LibraryPath.root(of: path, current: currentRoot))
    }
}
