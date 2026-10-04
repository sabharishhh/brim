import BrimCore
import Darwin
import Foundation

public struct HomebrewCaskInventory: Sendable {
    public struct UnresolvedRecord: Sendable {
        public let receiptPath: String
        public let possibleTargets: Set<String>
        public let targetsChecked: Bool
        public let completeness: ScanCompleteness

        public init(
            receiptPath: String, possibleTargets: Set<String>, targetsChecked: Bool,
            completeness: ScanCompleteness
        ) {
            self.receiptPath = receiptPath
            self.possibleTargets = possibleTargets
            self.targetsChecked = targetsChecked
            self.completeness = completeness
        }
    }

    public let tokens: Set<String>
    public let installations: [HomebrewInstallation]
    public let completeness: ScanCompleteness
    public let unresolvedRecords: [UnresolvedRecord]
    public let directoryCompleteness: ScanCompleteness

    public init(
        tokens: Set<String> = [], installations: [HomebrewInstallation] = [],
        completeness: ScanCompleteness = .complete, unresolvedRecords: [UnresolvedRecord] = [],
        directoryCompleteness: ScanCompleteness? = nil
    ) {
        self.tokens = tokens
        self.installations = installations
        self.completeness = completeness
        self.unresolvedRecords = unresolvedRecords
        self.directoryCompleteness = directoryCompleteness ?? completeness
    }
}

/// Reads recorded application paths from the Caskroom without running Homebrew.
public struct UpdateSourceScanner: Sendable {
    private let homebrewPrefixes: [String]

    public init(
        homebrewPrefixes: [String] = ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"]
    ) {
        self.homebrewPrefixes = homebrewPrefixes
    }

    /// Directory names alone are available to older display callers, never as ownership proof.
    public func installedCasks(fileManager: FileManager = .default) -> Set<String> {
        var casks: Set<String> = []
        for prefix in homebrewPrefixes {
            let caskroom = "\(prefix)/Caskroom"
            guard let names = try? fileManager.contentsOfDirectory(atPath: caskroom) else { continue }
            casks.formUnion(names.filter { !$0.hasPrefix(".") })
        }
        return casks
    }

    public func installedCaskInventory(budget: ScanBudget = ScanBudget(total: 5)) -> HomebrewCaskInventory {
        var directories = DirectorySearch(budget: budget)
        var tokens: Set<String> = []
        var installations: [HomebrewInstallation] = []
        var unresolved: [HomebrewCaskInventory.UnresolvedRecord] = []
        var completeness = ScanCompleteness.complete
        for prefix in homebrewPrefixes {
            let caskroom = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom")
            for token in directories.entries(caskroom) where HomebrewInstallation.isValidToken(token) {
                let cask = caskroom.appendingPathComponent(token)
                guard directories.canContinue(at: cask) else { break }
                tokens.insert(token)
                let record = HomebrewRecordReader.read(cask: cask, token: token, budget: budget)
                installations += record.installations
                completeness = completeness.merging(record.completeness)
                if let unknown = record.unresolved {
                    unresolved.append(unknown)
                }
            }
        }
        return HomebrewCaskInventory(
            tokens: tokens, installations: installations,
            completeness: completeness.merging(directories.completeness), unresolvedRecords: unresolved,
            directoryCompleteness: directories.completeness
        )
    }

    /// A readable exact record can survive an unrelated receipt gap. Unknown
    /// competing paths and duplicate exact records still refuse attribution.
    public static func ownership(
        at application: URL, among inventory: HomebrewCaskInventory
    ) -> (installation: HomebrewInstallation?, completeness: ScanCompleteness) {
        guard inventory.directoryCompleteness.isComplete else { return (nil, inventory.completeness) }
        let path = application.standardizedFileURL.path
        let matches = inventory.installations.filter { $0.applicationPath == path }
        guard matches.count == 1, let match = matches.first else {
            let ambiguity = matches.count > 1 ? ScanCompleteness(unreadable: matches.map(\.receiptPath)) : .complete
            return (nil, inventory.completeness.merging(ambiguity))
        }
        let possibleCompetitors = inventory.unresolvedRecords.filter {
            $0.receiptPath != match.receiptPath && (!$0.targetsChecked || $0.possibleTargets.contains(path))
        }
        guard possibleCompetitors.isEmpty else {
            return (nil, possibleCompetitors.reduce(ScanCompleteness.complete) { $0.merging($1.completeness) })
        }
        return (match, .complete)
    }

    public static func matchingInstallation(
        at application: URL, among inventory: HomebrewCaskInventory
    ) -> HomebrewInstallation? {
        ownership(at: application, among: inventory).installation
    }

    public static func matchingCask(
        for application: InstalledApplication, among inventory: HomebrewCaskInventory
    ) -> String? {
        matchingInstallation(at: application.url, among: inventory)?.token
    }

