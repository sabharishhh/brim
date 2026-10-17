@testable import BrimScan
import Foundation
import Testing

/// `brew upgrade` can print more than a pipe holds, so its output must be
/// drained or it waits on Brim forever.
struct HomebrewOutputTests {
    @Test func `a brew that says a great deal still finishes`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let brew = folder.appendingPathComponent("brew")
        try Data("#!/bin/sh\n/usr/bin/yes 'New formula' | /usr/bin/head -c 400000\nexit 0\n".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let checker = UpdateChecker(brewPath: brew.path)
        let outcome = try await withThrowingTaskGroup(of: String??.self) { group in
            group.addTask { await .some(checker.upgradeCask("demo")) }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                return .none
            }
            let first = try await group.next() ?? .none
            group.cancelAll()
            return first
        }
        let finished = try #require(outcome, "brew never finished")
        #expect(finished == nil)
    }
}
