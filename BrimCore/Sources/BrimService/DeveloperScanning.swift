import BrimCore
import BrimScan
import Foundation

public extension BrimService {
    func developerCacheUpdates(excluding folders: [URL]) async -> AsyncStream<[DeveloperCache]> {
        await DeveloperCacheScanner(
            home: root.url(for: .userLibrary).deletingLastPathComponent(),
            darwinCache: root.url(for: .darwinUserCache),
            excludedFolders: folders
        ).updates()
    }
}