    public static func matchingCask(
        for _: InstalledApplication, among _: Set<String>
    ) -> String? {
        nil
    }

    /// Lowercased, with everything that is not a letter or a number
    /// removed, so "boringNotch" and "boring-notch" are the same word and
    /// "Visual Studio Code" and "visual-studio-code" are too.
    static func normalise(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

private enum HomebrewRecordReader {
    struct Reading {
        let installations: [HomebrewInstallation]
        let unresolved: HomebrewCaskInventory.UnresolvedRecord?
        let completeness: ScanCompleteness
    }

    static func read(cask: URL, token: String, budget: ScanBudget) -> Reading {
        let receipt = cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        var search = DirectorySearch(budget: budget)
        guard search.canContinue(at: receipt) else {
            return uncertain(receipt: receipt, installations: [], completeness: search.completeness)
        }
        guard let record = appRecord(at: receipt) else {
            search.unreadable.append(receipt.path)
            let defense = defensiveTargets(in: cask, budget: budget)
            let completeness = search.completeness.merging(defense.completeness)
            let unresolved = HomebrewCaskInventory.UnresolvedRecord(
                receiptPath: receipt.path, possibleTargets: defense.targets,
                targetsChecked: defense.completeness.isComplete && !defense.targets.isEmpty,
                completeness: completeness
            )
            return Reading(installations: [], unresolved: unresolved, completeness: completeness)
        }
        var installations: [HomebrewInstallation] = []
        for name in record.names.sorted() {
            let link = cask.appendingPathComponent(record.version).appendingPathComponent(name)
            guard search.canContinue(at: link) else { break }
            guard let target = target(of: link), let installation = HomebrewInstallation(
                token: token, applicationPath: target, receiptPath: receipt.path
            ) else {
                search.unreadable.append(link.path)
                continue
            }
            installations.append(installation)
        }
        guard search.completeness.isComplete else {
            return uncertain(receipt: receipt, installations: installations, completeness: search.completeness)
        }
        return Reading(installations: installations, unresolved: nil, completeness: .complete)
    }

    private static func uncertain(
        receipt: URL, installations: [HomebrewInstallation], completeness: ScanCompleteness
    ) -> Reading {
        Reading(installations: installations, unresolved: .init(
            receiptPath: receipt.path, possibleTargets: Set(installations.map(\.applicationPath)),
            targetsChecked: false, completeness: completeness
        ), completeness: completeness)
    }

    private static func appRecord(at receipt: URL) -> (version: String, names: Set<String>)? {
        guard let data = receiptData(at: receipt),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = values["source"] as? [String: Any],
              let version = source["version"] as? String, IdentitySurface.isPathComponent(version),
              let artifacts = values["uninstall_artifacts"] as? [[String: Any]] else { return nil }
        var names = Set<String>()
        for artifact in artifacts where artifact["app"] != nil {
            guard let apps = artifact["app"] as? [Any], let source = apps.first as? String else { return nil }
            let name = URL(fileURLWithPath: source).lastPathComponent
            guard name.hasSuffix(".app"), IdentitySurface.isPathComponent(name) else { return nil }
            names.insert(name)
        }
        return (version, names)
    }

    /// Incomplete receipts cannot authorize a match. Their app links can
    /// still expose a competing target or rule out a clearly unrelated record.
    private static func defensiveTargets(
        in cask: URL, budget: ScanBudget
    ) -> (targets: Set<String>, completeness: ScanCompleteness) {
        var search = DirectorySearch(budget: budget)
        var targets = Set<String>()
        for name in search.entries(cask) where !name.hasPrefix(".") {
            let version = cask.appendingPathComponent(name)
            guard search.canContinue(at: version) else { break }
            var info = stat()
            guard lstat(version.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                search.unreadable.append(version.path)
                continue
            }
            for name in search.entries(version) where name.hasSuffix(".app") {
                let link = version.appendingPathComponent(name)
                guard search.canContinue(at: link) else { break }
                if let path = target(of: link) {
                    targets.insert(path)
                } else {
                    search.unreadable.append(link.path)
                }
            }
        }
        return (targets, search.completeness)
    }

    private static func target(of link: URL) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
              !destination.contains("\0") else { return nil }
        let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
            : link.deletingLastPathComponent().appendingPathComponent(destination)
        return target.standardizedFileURL.path
    }

    private static func receiptData(at receipt: URL) -> Data? {
        let descriptor = open(receipt.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        let limit = 1024 * 1024
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= Int64(limit) else { return nil }
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
                }; return nil
            }
            if count == 0 {
                break
            }
            offset += count
        }
        return offset <= limit ? Data(bytes.prefix(offset)) : nil
    }
}
