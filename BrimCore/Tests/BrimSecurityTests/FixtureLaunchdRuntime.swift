import BrimCore
import BrimOps
import Foundation

extension LaunchdRuntimeClient {
    /// These plists live only below NSTemporaryDirectory and have never
    /// been bootstrapped. Their runtime is modeled separately from file removal.
    static let unregisteredFixture = Self(stop: { path in
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(temporary + "/") else {
            throw NSError(domain: "FixtureScope", code: 1)
        }
        _ = try LaunchdJobDefinition.read(path)
    }, restore: { _ in }, observe: { _, _ in .absent })
}
