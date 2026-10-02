import BrimCore
import BrimProtocol
import SwiftUI

// swiftformat:disable wrapMultilineStatementBraces
/// Fresh reads and successful actions are deliberately separate rows.
struct RegistrationResultSection: View {
    let report: RemovalReport

    var body: some View {
        let observations = report.registrationObservations ?? []
        let listed = observations.filter { !$0.remaining.isEmpty }
        let unknown = observations.filter(\.couldNotCheck)
        let preserved = observations.filter { !$0.preserved.isEmpty }
        let recovery = observations.filter { $0.recoveryCopies?.isEmpty == false }
        if !listed.isEmpty || !unknown.isEmpty || !preserved.isEmpty || !recovery.isEmpty
            || report.unknownPaths?.isEmpty == false || report.completedActions?.isEmpty == false {
            VStack(alignment: .leading, spacing: 12) {
                Text("Registrations")
                    .font(.headline)
                ForEach(listed) { observation in
                    Label("\(observation.capability.title): \(observation.remaining.count) still listed",
                          systemImage: "exclamationmark.circle")
                }
                ForEach(preserved) { observation in
                    Label("\(observation.capability.title): kept for another installation",
                          systemImage: "lock")
                }
                ForEach(recovery) { observation in
                    Label("\(observation.capability.title): kept with the recovery copy", systemImage: "trash")
                }
                ForEach(unknown) { observation in
                    Label("\(observation.capability.title): could not check", systemImage: "questionmark.circle")
                }
                if let paths = report.unknownPaths, !paths.isEmpty {
                    Label("\(paths.count) locations could not be checked", systemImage: "questionmark.folder")
                }
                if report.completedActions?.isEmpty == false {
                    Label("Permissions reset", systemImage: "checkmark.circle")
                }
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(observations.filter { !$0.confirmedClear }) { observation in
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: Self.symbols[observation.capability] ?? "app")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(observation.capability.title).font(.headline)
                                    if observation.capability == .backgroundItem, !observation.remaining.isEmpty {
                                        Text("Background controls disable activity; they do not delete these records.")
                                    }
                                    if let limitation = observation.coverage.limitation {
                                        Text(limitation)
                                    }
                                    ForEach(observation.remaining + observation.preserved
                                        + (observation.recoveryCopies ?? [])) { record in
                                            Text(record.programPath ?? record.rawTargetPath ?? record.identifier)
                                                .textSelection(.enabled)
                                            Text(record.evidence).foregroundStyle(.secondary)
                                        }
                                    Text(observation.observedAt, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(report.completedActions ?? [], id: \.self) { action in
                            Label(action, systemImage: "checkmark.shield")
                        }
                        ForEach(report.unknownPaths ?? [], id: \.self) { path in
                            Label(path, systemImage: "questionmark.folder").textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let symbols: [DeclaredCapability: String] = [
        .vpnConfiguration: "network.badge.shield.half.filled",
        .launchdJob: "gearshape.2",
        .privacyGrant: "hand.raised",
        .backgroundItem: "person.crop.circle.badge.clock",
        .fileProvider: "icloud",
        .systemExtension: "puzzlepiece.extension",
        .privilegedHelper: "lock.shield",
        .appExtension: "puzzlepiece",
        .launchServices: "arrow.up.forward.app",
        .applicationGroups: "square.3.layers.3d",
        .bundlePlugin: "powerplug",
        .installationRecords: "shippingbox",
        .firewallEntry: "network.badge.shield.half.filled"
    ]
}
