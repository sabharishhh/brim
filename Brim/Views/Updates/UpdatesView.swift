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
            if model.available.contains(where: \.canInstall) {
                Button("Update All") { Task { await model.installAll(service: service) } }
                    .disabled(!model.installing.isEmpty)
            }
            Button(model.hasChecked ? "Check Again" : "Check for Updates") {
                Task { await model.check(service: service) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isChecking || model.isLoading)
        }
        .padding()
    }

    private var summary: String { model.headline }

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
                if let problem = model.problem {
                    Text(problem).font(.caption).foregroundColor(.orange)
                }
                availableSection
                orphanedCaskSection
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

    /// What can actually be updated, and the button that does it.
    @ViewBuilder
    private var availableSection: some View {
        if !model.available.isEmpty {
            Section {
                ForEach(model.available) { update in
                    HStack(spacing: 8) {
                        Text(update.name).fontWeight(.medium)
                        Text("\(update.installed ?? "?") → \(update.latest)")
                            .font(.caption).foregroundColor(.secondary).monospacedDigit()
                        Spacer()
                        if model.installing.contains(update.bundleID) {
                            ProgressView().controlSize(.small)
                        } else if update.canInstall {
                            Button("Update") {
                                Task { await model.install(update, service: service) }
                            }
                        } else if case .appStore = update.source {
                            Button("Open App Store") {
                                if let url = URL(string: "macappstore://showUpdatesPage") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        } else {
                            Button("Open") {
                                NSWorkspace.shared.open(
                                    URL(fileURLWithPath: "/Applications/\(update.name).app")
                                )
                            }
                            .help("This application installs its own updates. Opening it "
                                  + "lets it do so.")
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Available (\(model.available.count))").font(.headline)
                    .padding(.vertical, 4)
            }
        }
    }

    /// Homebrew records for software that is not on the disk.
    @ViewBuilder
    private var orphanedCaskSection: some View {
        if !model.orphanedCasks.isEmpty {
            Section {
                ForEach(model.orphanedCasks) { cask in
                    HStack(spacing: 8) {
                        Text(cask.name).fontWeight(.medium)
                        if let version = cask.installedVersion {
                            Text(version).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Remove Record") {
                            Task { await model.forget(cask, service: service) }
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Homebrew records with nothing installed "
                         + "(\(model.orphanedCasks.count))").font(.headline)
                    Text("The application was removed but Homebrew still lists it, so it keeps "
                         + "offering to update software that is not here.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The finding. Software with no route to a new version sits at
    /// whatever version it is at until somebody notices, which for
    /// anything that opens a file off the internet is the whole problem.
    @ViewBuilder
    private var strandedSection: some View {
        if !model.stranded.isEmpty {
            Section {
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

                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    // The finding is about the applications, not about Brim.
                    // "Cannot be checked" made a fact worth knowing, that
                    // this software will never update itself, read as a hole
                    // in the product.
                    Text("You update these yourself (\(model.stranded.count))").font(.headline)
                    Text("No App Store receipt, no Sparkle feed, no Homebrew cask and no "
                         + "updater running alongside them. Nothing will tell you when a new "
                         + "version comes out, so check the developer's site now and again.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
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
                    Text("Installed by Homebrew (\(model.homebrewManaged.count))")
                        .font(.headline)
                    Text("Updated with brew upgrade. Remove them with brew uninstall, or "
                         + "Homebrew will still list them as installed.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// A section with nothing in it is not rendered. A heading, a
    /// paragraph explaining what it would have contained and a row saying
    /// "None" is three lines about nothing.
    @ViewBuilder
    private func section(
        _ title: String, _ caption: String,
        _ agents: [UpdaterAgent], _ emptyNote: String
    ) -> some View {
        if !agents.isEmpty {
            Section {
                ForEach(agents) { agent in row(agent) }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(title) (\(agents.count))").font(.headline)
                    Text(caption).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
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
