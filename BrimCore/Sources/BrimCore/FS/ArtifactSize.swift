import Foundation

/// Content and allocated blocks measured for an artifact. Neither figure promises
/// the capacity a removal will return on a filesystem with clones or snapshots.
public struct ArtifactSize: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending, complete, partial, unknown
    }

    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let state: State
    public let completeness: ScanCompleteness

    public init(
        logicalBytes: Int64 = 0, allocatedBytes: Int64 = 0,
        state: State, completeness: ScanCompleteness = .complete
    ) {
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.state = state
        self.completeness = completeness
    }

    public static let pending = ArtifactSize(state: .pending)
    public var isEmpty: Bool {
        state == .complete && logicalBytes == 0
    }
}

/// One sizing rule for an already identified artifact. Discovery may exclude hidden
/// projects; measurement includes every hidden child and never follows a symlink.
public enum ArtifactSizer {
    public static func measure(
        at url: URL, budget: ScanBudget = ScanBudget(), maximumEntries: Int = 200_000
    ) -> ArtifactSize {
        measure(roots: [url], budget: budget, maximumEntries: maximumEntries)
    }

    public static func measure(
        roots: [URL], budget: ScanBudget = ScanBudget(), maximumEntries: Int = 200_000
    ) -> ArtifactSize {
        var traversal = ArtifactSizeTraversal(budget: budget, maximumEntries: maximumEntries)
        return traversal.measure(roots: minimalRoots(roots))
    }

    /// Removing a parent also removes its children. Keep one root for that content.
    public static func minimalRoots(_ urls: [URL]) -> [URL] {
        let candidates: [String] = urls.map(\.standardizedFileURL.path)
        let paths = Set(candidates).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count < $1.count
        }
        var kept: [String] = []
        for path in paths where !kept.contains(where: { path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
            kept.append(path)
        }
        return kept.map { URL(fileURLWithPath: $0) }
    }

    /// A parent removal includes its child. Compare both the displayed paths
    /// and their resolved locations so aliases cannot bypass an exclusion.
    public static func rootsOverlap(_ first: URL, _ second: URL) -> Bool {
        func overlap(_ firstPath: String, _ secondPath: String) -> Bool {
            firstPath == secondPath || firstPath.hasPrefix(secondPath == "/" ? "/" : secondPath + "/")
                || secondPath.hasPrefix(firstPath == "/" ? "/" : firstPath + "/")
        }
        return overlap(first.standardizedFileURL.path, second.standardizedFileURL.path)
            || overlap(first.resolvingSymlinksInPath().path, second.resolvingSymlinksInPath().path)
    }
}

/// A disposal policy based on what an artifact is, rather than its folder name.
public enum ArtifactClassification: String, Codable, Equatable, Sendable {
    case rebuildableOutput
    case rebuildableCache
    case dependencyStore
    case toolManaged
    case stateful
    case unknown

    public var costOfError: CostOfError {
        switch self {
        case .rebuildableOutput, .rebuildableCache: .low
        case .dependencyStore, .toolManaged, .unknown: .medium
        case .stateful: .high
        }
    }
}
