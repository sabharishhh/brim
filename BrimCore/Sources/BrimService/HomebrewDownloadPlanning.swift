import BrimCore
import BrimOps
import BrimScan
import Foundation

extension BrimService {
    public func planHomebrewDownloads(cachePath: URL, excluding folders: [URL]) async throws -> Plan {
        let home = root.url(for: .userHomeDotFolders)
        let expected = home.appendingPathComponent("Library/Caches/Homebrew").standardizedFileURL
        guard cachePath.standardizedFileURL == expected else {
            throw ToolCleanup.CleanupError
                .configurationUnavailable("The selected folder is not a supported downloads cache.")
        }
        let result = await Self.completedDownloads(home: home)
        guard result.completeness.isComplete else {
            throw ToolCleanup.CleanupError
                .configurationUnavailable("The download search did not finish. Nothing was moved.")
        }
        let targets = result.files.filter { !Self.overlapsExcludedFolder($0, exclusions: folders) }
        guard !targets.isEmpty else {
            throw ToolCleanup.CleanupError.configurationUnavailable("No completed downloads are available for cleanup.")
        }
        return try await plan(intent: PlanIntent(
            type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Completed downloads"),
            requesterKind: "ui", requesterIdentity: NSUserName(),
            specificTargets: targets, excludedFolders: folders
        ))
    }

    @concurrent
    private static func completedDownloads(home: URL) async -> HomebrewDownloadScanner.Result {
        HomebrewDownloadScanner.scan(home: home)
    }
}
