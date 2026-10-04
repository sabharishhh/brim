import BrimCore
import BrimScan
import Darwin
import Foundation
import Testing

struct RemnantOwnershipFailureTests {
    @Test func failedRegistrationLookupOverridesOlderAbsenceRecords() {
        let identifier = "org.example.orphan"
        let search = OwnershipSearch(
            installedBundleIDs: [], installedNames: [], receiptBundleIDs: [identifier],
            previouslyRemovedBundleIDs: [identifier], staleRegistrationOwners: [identifier: "Old missing job"],
            launchServicesLookup: { _ in throw CocoaError(.fileReadNoPermission) }
        )
        let verdict = search.ownership(of: identifier)
        guard case let .unknown(evidence) = verdict else {
            Issue.record("A failed owner lookup must remain uncertain.")
            return
        }
        #expect(verdict.category == .unclaimed)
        #expect(evidence.contains("Launch Services could not check"))
        #expect(evidence.contains(identifier))
    }

    @Test func installedOwnerProtectsDataDespiteRegistrationLookupFailure() {
        let search = OwnershipSearch(
            installedBundleIDs: ["org.example.installed"], installedNames: [], receiptBundleIDs: [],
            previouslyRemovedBundleIDs: [], launchServicesLookup: { _ in
                throw CocoaError(.fileReadNoPermission)
            }
        )
        #expect(search.ownership(of: "org.example.installed").category == nil)
    }

    @Test func failedNameLookupCannotRestoreOrphanStatusFromHistoryOrHomebrew() async throws {
        let fixture = try RemnantOwnershipFailureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let target = try fixture.dataFolder(in: .userApplicationSupport, name: "Orphan")
        let scanner = LeftoversScanner(
            root: fixture.root, launchServicesLookup: { name in
                if name == "Orphan" {
                    throw CocoaError(.fileReadNoPermission)
                }
                return []
            }, homebrewOrphans: ["orphan"], hasFullDiskAccess: false
        )
        let leftovers = try await scanner.scanLeftovers(
            knownPastBundleIDs: ["org.example.orphan"], knownNames: ["org.example.orphan": "Orphan"]
        )
        let item = try #require(
            leftovers.first { $0.url == target },
            "Expected \(target.absoluteString); found \(leftovers.map(\.url.absoluteString))"
        )
        #expect(item.category == .unclaimed)
        #expect(item.evidence.contains("Launch Services could not check"))
    }

    @Test func failedLookupCannotTurnContainerMetadataIntoProofOfAbsence() async throws {
        let fixture = try RemnantOwnershipFailureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let target = try fixture.dataFolder(in: .userContainers, name: UUID().uuidString)
        let owner = "org.example.orphan"
        let status = Array(owner.utf8).withUnsafeBytes {
            setxattr(target.path, "com.apple.containermanager.identifier", $0.baseAddress, $0.count, 0, 0)
        }
        try #require(status == 0)
        let scanner = LeftoversScanner(root: fixture.root, launchServicesLookup: { _ in
            throw CocoaError(.fileReadNoPermission)
        }, hasFullDiskAccess: false)
        let leftovers = try await scanner.scanLeftovers()
        let item = try #require(
            leftovers.first { $0.url == target },
            "Expected \(target.absoluteString); found \(leftovers.map(\.url.absoluteString))"
        )
        #expect(item.category == .unclaimed)
        #expect(item.evidence.contains("Launch Services could not check"))
    }
}

private struct RemnantOwnershipFailureFixture {
    let folder: URL
    var root: FileSystemRoot {
        FileSystemRoot(rootURL: folder, userName: "tester")
    }

    init() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func dataFolder(in domain: FileSystemRoot.Domain, name: String) throws -> URL {
        let target = root.url(for: domain).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: target.appendingPathComponent("data"))
        // Enumeration returns physical paths, including /private/var for
        // macOS temporary directories exposed through the /var link.
        let physicalPath = try #require(realpath(target.path, nil))
        defer { free(physicalPath) }
        return URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
    }
}
