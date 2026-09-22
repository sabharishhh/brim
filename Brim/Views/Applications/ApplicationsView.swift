import SwiftUI
import UniformTypeIdentifiers
import BrimCore
import BrimUI

/// The Applications view: every installed app, and what each one has actually
/// put on this Mac.
///
/// This is where the product's claim has to be visible. The queue removes
/// leftovers one path at a time; here the user picks an application and sees
/// the whole footprint Brim discovered from its identity alone, each group
/// labelled with the mechanism that found it.
struct ApplicationsView: View {
    @ObservedObject var model: ApplicationsModel
    /// Shared with the rest of the window, so a footprint that came up short
    /// can name the setting that would complete it instead of only saying it
    /// came up short.
    @ObservedObject var access: FullDiskAccessModel
    @SwiftUI.Environment(\.brimService) private var service
    @State private var uninstalling: InstalledApplication?
    @State private var resetting: InstalledApplication?
    /// What a drop that matched nothing should say. Doing nothing at all
    /// looks like the drop was not noticed.
    @State private var dropComplaint: String?

    var body: some View {
        HSplitView {
            applicationList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadIfNeeded(service: service) }
        .sheet(item: $resetting) { application in
            UninstallSheet(application: application, service: service, intentType: .reset) {
                Task { await model.load(service: service) }
            }
        }
        .sheet(item: $uninstalling) { application in
            UninstallSheet(application: application, service: service) {
                // Drop the row at once if the bundle really is gone —
                // re-enumerating every application takes seconds, and a row
                // that outlives "nothing remains" reads as a failure. The
                // full refresh still follows, to pick up anything else.
                model.forgetIfRemoved(application)
                AppIcon.forget(application.url)
                Task { await model.load(service: service) }
            }
        }
    }

