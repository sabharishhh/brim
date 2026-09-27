@testable import BrimCore
@testable import BrimScan
import XCTest

/// The list and the plan give one answer to "can Brim remove this".
///
/// The incident: three broken links in `~/.local/bin`, the person's own
/// folder, were listed as removable, ticked, approved and then skipped with
/// `needs_helper_not_set_up`, twice in one day. The sweep asked the folder,
/// which is the right question. The plan asked the item with
/// `access(path, W_OK)`, which follows a link, found nothing at the far end
/// and fell through to "needs an administrator". The review then described
/// the person's home folder as a system folder, and the result said macOS
/// had not said why.
///
/// Moving something out of a folder needs write access to that folder.
/// A folder being moved also needs write access to itself, because its
/// `..` entry is rewritten. Checked on a real Mac: a read-only file and a
/// broken link move, a read-only folder does not.
final class OneRemovalRuleTests: XCTestCase {
    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("one-rule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("frozen").path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func planned(_ url: URL) async throws -> Capability? {
        let projector = FootprintProjector(engine: EvidenceEngine(sources: []))
        let evidence = Evidence(
            url: url, tier: .A, mechanism: "DirectTarget", humanSentence: "Named for removal"
        )
        let footprint = try await projector.project(
            identity: Identity(bundleID: nil, name: "Leftovers"),
            in: FileSystemRoot(rootURL: URL(fileURLWithPath: "/")),
            explicitEvidence: [evidence]
        )
        return footprint.items.first?.capability
    }

    func testABrokenLinkInYourOwnFolderIsPlannedAsRemovable() async throws {
        let directory = try scratch()
        let link = directory.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: directory.appendingPathComponent("gone/node").path
        )

        let capability = try await planned(link)
        XCTAssertEqual(capability, .ok, "A link into a folder that is gone is still yours to move")
        XCTAssertEqual(capability, RemovalCapability.forDeleting(link.path))
    }

    func testAReadOnlyFileInYourOwnFolderIsPlannedAsRemovable() async throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent("com.example.plist")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)

        let capability = try await planned(file)
        XCTAssertEqual(capability, .ok)
        XCTAssertEqual(capability, RemovalCapability.forDeleting(file.path))
    }

    func testAReadOnlyFolderIsNotOfferedAsRemovable() async throws {
        let directory = try scratch()
        let frozen = directory.appendingPathComponent("frozen")
        try FileManager.default.createDirectory(at: frozen, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: frozen.path)

        XCTAssertNotEqual(
            RemovalCapability.forDeleting(frozen.path), .ok,
            "Moving a folder rewrites its own `..` entry, so a read-only folder refuses"
        )
        let capability = try await planned(frozen)
        XCTAssertEqual(capability, RemovalCapability.forDeleting(frozen.path))
    }
}
