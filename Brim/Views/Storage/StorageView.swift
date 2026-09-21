import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// Where the space went, told as separate numbers.
///
/// Finder shows one figure for free space and it already includes room
/// macOS is only holding on to, which is why deleting something large can
/// leave it unchanged. That single number is how cleaning utilities end up
/// claiming gigabytes nobody ever sees. Here the parts stay apart and each
/// one says what it is.
struct StorageView: View {
    @ObservedObject var model: StorageModel
    @SwiftUI.Environment(\.brimService) private var service

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let volume = model.startupVolume { breakdown(volume) }
                    reclaimable
                    if model.volumes.count > 1 { otherVolumes }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(24)
                Spacer(minLength: 0)
            }
        }
        .task { await model.loadIfNeeded(service: service) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Storage").font(.title2).fontWeight(.bold)
                Text(model.isLoading
                     ? "Reading the volumes…"
                     : "Kept as separate figures, because adding them together hides what is going on.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Rescan") { Task { await model.load(service: service) } }
                .disabled(model.isLoading)
        }
    }

    private func breakdown(_ volume: VolumeAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.name).font(.headline)
                Spacer()
                Text(ByteText.short(volume.capacity) + " in total")
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()
            }

            bar(volume)

            figure("In use", volume.used,
                   "Files, applications and everything else actually stored.", .accentColor)
            figure("Free right now", volume.freeRightNow,
                   "Genuinely empty this second. This is what a new file writes into.", .green)
            figure("Held by macOS", volume.reclaimableByTheSystem,
                   volume.localSnapshots > 0
                     ? "Caches and \(volume.localSnapshots) local Time Machine "
                       + "\(volume.localSnapshots == 1 ? "snapshot" : "snapshots"). macOS gives this "
                       + "back when something needs it, so deleting files does not add to it."
                     : "Caches macOS gives back when something needs the room. Deleting files "
                       + "does not add to it.",
                   .orange)

            Divider()
            Text("Finder would say " + ByteText.short(volume.freeAsFinderReportsIt)
                 + " free, because it counts the last two together.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func bar(_ volume: VolumeAccount) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let total = max(1, Double(volume.capacity))
            HStack(spacing: 1) {
                Rectangle().fill(Color.accentColor)
                    .frame(width: width * Double(volume.used) / total)
                Rectangle().fill(Color.orange)
                    .frame(width: width * Double(volume.reclaimableByTheSystem) / total)
                Rectangle().fill(Color.green.opacity(0.35))
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func figure(_ title: String, _ bytes: Int64, _ detail: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(tint).frame(width: 9, height: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(ByteText.short(bytes)).monospacedDigit()
                }
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reclaimable: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray.full").foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("What Brim could clear").fontWeight(.medium)
                if model.isLoading {
                    Text("Still counting…").font(.callout).foregroundColor(.secondary)
                } else if model.brimCanClear == 0 {
                    Text("Nothing. Brim has not found anything on this Mac it can attribute "
                         + "to software you no longer have.")
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(ByteText.short(model.brimCanClear) + " across "
                         + "\(model.brimCanClearCount) items, from the same scan the Leftovers "
                         + "section shows. Counted, not estimated.")
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private var otherVolumes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other volumes").font(.headline)
            ForEach(model.volumes.filter { $0.id != model.startupVolume?.id }) { volume in
                HStack {
                    Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                        .foregroundColor(.secondary)
                    Text(volume.name)
                    Spacer()
                    Text(ByteText.short(volume.freeRightNow) + " free of "
                         + ByteText.short(volume.capacity))
                        .font(.caption).foregroundColor(.secondary).monospacedDigit()
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
