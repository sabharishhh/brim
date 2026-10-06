import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// What a kept recording says an application created, as evidence.
///
/// A recording is a record: the person watched these appear while the app
/// was installed and set up, and kept them. That is Tier B, the same as a
/// name the developer chose, and every safeguard after this still applies:
/// the Tier S veto, the claimant list, the safety checker, developer
/// artefact classes and the running-app refusal.
public struct InstallRecordingSource: EvidenceSource {
    let recordings: @Sendable () -> [InstallRecording]

    public init(recordings: @escaping @Sendable () -> [InstallRecording]) {
        self.recordings = recordings
    }

    public func evidence(for identity: Identity, in _: FileSystemRoot) async throws -> [Evidence] {
        guard let identifier = identity.bundleID, !identifier.isEmpty else { return [] }
        return Self.items(for: identifier, in: recordings()).map { item, sentence in
            Evidence(url: URL(fileURLWithPath: item.path), tier: .B, mechanism: "InstallRecordingSource",
                     humanSentence: sentence)
        }
    }

    /// The files each recording kept for this app and that are still on
    /// the disk, with the sentence a row shows. An item named for another
    /// app of the same install stays with that app.
    static func items(
        for identifier: String, in recordings: [InstallRecording]
    ) -> [(RecordedItem, String)] {
        var found: [(RecordedItem, String)] = []
        for recording in recordings where recording.concerns(identifier) {
            guard let app = recording.apps.first(where: { $0.bundleID?.lowercased() == identifier.lowercased() })
            else { continue }
            let sentence = recording.evidence(for: app.name)
            for item in recording.items where !item.isRegistration && (item.app == nil || item.app == app.path)
                && PathObservation.observe(item.path).isPresent {
                found.append((item, sentence))
            }
        }
        return found
    }

    /// Remnants of apps a recording names that are no longer installed,
    /// for whatever the sweep did not already list. An item linked only by
    /// timing, which the person kept, is held to the sweep's rule for
    /// things nothing names: written this week, it belongs to something
    /// alive. One named for the app is the app's whenever it was written.
    public static func remnants(
        _ recordings: [InstallRecording], installed: Set<String>, listed: Set<String>,
        now: Date = Date(), inUseWithin: TimeInterval? = 7 * 24 * 60 * 60
    ) -> [Leftover] {
        var leftovers: [Leftover] = []
        var offered = listed
        for recording in recordings {
            for app in recording.apps {
                guard let identifier = app.bundleID?.lowercased(), !installed.contains(identifier) else { continue }
                for (item, sentence) in items(for: identifier, in: [recording]) {
                    let url = URL(fileURLWithPath: item.path)
                    guard !offered.contains(item.path),
                          !offered.contains(where: { item.path.hasPrefix($0 + "/") }) else { continue }
                    if item.app == nil, let window = inUseWithin, let written = LeftoversScanner.newestWrite(in: url),
                       now.timeIntervalSince(written) < window {
                        continue
                    }
                    let measured = ArtifactSizer.measure(at: url)
                    offered.insert(item.path)
                    leftovers.append(Leftover(
                        url: url, size: measured.logicalBytes, category: .orphaned,
                        potentialOwner: Identity(bundleID: app.bundleID, name: app.name), evidence: sentence,
                        capability: RemovalCapability.forDeleting(item.path),
                        sizeIsKnown: measured.state == .complete
                    ))
                }
            }
        }
        return leftovers
    }
}
