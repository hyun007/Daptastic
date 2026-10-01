import DaptasticCore
import Foundation

let usage = """
    usage: daptastic [options] <command>

    commands:
      login         prompt for the password, verify it with ping, store it in the Keychain
      ping          check the stored credentials
      desired       dump the desired set as JSON to stdout, with a summary on stderr
      plan VOLUME   diff against the card mounted at VOLUME and pre-flight; changes nothing
      sync VOLUME   plan, then transfer and delete; Ctrl-C stops cleanly
      spotlight VOLUME  stop Spotlight indexing the card: write the marker, then remount it
      download-test [N]  download the first N tracks of the desired set, discarding them, and
                    report server response time and throughput (isolates the network side)

    options (default to the app's saved settings):
      --server URL  --user NAME  --library-root PATH  --music-folder PATH
      --confirm-deletes   allow deletes that the shrink guard would withhold
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

var settings = SyncSettings.load()
var confirmDeletes = false
var positional: [String] = []

var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--server":
        guard let value = args.popFirst(), let url = SyncSettings.serverURL(from: value) else { fail("--server needs an http(s) URL") }
        settings.serverURL = url
    case "--user":
        guard let value = args.popFirst() else { fail("--user needs a name") }
        settings.username = value
    case "--library-root":
        guard let value = args.popFirst() else { fail("--library-root needs a path") }
        settings.libraryRoot = value
    case "--music-folder":
        guard let value = args.popFirst() else { fail("--music-folder needs a path") }
        settings.musicFolder = value
    case "--confirm-deletes":
        confirmDeletes = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        positional.append(arg)
    }
}
let command = positional.first

@MainActor func client(password: String? = nil) throws -> SubsonicClient {
    guard let url = settings.serverURL, !settings.username.isEmpty else {
        fail("no server or username set; set them in the app's Settings or pass --server and --user")
    }
    guard let password = try password ?? Keychain.password(account: settings.username) else {
        fail("no password in the Keychain for \(settings.username); run `daptastic login` first")
    }
    return SubsonicClient(credentials: .init(serverURL: url, username: settings.username, password: password))
}

@MainActor func readPassword() -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let result = readpassphrase("Navidrome password for \(settings.username): ", &buffer, buffer.count, 0) else {
        fail("could not read password")
    }
    return String(cString: result)
}

/// Checks the assumptions in CLAUDE.md against what the server actually reports.
func summarise(_ set: DesiredSet) {
    let paths = set.tracks.map(\.relativePath)
    let illegal = CharacterSet(charactersIn: ":?*<>|\"\\")
    let layout = /^[^\/]+\/\d{4} - [^\/]+\/(CD \d+\/)?[^\/]+\.[^\/.]+$/

    note("tracks:           \(set.tracks.count)")
    note("total size:       \(ByteCountFormatter.string(fromByteCount: set.totalBytes, countStyle: .file))")
    note("playlists:        \(set.playlists.map { "\($0.name) (\($0.songIDs.count))" })")
    note("starred tracks:   \(set.starredSongIDs.count)")
    note("missing size:     \(set.tracks.filter { $0.song.size == nil }.count)")
    note("non-ASCII paths:  \(paths.filter { !$0.allSatisfy(\.isASCII) }.count)")
    note("FAT-illegal:      \(paths.filter { $0.rangeOfCharacter(from: illegal) != nil }.count)")
    note("longest path:     \(paths.map(\.count).max() ?? 0)")
    note("off-layout paths: \(paths.filter { $0.wholeMatch(of: layout) == nil }.count) (expected Artist/YYYY - Album/[CD NN/]NN - Title.ext)")
    for path in paths.prefix(3) { note("  e.g. \(path)") }
}

func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// Returns whether the plan fits.
@discardableResult
func summarise(_ job: SyncJob, deletesConfirmed: Bool) -> Bool {
    let plan = job.plan
    func total(_ transfers: [SyncPlan.Transfer]) -> String { bytes(transfers.reduce(0) { $0 + $1.size }) }
    note("unchanged:        \(plan.unchangedCount)")
    note("add:              \(plan.adds.count) (\(total(plan.adds)))")
    note("update:           \(plan.updates.count) (\(total(plan.updates)))")
    note("delete:           \(plan.deletes.count) (\(bytes(plan.deletes.reduce(0) { $0 + $1.size })))")
    note("stale temps:      \(plan.staleTemporaries.count)")
    note("confirm deletes:  \(plan.requiresDeleteConfirmation ? "yes — desired set is empty or shrank >30%" : "no")")
    for file in plan.deletes.prefix(5) { note("  - \(file.relativePath)") }
    for transfer in plan.transfers.prefix(5) {
        note("  \(transfer.replacing == nil ? "+" : "~") \(transfer.track.relativePath)")
    }

    // Without confirmation, deletes are withheld, so they cannot free space.
    switch job.preflight(deletesConfirmed: deletesConfirmed) {
    case .fits(let needed, let available):
        note("pre-flight:       fits — needs \(bytes(needed)) of \(bytes(available))")
        return true
    case .shortfall(let short, let albums):
        note("pre-flight:       WILL NOT FIT — \(bytes(short)) short. Largest albums:")
        for album in albums { note("  \(bytes(album.bytes))  \(album.name)") }
        return false
    }
}

/// Collects timing for one request.
final class Timing: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var metrics: URLSessionTaskTransactionMetrics?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics.transactionMetrics.last
    }
}

/// Runs `work` so that Ctrl-C cancels it instead of killing the process mid-write.
func runCancellable(_ work: @escaping @Sendable () async throws -> Void) async throws {
    let task = Task { try await work() }
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        note("\ncancelling…")
        task.cancel()
    }
    source.resume()
    defer { source.cancel() }
    try await task.value
}

/// One status line on stderr.
let progressLine = ProgressThrottle { p in
        let percent = p.overallTotal > 0 ? Int(Double(p.overallBytes) / Double(p.overallTotal) * 100) : 100
        let name = (p.currentPath as NSString).lastPathComponent
        FileHandle.standardError.write(Data(
            "\r\u{1B}[K[\(p.fileIndex + 1)/\(p.fileCount)] \(percent)%  \(bytes(p.overallBytes))/\(bytes(p.overallTotal))  \(name.prefix(50))".utf8))
}

do {
    switch command {
    case "login":
        let password = readPassword()
        try await client(password: password).ping()
        try Keychain.setPassword(password, account: settings.username)
        note("ok: credentials verified and stored in the Keychain")
    case "ping":
        try await client().ping()
        note("ok")
    case "desired":
        let set = try await DesiredSetBuilder.build(client: try client(), libraryRoot: settings.libraryRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(set))
        print()
        summarise(set)
    case "download-test":
        let limit = positional.count > 1 ? Int(positional[1]) ?? .max : .max
        let client = try client()
        let tracks = try await DesiredSetBuilder.build(client: client, libraryRoot: settings.libraryRoot).tracks.prefix(limit)
        var bytes: Int64 = 0
        var waiting = 0.0
        let start = Date()
        for track in tracks {
            let timing = Timing()
            let (data, _) = try await URLSession.shared.data(for: client.downloadRequest(songID: track.song.id), delegate: timing)
            guard let m = timing.metrics, let sent = m.requestStartDate, let first = m.responseStartDate,
                  let end = m.responseEndDate else { continue }
            let wait = first.timeIntervalSince(sent), transfer = end.timeIntervalSince(first)
            waiting += wait
            bytes += Int64(data.count)
            note(String(format: "%6.1f MB  first byte %5.0f ms  then %6.1f MB/s  %@", Double(data.count) / 1e6, wait * 1000,
                        Double(data.count) / max(transfer, 0.001) / 1e6, (track.relativePath as NSString).lastPathComponent))
        }
        let elapsed = Date().timeIntervalSince(start)
        note(String(format: "total %.0f MB in %.1f s = %.1f MB/s; %.1f s of that waiting for first bytes",
                    Double(bytes) / 1e6, elapsed, Double(bytes) / elapsed / 1e6, waiting))
    case "spotlight":
        guard positional.count == 2 else { fail("spotlight needs the card's volume path") }
        let volume = URL(filePath: positional[1], directoryHint: .isDirectory)
        note("indexing before: \(Spotlight.isIndexing(volume).map { $0 ? "on" : "off" } ?? "unknown")")
        Spotlight.writeMarker(on: volume)
        let mounted = try await VolumeRemount.remount(volume)
        note("remounted at \(mounted.path)")
        note("indexing after:  \(Spotlight.isIndexing(mounted).map { $0 ? "on" : "off" } ?? "unknown")")
    case "plan", "sync":
        guard positional.count == 2 else { fail("\(command!) needs the card's volume path") }
        let volume = URL(filePath: positional[1], directoryHint: .isDirectory)
        let job = try await SyncJob.prepare(client: try client(), settings: settings, volume: volume)
        let fits = summarise(job, deletesConfirmed: confirmDeletes)
        guard command == "sync" else { break }
        guard fits else { fail("not syncing: it will not fit") }
        if job.plan.requiresDeleteConfirmation && !confirmDeletes {
            note("withholding \(job.plan.deletes.count) deletes; rerun with --confirm-deletes to allow them")
        }
        let confirmDeletes = confirmDeletes
        try await runCancellable {
            let outcome = try await job.run(deletesConfirmed: confirmDeletes, progress: progressLine.report)
            let result = outcome.sync, playlists = outcome.playlists
            note("\ndone: \(result.transferred) transferred, \(result.deleted) deleted, \(result.withheldDeletes) withheld")
            note("playlists: \(playlists.written.count) written, \(playlists.unchanged.count) unchanged, \(playlists.removed.count) removed")
            for name in playlists.skipped { note("  skipped \(name): a playlist_data file with that name is not ours") }
        }
    default:
        print(usage)
        exit(command == nil ? 0 : 1)
    }
} catch is CancellationError {
    fail("cancelled; finished files are kept and recorded — rerun sync to resume")
} catch {
    fail(error.localizedDescription)
}
