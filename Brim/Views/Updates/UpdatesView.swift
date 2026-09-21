import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// How each application gets its next version, and what is still checking
/// for software that has gone.
///
/// This used to list background updaters and nothing else, which answers
/// "who is checking in the background" and says nothing about the
/// application in front of you. The more useful question, and T-5.8's, is
/// whether each application has any route to a new version at all.
///
/// Everything here is read from the disk. A Sparkle feed is a string in an
/// Info.plist, an App Store purchase is a receipt inside the bundle, a
/// Homebrew cask is a directory in the Caskroom. No request is made, so
/// this renders identically with the network off and does not have to say
/// it is offline, because being offline changes nothing.
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
        if model.isLoading { return "Reading what each application updates from…" }
        return model.report.summary
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.report.coverage.isEmpty {
            ProgressView("Looking…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.report.coverage.isEmpty && model.agents.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundColor(.green)
                Text("Nothing to report").font(.headline)
                Text("No applications and no background updaters were found.")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                strandedSection
                homebrewSection
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

    /// The finding. Software with no route to a new version sits at
    /// whatever version it is at until somebody notices, which for
    /// anything that opens a file off the internet is the whole problem.
    @ViewBuilder
    private var strandedSection: some View {
        Section {
            if model.stranded.isEmpty {
                Text("Everything here has a way to get its next version.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(model.stranded) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.application.name).fontWeight(.medium)
                            if let version = entry.application.version {
                                Text(version).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(ByteText.short(entry.application.bundleSizeBytes))
                                .font(.caption).foregroundColor(.secondary).monospacedDigit()
                        }
                        Text(entry.sentence).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                Text("No way to update itself (\(model.stranded.count))").font(.headline)
                Text("Nothing checks these for a new version: no App Store receipt, no "
                     + "Sparkle feed, no Homebrew cask, no updater. They stay where they are "
                     + "until you replace them by hand.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    /// Software Homebrew installed, which Homebrew should remove.
    @ViewBuilder
    private var homebrewSection: some View {
        if !model.homebrewManaged.isEmpty {
            Section {
                ForEach(model.homebrewManaged) { entry in
                    HStack(spacing: 6) {
                        Text(entry.application.name).fontWeight(.medium)
                        Text(entry.homebrewCask ?? "")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(entry.application.name), installed by Homebrew as "
                        + "\(entry.homebrewCask ?? "a cask")"
                    )
                }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Homebrew looks after these (\(model.homebrewManaged.count))")
                        .font(.headline)
                    Text("brew upgrade updates them. When you remove one, let Homebrew do it: "
                         + "deleting the files underneath leaves Homebrew believing it is "
                         + "still installed.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
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
