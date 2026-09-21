import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// Build caches, which are usually the largest reclaimable thing on a
/// developer's Mac and the least visible.
///
/// Grouped by what clearing each one costs rather than by size, because
/// that is the question. Two directories can look alike and mean very
/// different things: clearing Xcode's derived data costs one slow build,
/// while clearing the simulator device set loses every simulator you have
/// set up. Brim lists only caches it has been taught about and leaves
/// anything it does not recognise alone.
struct DeveloperView: View {
    @ObservedObject var model: DeveloperModel
    @SwiftUI.Environment(\.brimService) private var service

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await model.loadIfNeeded(service: service) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer").font(.title2).fontWeight(.bold)
                Text(summary).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Rescan") { Task { await model.load(service: service) } }
                .disabled(model.isScanning)
        }
        .padding()
    }

    private var summary: String {
        if model.isScanning { return "Measuring what the build tools have kept…" }
        if model.caches.isEmpty { return "No build caches Brim recognises on this Mac." }
        return "\(ByteText.short(model.totalBytes)) across \(model.caches.count) caches, "
             + "of which \(ByteText.short(model.recoverableBytes)) comes back on its own"
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.caches.isEmpty {
            ProgressView("Measuring…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.caches.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "hammer").font(.largeTitle).foregroundColor(.secondary)
                Text("Nothing to show").font(.headline)
                Text("Brim did not find any of the build caches it knows about. It only lists "
                     + "ones it has been taught, rather than guessing from folder names.")
                    .foregroundColor(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                group(.rebuilt, "Rebuilt when you next build",
                      "Clearing these costs one slow build and nothing else.")
                group(.refetched, "Downloaded again when needed",
                      "Clearing these costs time and bandwidth the next time a build "
                      + "reaches for them.")
                group(.configured, "Set up by hand",
                      "Not caches. Clearing these loses work or configuration, so Brim shows "
                      + "them for the space they take and leaves them to you.")
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func group(_ cost: DeveloperCache.Cost, _ title: String, _ caption: String) -> some View {
        let items = model.caches.filter { $0.cost == cost }
        if !items.isEmpty {
            Section {
                ForEach(items) { cache in row(cache) }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title).font(.headline)
                        Spacer()
                        Text(ByteText.short(items.reduce(0) { $0 + $1.sizeBytes }))
                            .font(.caption).foregroundColor(.secondary).monospacedDigit()
                    }
                    Text(caption).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ cache: DeveloperCache) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(cache.tool).fontWeight(.medium)
                Text(cache.name).foregroundColor(.secondary)
                Spacer()
                Text(ByteText.short(cache.sizeBytes))
                    .monospacedDigit().foregroundColor(cache.cost == .configured ? .orange : .primary)
            }
            Text(cache.explanation)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(cache.url.path)
                .font(.caption2).foregroundColor(.secondary)
                .truncationMode(.middle).lineLimit(1).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
