import Foundation

public enum LibraryPathError: Error, LocalizedError, Equatable {
    case missingPath(songID: String)
    case outsideRoot(path: String, root: String)

    public var errorDescription: String? {
        switch self {
        case .missingPath(let id):
            "Song \(id) has no path; turn on \"Report Real Path\" for the \"daptastic [Daptastic]\" player in Navidrome"
        case .outsideRoot(let path, let root):
            "\(path) is not under the library root \(root). Turn on \"Report Real Path\" for the \"daptastic [Daptastic]\" player in Navidrome (Settings → Players), and check the library root"
        }
    }
}

/// With "Report Real Path" on, Navidrome returns absolute server paths such as
/// `/music/Artist/YYYY - Album/NN - Title.ext`. The library root is not exposed by the API,
/// so it is configured.
public enum LibraryPath {
    public static let defaultRoot = "/music"

    /// The path relative to `root`, which is what gets mirrored onto the device.
    public static func relative(_ path: String, root: String) throws -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { throw LibraryPathError.outsideRoot(path: path, root: root) }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else {
            throw LibraryPathError.outsideRoot(path: path, root: root)
        }
        return relative
    }
}
