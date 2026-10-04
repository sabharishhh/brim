import BrimCore
import BrimScan
import Foundation

extension BrimService {
    nonisolated static func observedSpaceIncrease(before: Int64?, after: Int64?) -> Int64 {
        guard let before, let after, before >= 0, after >= 0 else { return 0 }
        return max(0, after - before)
    }

    /// The service derives disposal policy from the current artifact records.
    @concurrent
    static func classifiedDeveloperTargets(_ footprint: Footprint, in root: FileSystemRoot) async -> Footprint {
        let home = root.url(for: .userHomeDotFolders)
        let items = footprint.items.map { item in
            let catalogue = DeveloperCacheScanner.classification(
                at: item.evidence.url, home: home, darwinCache: root.url(for: .darwinUserCache)
            )
            let project = ProjectBuildScanner.classification(at: item.evidence.url, home: home)
            let classification = catalogue == .stateful || project == .stateful ? .stateful : (
                HomebrewDownloadScanner.classification(at: item.evidence.url, home: home)
                    ?? catalogue ?? project
            )
            return FootprintItem(
                evidence: item.evidence, sizeBytes: item.sizeBytes, capability: item.capability,
                unreadableEntries: item.unreadableEntries, sizeMeasurement: item.sizeMeasurement,
                artifactClassification: classification
            )
        }
        return Footprint(
            identity: footprint.identity,
            items: items,
            logicalSizeBytes: footprint.logicalSizeBytes,
            reclaimableSizeBytes: footprint.reclaimableSizeBytes,
            snapshotPinnedBytes: footprint.snapshotPinnedBytes,
            completeness: footprint.completeness
        )
    }

    nonisolated static func overlapsExcludedFolder(_ target: URL, exclusions: [URL]) -> Bool {
        exclusions.contains { ArtifactSizer.rootsOverlap(target, $0) }
    }

    nonisolated static func validateExclusions(in intent: PlanIntent) throws {
        let exclusions = intent.excludedFolders ?? []
        guard !intent.explicitTargets.contains(where: { overlapsExcludedFolder($0, exclusions: exclusions) }) else {
            throw ApplyError.validationFailed("A selected path overlaps a folder you excluded.")
        }
    }

    nonisolated static func explicitEvidence(for targets: [URL]) -> [Evidence] {
        targets.map { url in
            let isJob = LaunchdJobFile.isOne(url)
            return Evidence(
                url: url,
                tier: .A,
                mechanism: isJob ? "LaunchdSource" : "DirectTarget",
                humanSentence: isJob ? "A launchd job file named for removal" :
                    "Specific target requested by intent"
            )
        }
    }

    static func homebrewInstallation(
        for subject: Identity, in root: FileSystemRoot
    ) async -> (installation: HomebrewInstallation?, completeness: ScanCompleteness) {
        let inventory = await homebrewInventory(in: root)
        guard let path = subject.bundlePath else { return (nil, inventory.completeness) }
        return UpdateSourceScanner.ownership(at: URL(fileURLWithPath: path), among: inventory)
    }

    @concurrent
    static func homebrewInventory(in root: FileSystemRoot) async -> HomebrewCaskInventory {
        let prefixes = ["opt/homebrew", "usr/local"].map { root.rootURL.appendingPathComponent($0).path }
        return UpdateSourceScanner(homebrewPrefixes: prefixes).installedCaskInventory()
    }
}
