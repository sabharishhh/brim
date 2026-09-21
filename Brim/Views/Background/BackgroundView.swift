import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// What macOS runs on your behalf, and what it is still being told to run
/// for software that is no longer here.
///
/// This is the surface the whole product grew out of. Remove an app without
/// deregistering it and System Settings goes on listing its background item,
/// often as a bare identifier with no name, and no amount of deleting files
/// clears it.
///
/// Two lists, because they call for different things. A job pointing at a
/// program that has gone is a loose end. A job pointing at something real is
/// simply what your Mac is doing, and is here so you can see it.
struct BackgroundView: View {
    @ObservedObject var model: BackgroundModel
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background").font(.title2).fontWeight(.bold)
                    Text(summary).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Include macOS", isOn: $model.showsSystemOwned)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("Rescan") { Task { await model.load(service: service) } }
                    .disabled(model.isLoading)
            }
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var summary: String {
        if model.isLoading { return "Reading what macOS has been told to run…" }
        let stale = model.stale.count
        let live = model.live.count
        if stale == 0 { return "\(live) running for software you still have. Nothing left over." }
        return "\(stale) left over by software that has gone, \(live) belonging to software you still have"
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.report.registrations.isEmpty {
            ProgressView("Reading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.hasLoadedBackgroundItems { backgroundItemsPrompt }
                section(
                    "Left behind",
                    "These point at a program that is not on this Mac any more. Each one either "
                    + "fails quietly every time you log in, or keeps running something you "
                    + "thought was gone.",
                    model.stale,
                    "Nothing left over. Every background job here points at software you "
                    + "still have."
                )
                section(
                    "Still in use",
                    "Software you have, running in the background. Here so you can see it, "
                    + "not because anything is wrong.",
                    model.live,
                    model.searchText.isEmpty ? "Nothing runs in the background on this Mac."
                                             : "Nothing matches."
                )
            }
            .listStyle(.inset)
        }
    }

    /// The one place in the app that offers to raise an administrator
    /// prompt, and it says so before you press it.
    private var backgroundItemsPrompt: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.circle").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Login items are not in this list yet").fontWeight(.medium)
                    Text("macOS keeps those in a separate database, and it wants an "
                         + "administrator password before it will show them. Brim will not "
                         + "ask for that on its own.")
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(model.gaps, id: \.kind) { gap in
                        if let limitation = gap.limitation {
                            Text(limitation).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Show them") { Task { await model.includeBackgroundItems() } }
                    .disabled(model.isLoading)
            }
            .padding(10)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func section(
        _ title: String, _ caption: String,
        _ items: [Registration], _ emptyNote: String
    ) -> some View {
        Section {
            if items.isEmpty {
                Text(emptyNote).font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(items) { item in RegistrationRow(registration: item) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(title) (\(items.count))").font(.headline)
                    Spacer()
                    if title == "Still in use", model.hiddenSystemCount > 0 {
                        Text("\(model.hiddenSystemCount) from macOS hidden")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Text(caption).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct RegistrationRow: View {
    let registration: Registration

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(registration.label).fontWeight(.medium)
                Text(registration.kind.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                if registration.isSystemOwned {
                    Text("macOS").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if registration.isActionableStale {
                    Label("Points at nothing", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundColor(.orange)
                }
            }
            Text(registration.evidence)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let program = registration.programPath {
                Text(program)
                    .font(.caption2).foregroundColor(.secondary)
                    .truncationMode(.middle).lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
