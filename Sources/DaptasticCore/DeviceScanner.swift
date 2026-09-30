import Foundation

public struct DeviceFile: Sendable, Equatable, Hashable {
    public let relativePath: String
    public let size: Int64

    public init(relativePath: String, size: Int64) {
        self.relativePath = relativePath
        self.size = size
    }
}

public enum DeviceScanner {
    /// Suffix for in-flight transfers; renamed away on completion. Leftovers are stale.
    public static let temporarySuffix = ".daptastic-partial"

    /// Every regular file under `root`, relative to it. Skips hidden entries — `.daptastic/`,
    /// `.Spotlight-V100`, and the `._*` AppleDouble files macOS litters on exFAT.
    public static func scan(root: URL) throws -> [DeviceFile] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var files: [DeviceFile] = []
        while let relative = enumerator.nextObject() as? String {
            let attributes = enumerator.fileAttributes ?? [:]
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            if (relative as NSString).lastPathComponent.hasPrefix(".") {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            files.append(DeviceFile(relativePath: relative, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0))
        }
        return files
    }

    public static func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = values.volumeAvailableCapacity else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return Int64(capacity)
    }
}
