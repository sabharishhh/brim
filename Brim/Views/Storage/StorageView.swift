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
                     : "Free space, space macOS is holding, and what can be cleared.")
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
                   "Files, applications and everything else stored.", .accentColor)
            figure("Free right now", volume.freeRightNow,
                   "Available for new files.", .green)
            figure("Held by macOS", volume.reclaimableByTheSystem,
                   "Caches macOS gives back when something needs the room. Deleting files "
                   + "does not add to it.",
                   .orange)

            Divider()
            Text("Finder reports " + ByteText.short(volume.freeAsFinderReportsIt)
                 + " free, because it counts the last two together.")
                .font(.caption).foregroundColor(.secondary)

            if !volume.snapshots.isEmpty { snapshotNote(volume) }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Snapshots are reported by count and purgeability, never by size.
    /// macOS exposes no supported way to ask how many bytes one is holding,
    /// and a figure invented here would be the exact dishonesty this
    /// section exists to avoid.
    private func snapshotNote(_ volume: VolumeAccount) -> some View {
        let pinning = volume.pinningSnapshots.count
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(volume.snapshots.count) local "
                     + (volume.snapshots.count == 1 ? "snapshot" : "snapshots"))
                    .fontWeight(.medium)
                Text(pinning == 0
                     ? "macOS will discard these when it needs the room."
                     : "\(pinning) will not be discarded automatically. Until they go, "
                       + "deleting a large file may free nothing.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
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
        // One element per figure, with the number as the value. Three
        // separate pieces of text meant a reader got a heading, then a
        // number, then a sentence, and had to hold them together itself.
        // These three figures mean different things and the whole point
        // of the section is not to let them blur.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(SpokenText.sentences([title, detail]))
        .accessibilityValue(ByteText.short(bytes))
    }

    private var reclaimable: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray.full").foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can be cleared").fontWeight(.medium)
                if model.isLoading {
                    Text("Still counting…").font(.callout).foregroundColor(.secondary)
                } else if model.brimCanClear == 0 {
                    Text("Nothing found.")
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(ByteText.short(model.brimCanClear) + " across "
                         + "\(model.brimCanClearCount) items, listed in Leftovers.")
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
