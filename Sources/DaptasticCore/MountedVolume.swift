import Foundation

/// A mounted removable volume. The DAP's card is identified by UUID, not name — cards are
/// often called "Untitled" or "NO NAME".
public struct MountedVolume: Sendable, Hashable, Identifiable {
    public let url: URL
    public let name: String
    public let uuid: String?
    public let totalBytes: Int64?
    public let availableBytes: Int64?

    public var id: String { uuid ?? url.path }

    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    public init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
              values.volumeIsRemovable == true || values.volumeIsEjectable == true
        else { return nil }
        self.url = url
        self.name = values.volumeName ?? url.lastPathComponent
        self.uuid = values.volumeUUIDString
        self.totalBytes = values.volumeTotalCapacity.map(Int64.init)
        self.availableBytes = values.volumeAvailableCapacity.map(Int64.init)
    }

    public static func removable() -> [MountedVolume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(MountedVolume.init(url:)).sorted { $0.name < $1.name }
    }
}