    // MARK: - List

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Applications")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(model.isLoading
                         ? "Scanning…"
                         : "\(model.applications.count) installed")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)
            .accessibilityElement(children: .combine)

            if !model.history.changes.isEmpty {
                changesNote
            }

            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityLabel("Search applications")

            Divider()

            if let dropComplaint {
                Text(dropComplaint)
                    .font(.caption).foregroundColor(.orange)
                    .padding(.horizontal).padding(.bottom, 6)
            }

            List(selection: Binding(
                get: { model.selected?.id },
                set: { id in model.select(model.applications.first { $0.id == id }) }
            )) {
                ForEach(model.visibleApplications) { application in
                    row(application).tag(application.id)
                }
            }
            .listStyle(.inset)
            // Drop an application here, or on the Dock icon, to jump
            // straight to it.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                load(providers)
                return true
            }
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if model.selectApplication(at: url) {
                        dropComplaint = nil
                    } else {
                        dropComplaint = "\(url.lastPathComponent) is not an application in "
                                      + "this list."
                    }
                }
            }
        }
    }

    /// What is different since last time, derived by subtracting one
    /// snapshot from the one before it.
    private var changesNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.history.changes.isEmpty {
                Text("Since the last scan").font(.caption).fontWeight(.semibold)
                ForEach(Array(model.history.changes.prefix(5).enumerated()), id: \.offset) {
                    _, change in
                    Text(change.sentence)
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    private func row(_ application: InstalledApplication) -> some View {
        HStack(spacing: 8) {
            AppIconView(url: application.url, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(application.name)
                    .fontWeight(.medium)
                HStack(spacing: 5) {
                    if let version = application.version {
                        Text(version)
                    }
                    // Said out loud, because the detail pane shows a much
                    // larger number for the same application and the two
                    // look like a contradiction otherwise. This is the
                    // bundle; that is everything the app has scattered
                    // elsewhere as well.
                    Text(ByteText.short(application.bundleSizeBytes) + " app")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if application.isSystemProtected {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("Part of macOS, so it stays")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(application.name). "
            + (application.version.map { "Version \($0). " } ?? "")
            + ByteText.short(application.bundleSizeBytes)
            + (application.isSystemProtected ? ". Protected by macOS." : "")
        )
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let application = model.selected {
            VStack(spacing: 0) {
                detailHeader(application)
                Divider()
                footprintBody(application)
            }
        } else {
            VStack(spacing: 6) {
                Text("Select an application")
                    .font(.headline)
                Text("Everything it has put on this Mac, and how Brim found each one.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                AppIconView(url: application.url, size: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let bundleID = application.identity.bundleID {
                        Text(bundleID)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                if let reason = model.uninstallBlockedReason {
                    Label("Protected", systemImage: "lock")
                        .foregroundColor(.secondary)
                        .help(reason)
                } else {
                    // Reset keeps the application and its licence and
                    // clears its state. Offered beside the removal
                    // because "make it work again" is a different job
                    // from "get rid of it", and people reach for the
                    // second when they only wanted the first.
                    Button("Reset…") { resetting = application }
                        .disabled(model.isInspecting || model.footprint == nil)
                    Button("Uninstall…") {
                        uninstalling = application
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInspecting || model.footprint == nil)
                }
            }

            footprintSummary(application)
        }
        .padding()
    }

    @ViewBuilder
    private func footprintSummary(_ application: InstalledApplication) -> some View {
        if model.isInspecting {
            Label("Discovering everything this app has left behind…", systemImage: "magnifyingglass")
                .font(.subheadline)
                .foregroundColor(.secondary)
        } else if let footprint = model.footprint {
            let locations = footprint.items.count
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("**\(locations)** \(locations == 1 ? "location" : "locations")")
                    Text("·")
                    // Named, not just printed. The list beside this shows
                    // the bundle alone, so an unlabelled larger number here
                    // reads as one of the two being wrong.
                    Text(ByteText.short(footprint.totalSizeBytes) + " in total")
                        .monospacedDigit()
                    Text("·")
                    Text("\(model.footprintGroups.count) \(model.footprintGroups.count == 1 ? "mechanism" : "mechanisms")")
                }
                Text("The app itself is \(ByteText.short(application.bundleSizeBytes)). The rest is "
                     + "what it has written elsewhere on this Mac.")
                    .font(.caption)

                // A search that did not finish cannot claim to be the
                // whole footprint, so it says so and nothing is ticked
                // for the person.
                if let gap = footprint.completeness.explanation {
                    Label(gap, systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // A total short by an unknown amount has to say so. Without
                // Full Disk Access every container reads as empty, and a
                // quietly wrong number is worse than a refused one.
                //
                // What it must not do is stop there. The earlier wording ran
                // "could not be read, so this is at least that much and
                // probably more", which named a limit, guessed at its size,
                // and gave the person nothing to do about it. Brim knows why
                // the read failed and knows the one setting that fixes it,
                // so it says that instead.
                if footprint.unreadableEntries > 0 {
                    let count = footprint.unreadableEntries
                    let items = count == 1 ? "item" : "items"
                    let fullDiskAccessIsOn = access.isGranted
                    Label {
                        Text(fullDiskAccessIsOn
                             ? "\(count) \(items) here are protected by macOS and are not "
                             + "counted in this total."
                             : "\(count) \(items) sit behind Full Disk Access. Switch it on "
                             + "and Brim measures them too.")
                    } icon: {
                        Image(systemName: fullDiskAccessIsOn ? "lock" : "eye.slash")
                    }
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    if !fullDiskAccessIsOn {
                        Button("Open Full Disk Access") {
                            FullDiskAccess.openSettings()
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(
                "\(locations) locations found, across "
                + "\(model.footprintGroups.count) discovery mechanisms. "
                + "The app itself is \(ByteText.short(application.bundleSizeBytes))."
                + (footprint.unreadableEntries > 0
                   ? (access.isGranted
                      ? " \(footprint.unreadableEntries) items are protected by macOS and are "
                      + "not in this total."
                      : " \(footprint.unreadableEntries) items sit behind Full Disk Access.")
                   : "")
            )
            .accessibilityValue(ByteText.short(footprint.totalSizeBytes) + " in total")
        }
    }

    @ViewBuilder
    private func footprintBody(_ application: InstalledApplication) -> some View {
        if model.isInspecting {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.footprintGroups.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing found beyond the application itself")
                    .font(.headline)
                Text("No other files were found for this application.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.footprintGroups) { group in
                    Section {
                        ForEach(group.items, id: \.evidence.url) { item in
                            HStack {
                                Text(item.evidence.url.path)
                                    .font(.caption)
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteText.short(item.sizeBytes))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(group.explanation.isEmpty ? group.mechanism : group.explanation)
                                    .font(.subheadline)
                                Spacer()
                                Text(group.strongestTier.shortLabel)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(group.items.count) · \(ByteText.short(group.totalBytes))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
