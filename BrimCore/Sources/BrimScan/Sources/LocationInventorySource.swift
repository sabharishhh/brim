import Foundation
import BrimCore

/// Walks the location inventory, applying each location's own rule.
///
/// This replaces nine hard-coded paths. The point is not the count: it is
/// that every location now carries the rule by which something there is
/// shown to belong to an application, and the tier follows from the rule.
/// A folder Brim can only name-match is Tier C and says so in the row,
/// which is the difference between finding more and guessing more.
///
/// Two kinds of work happen here and they cost very differently. Asking
/// whether one path exists is a single `lstat`. Reading the `Info.plist`
/// of every bundle in a plug-in folder is a directory walk, so those are
/// done last and under the run's remaining budget.
public struct LocationInventorySource: EvidenceSource {

    private let inventory: LocationInventory
    private let budget: @Sendable () -> ScanBudget

    public init(
        inventory: LocationInventory = .standard,
        budget: @escaping @Sendable () -> ScanBudget = { ScanBudget() }
    ) {
        self.inventory = inventory
        self.budget = budget
    }

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        findings(for: identity, in: root).evidence
    }

    /// The evidence, and an honest account of what was not looked at.
    public func findings(
        for identity: Identity, in root: FileSystemRoot
    ) -> (evidence: [Evidence], completeness: ScanCompleteness) {
        let fm = FileManager.default
        let runBudget = budget()
        var evidence: [Evidence] = []
        var timedOut: [String] = []
        var unreadable: [String] = []

        // Cheap first: one existence check per location. Even a hundred
        // of these is a few milliseconds, so they are never skipped for
        // time and a slow run still gets the certain answers.
        for location in inventory.locations where location.rule != .identifierInsideBundle {
            let directory = root.url(for: location.domain)
            for candidate in Self.candidates(for: location, identity: identity) {
                let url = directory.appendingPathComponent(candidate)
                guard fm.fileExists(atPath: url.path) else { continue }
                evidence.append(Evidence(
                    url: url,
                    tier: location.tier,
                    mechanism: "LocationInventorySource",
                    humanSentence: location.sentence
                ))
            }
            // A prefix rule needs the directory listed, which is the one
            // cheap rule that can still be refused.
            if location.rule == .bundleIdentifierPrefix, let bundleID = identity.bundleID {
                switch Self.entries(of: directory, fm: fm) {
                case .refused:
                    unreadable.append(directory.path)
                case .listed(let names):
                    for name in names where name.hasPrefix(bundleID + ".") {
                        let url = directory.appendingPathComponent(name)
                        guard !evidence.contains(where: { $0.url == url }) else { continue }
                        evidence.append(Evidence(
                            url: url, tier: location.tier,
                            mechanism: "LocationInventorySource",
                            humanSentence: location.sentence
                        ))
                    }
                case .absent:
                    break
                }
            }
        }

        // Expensive last: reading a bundle's Info.plist is the only way
        // to attribute an audio plug-in, whose file name says nothing.
        for location in inventory.locations where location.rule == .identifierInsideBundle {
            guard let bundleID = identity.bundleID else { break }
            let directory = root.url(for: location.domain)

            guard !runBudget.hasRunOut else {
                timedOut.append(directory.path)
                continue
            }
            switch Self.entries(of: directory, fm: fm) {
            case .absent:
                continue
            case .refused:
                unreadable.append(directory.path)
            case .listed(let names):
                for name in names where !name.hasPrefix(".") {
                    let item = directory.appendingPathComponent(name)
                    guard Self.declaredIdentifier(at: item) == bundleID else { continue }
                    evidence.append(Evidence(
                        url: item, tier: location.tier,
                        mechanism: "LocationInventorySource",
                        humanSentence: location.sentence
                    ))
                }
            }
        }

        return (
            evidence,
            ScanCompleteness(unreadable: unreadable, timedOut: timedOut)
        )
    }

    /// What to look for in one location, given who is being uninstalled.
    static func candidates(
        for location: LocationInventory.Location, identity: Identity
    ) -> [String] {
        switch location.rule {
        case .bundleIdentifier:
            return identity.bundleID.map { [$0] } ?? []
        case .bundleIdentifierFile(let ext):
            return identity.bundleID.map { ["\($0).\(ext)"] } ?? []
        case .bundleIdentifierPrefix:
            // The exact name as well as the prefixed ones, because
            // `com.example.app.plist` is the common case.
            return identity.bundleID.map { ["\($0).plist", $0] } ?? []
        case .applicationName:
            return identity.name.isEmpty ? [] : [identity.name]
        case .identifierInsideBundle:
            return []
        }
    }

    enum Listing {
        case absent
        /// Present and readable.
        case listed([String])
        /// Present and refused. Different from empty, and reported.
        case refused
    }

    static func entries(of directory: URL, fm: FileManager) -> Listing {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .absent }
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return .refused
        }
        return .listed(names)
    }

    static func declaredIdentifier(at bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        return parsed["CFBundleIdentifier"] as? String
    }
}
