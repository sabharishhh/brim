import BrimCore
@testable import BrimIndex
import Foundation
import Testing

// swiftformat:disable wrapMultilineStatementBraces

struct RecentInstallHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400

    /// A reinstalled app used its first-ever observation and stayed dated as
    /// the old installation, even after a snapshot had confirmed its absence.
    @Test func aRecordedReinstallStartsANewCurrentPeriod() async throws {
        try await withIndex { index in
            let anchor = app("Anchor")
            let returned = app("Returned", added: now - 20 * day)
            _ = try await index.recordInstalled([anchor, returned], at: now - 10 * day)
            #expect(try await index.appearanceWindows().isEmpty)
            _ = try await index.recordInstalled([anchor], at: now - 3 * day)
            #expect(try await index.appearanceWindows().isEmpty)
            _ = try await index.recordInstalled([anchor, returned], at: now - day)
            #expect(try await index.appearanceWindows()[returned.bundleID] == AppearanceWindow(
                seen: now - day, previousLook: now - 3 * day, addedAt: returned.addedAt, isReinstallation: true
            ))
            #expect(try await index.appearances() == [returned.bundleID: now - day])
            _ = try await index.recordInstalled([anchor], at: now)
            #expect(try await index.appearanceWindows().isEmpty)
        }
    }

    @Test func laterUpdatesDoNotReplaceTheOriginalDiscoveryEvidence() async throws {
        try await withIndex { index in
            let anchor = app("Anchor")
            let old = app("Old", added: now - 30 * day)
            _ = try await index.recordInstalled([anchor], at: now - 3 * day)
            _ = try await index.recordInstalled([anchor, old], at: now - 2 * day)
            _ = try await index.recordInstalled([anchor, app("Old", version: "2", added: now)], at: now)
            #expect(try await index.appearanceWindows()[old.bundleID] == AppearanceWindow(
                seen: now - 2 * day, previousLook: now - 3 * day, addedAt: now - 30 * day
            ))
        }
    }

    /// Changes kept one nonempty comparison forever. A new event displaced
    /// earlier activity from the same week, and old activity never expired.
    @Test func theWeekIncludesAllRecordedAppEventsAndExpiresOlderOnes() async throws {
        try await withIndex { index in
            _ = try await index.recordInstalled([app("Anchor")], at: now - 10 * day)
            _ = try await index.recordInstalled([app("Anchor"), app("Old")], at: now - 9 * day)
            _ = try await index.recordInstalled([app("Anchor", version: "2"), app("Old")], at: now - 6 * day)
            _ = try await index.recordInstalled([app("Anchor", version: "2")], at: now - 4 * day)
            _ = try await index.recordInstalled([app("Anchor", version: "2"), app("New")], at: now - 3 * day)
            _ = try await index.recordInstalled([app("Anchor", version: "3"), app("New")], at: now - 2 * day)
            _ = try await index.recordInstalled([app("Anchor", version: "3"), app("New")], at: now)
            let changes = try await index.recentChanges(since: now - 7 * day, until: now)
            #expect(changes.map(\.name) == ["Anchor", "New", "Old", "Anchor"])
            #expect(changes.map(\.kind) == [.updated(from: "2", to: "3"), .appeared,
                                            .disappeared, .updated(from: "1", to: "2")])
            #expect(changes.allSatisfy { $0.until >= now - 7 * day && $0.until <= now })
        }
    }

    @Test func eventsFromScansInTheSameSecondStillHaveDistinctIdentities() async throws {
        try await withIndex { index in
            let anchor = app("Anchor")
            _ = try await index.recordInstalled([anchor], at: now)
            _ = try await index.recordInstalled([anchor, app("Returned")], at: now)
            _ = try await index.recordInstalled([anchor, app("Returned", version: "2")], at: now)
            _ = try await index.recordInstalled([anchor], at: now)
            _ = try await index.recordInstalled([anchor, app("Returned", version: "2")], at: now)
            let changes = try await index.recentChanges(since: now - day, until: now)
            #expect(changes.count == 4)
            #expect(changes.map(\.kind) == [.appeared, .disappeared, .updated(from: "1", to: "2"), .appeared])
            #expect(Set(changes.map(\.id)).count == 4)
            #expect(changes.allSatisfy { $0.snapshotID != nil })
            #expect(try await index.appearanceWindows()["org.example.Returned"]?.isReinstallation == true)
        }
    }

    @Test func newlyFoundOldBundlesAndRoutineMetadataDoNotBecomeInstallEvents() async throws {
        try await withIndex { index in
            let old = app("Old", added: now - 20 * day)
            let system = app("System", path: "/System/Applications/System.app")
            let embedded = app("Embedded", path: "/Applications/Host.app/Contents/Applications/Embedded.app")
            let unknown = app("Unknown", version: nil)
            _ = try await index.recordInstalled([app("Anchor"), unknown], at: now - 3 * day)
            _ = try await index.recordInstalled([app("Anchor"), old, system, embedded,
                                                 app("Unknown", version: "1")], at: now - 2 * day)
            _ = try await index.recordInstalled([app("Anchor", size: 900_000_000), old, system, embedded,
                                                 app("Unknown", version: "1")], at: now - day)
            #expect(try await index.recentChanges(since: now - 7 * day, until: now).isEmpty)
        }
    }

    @Test func anOldAddedDateDoesNotSuppressARecordedReinstallEvent() async throws {
        try await withIndex { index in
            let anchor = app("Anchor")
            let returned = app("Returned", added: now - 20 * day)
            _ = try await index.recordInstalled([anchor, returned], at: now - 10 * day)
            _ = try await index.recordInstalled([anchor], at: now - 2 * day)
            _ = try await index.recordInstalled([anchor, returned], at: now - day)
            let changes = try await index.recentChanges(since: now - 7 * day, until: now)
            #expect(changes.map(\.kind) == [.appeared, .disappeared])
        }
    }

    private func app(_ name: String, version: String? = "1", added: Date? = nil,
                     path: String? = nil, size: Int64 = 1000) -> InstallObservation {
        InstallObservation(bundleID: "org.example." + name, name: name, version: version,
                           bundlePath: path ?? "/Applications/\(name).app", sizeBytes: size, addedAt: added)
    }

    private func withIndex(_ test: (Index) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try Index(dbManager: DatabaseManager(databaseURL: directory.appendingPathComponent("brim.sqlite")))
        try await test(index)
    }
}
