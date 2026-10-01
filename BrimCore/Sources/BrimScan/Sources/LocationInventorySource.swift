import BrimCore
import Darwin
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
        let subject = LocationInventory.Subject(identity)

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
            // Container names and owner records must agree. The shared
            // reader owns these domains so a generic name match cannot
            // strengthen conflicting metadata back to a selected row.
            if location.domain == .userContainers || location.domain == .systemContainers {
                continue
            }
            let directory = root.url(for: location.domain)
            let candidates = location.candidates(for: subject)
            let needsListing = switch location.rule {
            case .bundleIdentifierPrefix, .bundleIdentifierDelimitedPrefix,
                 .applicationNameDelimitedPrefix, .temporaryDirectory, .clientOfService,
                 .homeDotFolder, .diagnosticReport:
                true
            default:
                false
            }
            guard !candidates.isEmpty || needsListing else { continue }
            let read = listing(directory)
            if case .refused = read, !needsListing {
                unreadable.append(directory.path)
            }
            for candidate in candidates {
                let url = directory.appendingPathComponent(candidate)
                guard fm.fileExists(atPath: url.path),
                      let tier = location.matchTier(name: candidate, subject: subject) else { continue }
                evidence.append(Evidence(
                    url: url,
                    tier: tier,
                    mechanism: "LocationInventorySource",
                    humanSentence: location.sentence
                ))
            }
            // Prefix rules need the directory listed, which can be refused.
            if needsListing {
                switch read {
                case .refused:
                    unreadable.append(directory.path)
                case let .listed(names):
                    for name in names {
                        guard let tier = location.matchTier(name: name, subject: subject) else { continue }
                        let url = directory.appendingPathComponent(name)
                        guard !evidence.contains(where: { $0.url == url }) else { continue }
                        evidence.append(Evidence(
                            url: url, tier: tier,
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
            guard !subject.identifiers.isEmpty else { break }
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
                    guard !runBudget.hasRunOut else { timedOut.append(directory.path); break }
                    let declared = Self.bundleInfo(at: item)
                    if declared.refused {
                        unreadable.append(item.appendingPathComponent("Contents/Info.plist").path)
                    }
                    guard let foundID = declared.values?["CFBundleIdentifier"] as? String,
                          let tier = location.matchTier(
                              name: name, subject: subject, declaredIdentifier: foundID
                          ) else { continue }
                    evidence.append(Evidence(
                        url: item, tier: tier,
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
        location.candidates(for: identity)
    }

    static func entries(of directory: URL, fm: FileManager) -> DirectoryEntries {
        DirectoryEntries.read(directory, using: fm)
    }

    static func declaredIdentifier(at bundle: URL) -> String? {
        bundleInfo(at: bundle).values?["CFBundleIdentifier"] as? String
    }

    static func bundleInfo(at bundle: URL) -> (values: [String: Any]?, refused: Bool) {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let descriptor = open(plist.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return (nil, errno != ENOENT && errno != ENOTDIR) }
        defer { close(descriptor) }
        var info = stat()
        let limit = 64 * 1024
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= Int64(limit) else { return (nil, true) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        let capacity = bytes.count
        var offset = 0
        while offset < capacity {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), capacity - offset)
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }; return (nil, true)
            }
            if count == 0 {
                break
            }
            offset += count
        }
        guard offset <= limit,
              let parsed = try? PropertyListSerialization.propertyList(from: Data(bytes.prefix(offset)), format: nil)
              as? [String: Any] else { return (nil, true) }
        return (parsed, false)
    }
}
