import Foundation

public enum TransferError: Error, LocalizedError {
    case diskFull(path: String)
    case sizeMismatch(path: String, expected: Int64, received: Int64)
    case httpStatus(path: String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .diskFull(let path): "The card filled up while writing \(path)"
        case .sizeMismatch(let path, let expected, let received):
            "\(path): expected \(expected) bytes, received \(received)"
        case .httpStatus(let path, let code): "\(path): HTTP \(code) from server"
        }
    }
}

public struct TransferProgress: Sendable {
    public let fileIndex: Int
    public let fileCount: Int
    public let currentPath: String
    public let fileBytes: Int64
    public let fileTotal: Int64
    public let overallBytes: Int64
    public let overallTotal: Int64
}

public struct SyncResult: Sendable {
    public let transferred: Int
    public let transferredBytes: Int64
    public let deleted: Int
    /// Deletes that were due but withheld pending confirmation.
    public let withheldDeletes: Int
}

public struct TransferEngine: Sendable {
    let client: SubsonicClient
    let musicRoot: URL
    let session: URLSession
    /// Manifest writes go over USB; batch them. An interrupted sync can leave at most this
    /// many unrecorded files, and they are re-adopted by the next sync if still desired.
    let manifestSaveInterval = 20

    public init(client: SubsonicClient, musicRoot: URL, session: URLSession = .shared) {
        self.client = client
        self.musicRoot = musicRoot
        self.session = session
    }

    /// Runs `plan` in the order its pre-flight assumes: stale temporaries, then deletes (if
    /// allowed), then transfers. Deletes that need confirmation are skipped unless
    /// `deletesConfirmed`. Cancel the calling task to stop; the file in flight is discarded.
    public func execute(
        plan: SyncPlan,
        desired: DesiredSet,
        deletesConfirmed: Bool = false,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> SyncResult {
        var manifest = try SyncManifest.load(musicRoot: musicRoot)
        let fm = FileManager.default

        for file in plan.staleTemporaries {
            try? fm.removeItem(at: url(for: file.relativePath))
        }

        let applyDeletes = !plan.requiresDeleteConfirmation || deletesConfirmed
        if applyDeletes {
            for file in plan.deletes { try removeFile(file.relativePath) }
            let deleted = Set(plan.deletes.map { SyncPlanner.key($0.relativePath) })
            manifest.files = manifest.files.filter { !deleted.contains(SyncPlanner.key($0.key)) }
            try manifest.save(musicRoot: musicRoot)
        }

        let overallTotal = plan.transfers.reduce(0) { $0 + $1.size }
        var overallDone: Int64 = 0
        var sinceSave = 0
        defer { try? manifest.save(musicRoot: musicRoot) }

        for (index, transfer) in plan.transfers.enumerated() {
            try Task.checkCancellation()
            let path = transfer.track.relativePath
            let done = overallDone
            try await download(transfer) { bytes in
                progress(TransferProgress(
                    fileIndex: index, fileCount: plan.transfers.count, currentPath: path,
                    fileBytes: bytes, fileTotal: transfer.size,
                    overallBytes: done + bytes, overallTotal: overallTotal))
            }
            // The planner may have matched a differently-spelt name; drop that entry.
            if let replaced = transfer.replacing, replaced.relativePath != path {
                manifest.files[replaced.relativePath] = nil
            }
            manifest.files[path] = transfer.size
            overallDone += transfer.size
            sinceSave += 1
            if sinceSave >= manifestSaveInterval {
                try manifest.save(musicRoot: musicRoot)
                sinceSave = 0
            }
        }

        // Everything desired is now on the card; adopt files that were already there.
        let recorded = Set(manifest.files.keys.map(SyncPlanner.key))
        for track in desired.tracks where !recorded.contains(SyncPlanner.key(track.relativePath)) {
            manifest.files[track.relativePath] = track.song.size
        }
        // Withheld deletes leave the baseline alone; otherwise the next sync would see no
        // shrink and delete without asking.
        if applyDeletes { manifest.lastSyncTrackCount = desired.tracks.count }
        manifest.lastSyncDate = Date()
        try manifest.save(musicRoot: musicRoot)

        return SyncResult(
            transferred: plan.transfers.count,
            transferredBytes: overallTotal,
            deleted: applyDeletes ? plan.deletes.count : 0,
            withheldDeletes: applyDeletes ? 0 : plan.deletes.count)
    }

    // MARK: Files

    func url(for relativePath: String) -> URL {
        musicRoot.appending(path: relativePath, directoryHint: .notDirectory)
    }

    /// Removes a file, then any directories left empty up to the music root.
    func removeFile(_ relativePath: String) throws {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: url(for: relativePath))
        } catch CocoaError.fileNoSuchFile {}

        var dir = url(for: relativePath).deletingLastPathComponent()
        while dir.standardizedFileURL.path != musicRoot.standardizedFileURL.path {
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            // Finder droppings don't count as content.
            guard contents.allSatisfy({ $0 == ".DS_Store" || $0.hasPrefix("._") }) else { break }
            try fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Streams to `<dest>.daptastic-partial`, checks the byte count, then renames over `dest`.
    func download(_ transfer: SyncPlan.Transfer, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let path = transfer.track.relativePath
        let destination = url(for: path)
        let temporary = url(for: path + DeviceScanner.temporarySuffix)
        let fm = FileManager.default

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // FileHandle writes carry no extended attributes, so macOS creates no ._ files.
        guard fm.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        let handle = try FileHandle(forWritingTo: temporary)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? fm.removeItem(at: temporary) }
        }

