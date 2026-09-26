import BrimCore
import Foundation

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
    private typealias Location = LocationInventory.Location
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

    public func scan(for identity: Identity, in root: FileSystemRoot) async throws -> EvidenceFindings {
        findings(for: identity, in: root)
    }

    /// The evidence, and an honest account of what was not looked at.
    public func findings(
        for identity: Identity, in root: FileSystemRoot
    ) -> EvidenceFindings {
        let fm = FileManager.default
        let runBudget = budget()
        var evidence: [Evidence] = []
        var timedOut: [String] = []
        var unreadable: [String] = []
        var listings: [String: DirectoryEntries] = [:]

        func listing(_ directory: URL) -> DirectoryEntries {
            if let cached = listings[directory.path] {
                return cached
            }
            let read = Self.entries(of: directory, fm: fm)
            listings[directory.path] = read
            return read
        }

        // Cheap first: one existence check per location. Even a hundred
        // of these is a few milliseconds, so they are never skipped for
        // time and a slow run still gets the certain answers.
        for location in inventory.locations where location.rule != .identifierInsideBundle {
            let directory = root.url(for: location.domain)
            let candidates = Self.candidates(for: location, identity: identity)
            guard !candidates.isEmpty else { continue }
            let read = listing(directory)
            if case .refused = read {
                unreadable.append(directory.path)
            }
            for candidate in candidates {
                let url = directory.appendingPathComponent(candidate)
                guard fm.fileExists(atPath: url.path) else { continue }
                evidence.append(Evidence(
                    url: url,
                    tier: Self.tier(for: candidate, location: location, identity: identity),
                    mechanism: "LocationInventorySource",
                    humanSentence: location.sentence
                ))
            }
            // A prefix rule needs the directory listed, which is the one
            // cheap rule that can still be refused.
            if location.rule == .bundleIdentifierPrefix, !identity.searchBundleIdentifiers.isEmpty {
                switch read {
                case .refused:
                    unreadable.append(directory.path)
                case let .listed(names):
                    for name in names {
                        let matches = identity.searchBundleIdentifiers.contains { name.hasPrefix($0 + ".") }
                        guard matches else { continue }
                        let url = directory.appendingPathComponent(name)
                        guard !evidence.contains(where: { $0.url == url }) else { continue }
                        let matchedID = identity.searchBundleIdentifiers
                            .filter { name.hasPrefix($0 + ".") }
                            .max { $0.count < $1.count }
                        evidence.append(Evidence(
                            url: url, tier: matchedID == identity.bundleID ? location.tier : .C,
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
            guard !identity.searchBundleIdentifiers.isEmpty else { break }
            let directory = root.url(for: location.domain)

            guard !runBudget.hasRunOut else {
                timedOut.append(directory.path)
                continue
            }
            switch listing(directory) {
            case .absent:
                continue
            case .refused:
                unreadable.append(directory.path)
            case let .listed(names):
                for name in names where !name.hasPrefix(".") {
                    let item = directory.appendingPathComponent(name)
                    guard let foundID = Self.declaredIdentifier(at: item),
                          identity.searchBundleIdentifiers.contains(foundID) else { continue }
                    evidence.append(Evidence(
                        url: item, tier: foundID == identity.bundleID ? location.tier : .C,
                        mechanism: "LocationInventorySource",
                        humanSentence: location.sentence
                    ))
                }
            }
        }

        return EvidenceFindings(
            evidence: evidence,
            completeness: ScanCompleteness(unreadable: unreadable, timedOut: timedOut)
        )
    }

    /// What to look for in one location, given who is being uninstalled.
    static func candidates(
        for location: LocationInventory.Location, identity: Identity
    ) -> [String] {
        switch location.rule {
        case .bundleIdentifier:
            return identity.searchBundleIdentifiers
        case let .bundleIdentifierFile(ext):
            return identity.searchBundleIdentifiers.map { "\($0).\(ext)" }
        case .bundleIdentifierPrefix:
            // The exact name as well as the prefixed ones, because
            // `com.example.app.plist` is the common case.
            return identity.searchBundleIdentifiers.flatMap { ["\($0).plist", $0] }
        case .applicationName:
            // Both names, because an application's folders are named after
            // whichever of them its developer reached for. Visual Studio
            // Code is "Visual Studio Code" on disk and "Code" to itself,
            // and its 143 MB of support files are under the second.
            return identity.searchNames
        case .applicationNameLowercased:
            var seen = Set<String>()
            return identity.searchNames
                .map { $0.lowercased() }
                .filter { seen.insert($0).inserted }
        case .identifierInsideBundle:
            return []
        }
    }

    private static func tier(for candidate: String, location: Location, identity: Identity) -> EvidenceTier {
        switch location.rule {
        case .bundleIdentifier:
            guard let main = identity.bundleID else { return .C }
            return candidate == main ? location.tier : .C
        case let .bundleIdentifierFile(ext):
            guard let main = identity.bundleID else { return .C }
            return candidate == "\(main).\(ext)" ? location.tier : .C
        case .bundleIdentifierPrefix:
            guard let main = identity.bundleID else { return .C }
            return candidate == main || candidate == "\(main).plist" ? location.tier : .C
        default:
            return location.tier
        }
    }

    static func entries(of directory: URL, fm: FileManager) -> DirectoryEntries {
        DirectoryEntries.read(directory, using: fm)
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
