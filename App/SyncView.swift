import DaptasticCore
import SwiftUI

struct SyncView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            Text(model.targetVolume.map { "\($0.name) is connected." } ?? "The card isn't connected.")
            buttons { Button("Sync Now", action: model.startSync).disabled(!model.canSync) }

        case .cardConnected(let volume):
            Label("“\(volume.name)” connected", systemImage: "externaldrive.fill.badge.checkmark")
                .font(.headline)
            Text("Sync your starred music and playlists now?")
            buttons {
                Button("Not Now", action: close)
                Button("Sync Now", action: model.startSync)
                    .keyboardShortcut(.defaultAction)
            }

        case .preparing:
            ProgressView("Checking your library and the card…")
            buttons { Button("Cancel", action: model.cancel) }

        case .confirmDeletes(let job):
            confirmDeletes(job)

        case .wontFit(let shortfall, let albums):
            Label("Not enough space on the card", systemImage: "externaldrive.badge.exclamationmark")
                .font(.headline)
            Text("It needs \(shortfall.formattedBytes) more. Un-star some albums in Navidrome, then sync again. Largest albums:")
            albumList(albums)
            buttons { Button("Close", action: close) }

        case .syncing(let progress):
            syncing(progress)

        case .finished(let outcome):
            Label("Sync complete", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(summary(outcome))
            buttons {
                Button("Close", action: close)
                Button("Eject Card") {
                    model.eject()
                    close()
                }
                .disabled(model.targetVolume == nil)
            }

        case .failed(let message):
            Label("Sync failed", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message).textSelection(.enabled)
            buttons {
                Button("Settings…") { openWindow.bringToFront(WindowID.settings) }
                Button("Try Again", action: model.startSync).disabled(!model.canSync)
            }

        case .cancelled:
            Label("Sync cancelled", systemImage: "stop.circle")
                .font(.headline)
            Text("Finished files were kept. Sync again to pick up where it left off.")
            buttons {
                Button("Close", action: close)
                Button("Resume", action: model.startSync).disabled(!model.canSync)
            }
        }
    }

    private func confirmDeletes(_ job: SyncJob) -> some View {
        let deletes = job.plan.deletes
        return Group {
            Label("Delete \(deletes.count) files from the card?", systemImage: "trash")
                .font(.headline)
            Text(job.desired.tracks.isEmpty
                 ? "Nothing is starred on the server any more. If that's a mistake, cancel and check Navidrome."
                 : "The starred set shrank by more than 30% since the last sync. These files are no longer starred:")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(deletes.prefix(200), id: \.relativePath) { Text($0.relativePath) }
                    if deletes.count > 200 { Text("…and \(deletes.count - 200) more").foregroundStyle(.secondary) }
                }
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            buttons {
                Button("Cancel", action: model.cancel)
                Button("Sync Without Deleting") { model.resolveDeletes(job, delete: false) }
                Button("Delete \(deletes.count) Files", role: .destructive) { model.resolveDeletes(job, delete: true) }
            }
        }
    }

    @ViewBuilder private func syncing(_ progress: TransferProgress?) -> some View {
        if let progress {
            Text((progress.currentPath as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: Double(progress.overallBytes), total: Double(max(progress.overallTotal, 1)))
            Text("File \(progress.fileIndex + 1) of \(progress.fileCount) · \(progress.overallBytes.formattedBytes) of \(progress.overallTotal.formattedBytes)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            ProgressView("Starting…")
        }
        buttons { Button("Cancel", action: model.cancel) }
    }

    private func albumList(_ albums: [SyncPlan.AlbumSize]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(albums, id: \.name) { album in
                GridRow {
                    Text(album.bytes.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                    Text(album.name).lineLimit(1)
                }
            }
        }
        .font(.callout)
    }

    private func summary(_ outcome: SyncJob.Outcome) -> String {
        let s = outcome.sync, p = outcome.playlists
        var lines = ["\(s.transferred) files copied, \(s.deleted) deleted."]
        if s.withheldDeletes > 0 { lines.append("\(s.withheldDeletes) un-starred files were kept on the card.") }
        lines.append("Playlists: \(p.written.count) updated, \(p.unchanged.count) unchanged, \(p.removed.count) removed.")
        if !p.skipped.isEmpty {
            lines.append("Skipped \(p.skipped.joined(separator: ", ")): a playlist with that name already exists on the card.")
        }
        return lines.joined(separator: "\n")
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
    }

    private func close() {
        model.dismiss()
        dismissWindow(id: WindowID.sync)
    }
}