        let received: Int64
        do {
            received = try await StreamingDownload(handle: handle, path: path, progress: progress)
                .run(request: client.downloadRequest(songID: transfer.track.song.id), session: session)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
        guard received == transfer.size else {
            throw TransferError.sizeMismatch(path: path, expected: transfer.size, received: received)
        }
        try handle.synchronize()
        try handle.close()

        // rename(2) replaces an existing destination in one step.
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // The planner may have matched an existing file under a different case/normalisation.
        if let replaced = transfer.replacing, SyncPlanner.key(replaced.relativePath) == SyncPlanner.key(path),
           replaced.relativePath != path, fm.fileExists(atPath: url(for: replaced.relativePath).path),
           !isSameFile(url(for: replaced.relativePath), destination) {
            try? fm.removeItem(at: url(for: replaced.relativePath))
        }
        succeeded = true
    }

    private func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let ids = [a, b].map { try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject }
        return ids[0] != nil && ids[0] == ids[1]
    }
}

/// One `download` request streamed to a file handle.
/// Subsonic reports errors as HTTP 200 with an XML/JSON body, so a non-audio content type is
/// read as an error rather than written to the card.
///
/// Receiving and writing run side by side: the network hands 1 MB blocks to a writer queue and
/// only waits when that falls 8 MB behind, and the writer flushes to the card every 8 MB.
/// Otherwise macOS holds the whole download in RAM (exFAT ignores F_NOCACHE) and the card only
/// catches up at the final flush, so downloading and writing take turns: 10.7 MB/s measured,
/// exactly what a 33 MB/s download and a 16 MB/s card give one after the other.
final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let blockSize = 1 << 20
    static let maxBlocksQueued = 8
    static let flushInterval = 8 << 20

    private let handle: FileHandle
    private let path: String
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?
    private var received: Int64 = 0
    private var written: Int64 = 0
    /// Writer-queue only.
    private var unflushed = 0
    private var errorBody: Data?
    private var failure: Error?
    /// Received bytes not yet handed to the writer. Only touched from this task's delegate
    /// callbacks, which are serial.
    private var pending = Data()
    private let writer = DispatchQueue(label: "cc.jofam.daptastic.writer")
    /// Free slots in the buffer between network and card.
    private let slots = DispatchSemaphore(value: StreamingDownload.maxBlocksQueued)

    init(handle: FileHandle, path: String, progress: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.path = path
        self.progress = progress
    }

    func run(request: URLRequest, session: URLSession) async throws -> Int64 {
        let task = session.dataTask(with: request)
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else { return completionHandler(.allow) }
        if !(200..<300).contains(http.statusCode) {
            lock.withLock { failure = TransferError.httpStatus(path: path, code: http.statusCode) }
            return completionHandler(.cancel)
        }
        let type = http.mimeType ?? ""
        if type.contains("xml") || type.contains("json") {
            lock.withLock { errorBody = Data() }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isErrorBody = lock.withLock {
            if errorBody != nil { errorBody!.append(data); return true }
            received += Int64(data.count)
            return false
        }
        guard !isErrorBody else { return }
        pending.append(data)
        if pending.count >= Self.blockSize { submitPending(dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, lock.withLock({ failure == nil && errorBody == nil }) { submitPending(task) }
        // Report only once every queued block is on the card.
        writer.async { [self] in
            let (continuation, outcome): (CheckedContinuation<Int64, Error>?, Result<Int64, Error>) = lock.withLock {
                defer { self.continuation = nil }
                if let failure { return (self.continuation, .failure(failure)) }
                if let error { return (self.continuation, .failure(error)) }
                if let errorBody { return (self.continuation, .failure(Self.subsonicError(errorBody))) }
                return (self.continuation, .success(received))
            }
            continuation?.resume(with: outcome)
        }
    }

    /// Hands the buffered bytes to the writer, waiting only if it is `maxBlocksQueued` behind.
    private func submitPending(_ task: URLSessionTask) {
        guard !pending.isEmpty else { return }
        let block = pending
        pending = Data(capacity: Self.blockSize)
        slots.wait()
        writer.async { [self] in
            defer { slots.signal() }
            guard lock.withLock({ failure == nil }) else { return }
            do {
                try handle.write(contentsOf: block)
                unflushed += block.count
                if unflushed >= Self.flushInterval {
                    try handle.synchronize()
                    unflushed = 0
                }
                progress(lock.withLock { written += Int64(block.count); return written })
            } catch {
                let posix = (error as NSError).domain == NSPOSIXErrorDomain ? (error as NSError).code : nil
                let full = posix == Int(ENOSPC) || (error as? CocoaError)?.code == .fileWriteOutOfSpace
                lock.withLock { failure = full ? TransferError.diskFull(path: path) : error }
                task.cancel()
            }
        }
    }

    /// Best-effort parse of an XML or JSON Subsonic error body.
    static func subsonicError(_ body: Data) -> Error {
        do {
            _ = try SubsonicClient.decode(body)
            return SubsonicClientError.malformedResponse("download returned a non-audio success body")
        } catch let error as SubsonicError {
            return error
        } catch {}  // Not JSON; try XML.
        let text = String(decoding: body, as: UTF8.self)
        if let match = text.firstMatch(of: /code="(\d+)"[^>]*?message="([^"]*)"/), let code = Int(match.1) {
            return SubsonicError(code: code, message: String(match.2))
        }
        return SubsonicClientError.malformedResponse("download returned: \(text.prefix(200))")
    }
}
