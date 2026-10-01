import DaptasticCore
import SwiftUI

/// Whether Spotlight is indexing the card, with a one-click fix: the app has already written
/// the no-index marker, and remounting the card makes Spotlight honour it.
struct SpotlightStatusView: View {
    let volume: MountedVolume

    @Environment(AppModel.self) private var model
    @State private var state = State.checking

    enum State: Equatable {
        case checking, off, indexing, remounting, unknown
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Spotlight…").foregroundStyle(.secondary)
                }
            case .off:
                label("checkmark.circle.fill", .green, "Spotlight will skip this card.")
            case .unknown:
                label("info.circle", .secondary, "Daptastic has asked Spotlight to skip this card.")
            case .indexing, .remounting, .failed:
                VStack(alignment: .leading, spacing: 8) {
                    label("exclamationmark.triangle.fill", .orange,
                          "Spotlight is indexing this card. It reads every file back while Daptastic writes, which can make syncing about 3× slower.")
                    Text("Daptastic has told Spotlight to skip the card. That takes effect once the card is remounted — it stays plugged in, and it takes a second or two.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Remount Card", action: remount)
                            .disabled(state == .remounting || model.isBusy)
                        if state == .remounting { ProgressView().controlSize(.small) }
                    }
                    if case .failed(let message) = state {
                        Text("\(message). Close any Finder windows or apps using the card, then try again.")
                            .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task(id: volume.id) { await check() }
    }

    private func check() async {
        state = .checking
        switch await model.isSpotlightIndexing(volume) {
        case true?: state = .indexing
        case false?: state = .off
        case nil: state = .unknown
        }
    }

    private func remount() {
        state = .remounting
        Task {
            do {
                try await model.stopSpotlight(on: volume)
                await check()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func label(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
}
