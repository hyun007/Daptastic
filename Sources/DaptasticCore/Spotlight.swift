import DiskArbitration
import Foundation

/// Spotlight indexing a card reads every new file back over USB while a sync writes, cutting
/// throughput to about a third. A marker file at the volume root turns indexing off — from
/// the next time the volume is mounted (verified: `mdutil -s` then reports "Indexing and
/// searching disabled").
public enum Spotlight {
    static let marker = ".metadata_never_index"

    /// Best effort; a no-op if the marker is already there.
    public static func writeMarker(on volume: URL) {
        let url = volume.appending(path: marker, directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    /// Whether Spotlight is indexing `volume` right now, per `mdutil -s`; nil if it can't tell.
    public static func isIndexing(_ volume: URL) -> Bool? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/mdutil")
        process.arguments = ["-s", volume.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
        if output.contains("indexing enabled") { return true }
        if output.contains("disabled") { return false }
        return nil
    }
}

public enum RemountError: Error, LocalizedError {
    case noDisk
    /// macOS refused, usually because something has a file on the card open.
    case refused(operation: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .noDisk: "Couldn't find the disk for this card"
        case .refused(let operation, let reason): "Couldn't \(operation) the card: \(reason)"
        }
    }
}

/// Unmounts and remounts a volume without ejecting it, so macOS re-reads settings such as the
/// Spotlight marker. The card stays plugged in.
public enum VolumeRemount {
    /// Returns where the volume is mounted afterwards (normally the same path).
    public static func remount(_ volume: URL) async throws -> URL {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw RemountError.noDisk }
        let queue = DispatchQueue(label: "cc.jofam.daptastic.remount")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL) else {
            throw RemountError.noDisk
        }

        try await perform("unmount") { callback, context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), callback, context)
        }
        try await perform("remount") { callback, context in
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, context)
        }

        let description = DADiskCopyDescription(disk) as? [CFString: Any]
        return description?[kDADiskDescriptionVolumePathKey] as? URL ?? volume
    }

    private final class Completion {
        let operation: String
        let continuation: CheckedContinuation<Void, Error>
        init(_ operation: String, _ continuation: CheckedContinuation<Void, Error>) {
            self.operation = operation
            self.continuation = continuation
        }
    }

    /// Bridges DiskArbitration's C callback (no captures allowed) to async via its context.
    private static func perform(
        _ operation: String,
        _ start: (DADiskMountCallback, UnsafeMutableRawPointer) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Unmanaged.passRetained(Completion(operation, continuation)).toOpaque()
            start({ _, dissenter, context in
                let completion = Unmanaged<Completion>.fromOpaque(context!).takeRetainedValue()
                if let dissenter {
                    let reason = DADissenterGetStatusString(dissenter) as String?
                        ?? String(cString: strerror(Int32(DADissenterGetStatus(dissenter) & 0xFF)))
                    completion.continuation.resume(throwing: RemountError.refused(operation: completion.operation, reason: reason))
                } else {
                    completion.continuation.resume()
                }
            }, context)
        }
    }
}
