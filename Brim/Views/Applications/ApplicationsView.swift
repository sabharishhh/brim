import SwiftUI
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
    @SwiftUI.Environment(\.brimService) private var service
    @State private var uninstalling: InstalledApplication?

    var body: some View {
        HSplitView {
            applicationList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadIfNeeded(service: service) }
        .sheet(item: $uninstalling) { application in
            UninstallSheet(application: application, service: service) {
                // Drop the row at once if the bundle really is gone —
                // re-enumerating every application takes seconds, and a row
                // that outlives "nothing remains" reads as a failure. The
                // full refresh still follows, to pick up anything else.
                model.forgetIfRemoved(application)
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
                         ? "Scanning..."
                         : "\(model.applications.count) installed")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)
            .accessibilityElement(children: .combine)

            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityLabel("Search applications")

            Divider()

            List(selection: Binding(
                get: { model.selected?.id },
                set: { id in model.select(model.applications.first { $0.id == id }) }
            )) {
                ForEach(model.visibleApplications) { application in
                    row(application).tag(application.id)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ application: InstalledApplication) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(application.name)
                    .fontWeight(.medium)
                HStack(spacing: 5) {
                    if let version = application.version {
                        Text(version)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: application.bundleSizeBytes, countStyle: .file))
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
                    .help("Part of macOS — cannot be removed")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(application.name). "
            + (application.version.map { "Version \($0). " } ?? "")
            + ByteCountFormatter.string(fromByteCount: application.bundleSizeBytes, countStyle: .file)
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
                Text("Brim will show everything it has left on this Mac, and how it knows.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
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
            HStack(spacing: 6) {
                Text("**\(locations)** \(locations == 1 ? "location" : "locations")")
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: footprint.totalSizeBytes, countStyle: .file))
                    .monospacedDigit()
                Text("·")
                Text("\(model.footprintGroups.count) \(model.footprintGroups.count == 1 ? "mechanism" : "mechanisms")")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(locations) locations found, "
                + ByteCountFormatter.string(fromByteCount: footprint.totalSizeBytes, countStyle: .file)
                + ", across \(model.footprintGroups.count) discovery mechanisms"
            )
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
                Text("Brim searched every location an app can write to and found no other trace.")
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
                                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
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
                            Text("\(group.items.count) · \(ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file))")
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
