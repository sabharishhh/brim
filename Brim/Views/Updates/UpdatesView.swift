import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// What keeps checking for new versions, and whether the software it
/// checks for is even here.
///
/// Worth its own section because updaters behave differently from other
/// background jobs. Most installers add one and no uninstaller removes it,
/// so a Mac that has had Chrome, Dropbox or Adobe on it at any point tends
/// to go on checking for all three. They also wake the machine on a timer,
/// which costs battery for software you may no longer have.
struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel
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
                Text("Updates").font(.title2).fontWeight(.bold)
                Text(summary).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Rescan") { Task { await model.load(service: service) } }
                .disabled(model.isLoading)
        }
        .padding()
    }

    private var summary: String {
        if model.isLoading { return "Looking for updaters…" }
        if model.agents.isEmpty { return "Nothing on this Mac is checking for updates in the background." }
        if model.orphaned.isEmpty {
            return "\(model.working.count) checking for software you have. None left stranded."
        }
        return "\(model.orphaned.count) checking for software that has gone, "
             + "\(model.working.count) for software you still have"
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.agents.isEmpty {
            ProgressView("Looking…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.agents.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundColor(.green)
                Text("Nothing is checking for updates").font(.headline)
                Text("No background updater is registered on this Mac.")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                section(
                    "Checking for software that has gone",
                    "The program each of these launches is not on this Mac any more. They "
                    + "wake up on a schedule and find nothing to do.",
                    model.orphaned,
                    "None. Every updater here belongs to software you still have."
                )
                section(
                    "Checking for software you have",
                    "Doing the job they were installed for. Here so you can see what runs "
                    + "on a timer.",
                    model.working,
                    "None."
                )
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func section(
        _ title: String, _ caption: String,
        _ agents: [UpdaterAgent], _ emptyNote: String
    ) -> some View {
        Section {
            if agents.isEmpty {
                Text(emptyNote).font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(agents) { agent in row(agent) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(title) (\(agents.count))").font(.headline)
                Text(caption).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ agent: UpdaterAgent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(agent.vendor).fontWeight(.medium)
                Text(agent.registration.identifier)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if !agent.productIsInstalled {
                    Label("Nothing to update", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundColor(.orange)
                }
            }
            if let program = agent.registration.programPath {
                Text(program)
                    .font(.caption2).foregroundColor(.secondary)
                    .truncationMode(.middle).lineLimit(1).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        // Composed, because the four pieces arrived as four unrelated
        // fragments. The location matters more here than anywhere: Google
        // installs the same updater twice, so without it two rows read
        // identically and a reader cannot tell which is which.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(SpokenText.sentences([
            agent.vendor,
            agent.registration.identifier,
            agent.productIsInstalled ? "" : "nothing to update, the program it checks is gone"
        ]))
        .accessibilityValue(agent.registration.spokenLocation ?? "")
    }
}
