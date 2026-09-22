import XCTest
import BrimCore
@testable import BrimScan

/// A record that names user documents is still a record. Brim removes the
/// record. Brim never touches what it points at.
///
/// `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/<identifier>.sfl4`
/// is keyed exactly on the bundle identifier and was invisible on all six
/// applications measured on this Mac, so it belongs in the inventory. It is
/// also a list of the person's own files: the last twenty documents they
/// opened, by full path, anywhere on the disk.
///
/// That makes it the one location in this task where finding more and
/// deleting more are not the same thing, and it is one careless line apart.
/// A scanner that reads the record to "find what else belongs to this
/// application" walks straight out of application storage and into
/// `~/Documents`. Security-scoped bookmarks and autosave records have the
/// same shape and the same rule.
///
/// These tests were written before the location was added, which is the only
/// order in which a guard means anything.
final class RecordedPathTests: XCTestCase {

    private var rootURL: URL!
    private var root: FileSystemRoot!

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recorded-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// A recent-documents record naming a document the person owns, shaped
    /// the way a real one is: a property list with the path inside it, so a
    /// naive reader would find the path without much trying.
    @discardableResult
    private func makeRecentDocumentsRecord(
        for bundleID: String, naming document: URL
    ) throws -> URL {
        let directory = root.url(for: .userApplicationSupport)
            .appendingPathComponent("com.apple.sharedfilelist")
            .appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = directory.appendingPathComponent("\(bundleID).sfl4")
        let archive: [String: Any] = [
            "items": [["Name": document.lastPathComponent, "URL": document.path]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: archive, format: .binary, options: 0
        )
        try data.write(to: record)
        return record
    }

    private func makeDocument(named name: String) throws -> URL {
        let documents = rootURL.appendingPathComponent("Users/tester/Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let document = documents.appendingPathComponent(name)
        try Data("the person's own work".utf8).write(to: document)
        return document
    }

    // MARK: - The guard

    /// **The line this must not cross.** The record goes, the document it
    /// names does not, and nothing in between gets a vote.
    func testTheDocumentARecordNamesIsNeverAScanTarget() async throws {
        let document = try makeDocument(named: "Thesis.md")
        try makeRecentDocumentsRecord(for: "com.example.app", naming: document)

        let identity = Identity(bundleID: "com.example.app", name: "App")
        let engine = EvidenceEngine(sources: [
            LocationInventorySource(budget: { .unlimited }),
            BundleIdentifierComponentSource(),
            BundleIdentifierStateSource(),
        ])
        let discovered = try await engine.discover(identity: identity, in: root)
        let paths = Set(discovered.evidence.map { $0.url.standardizedFileURL.path })

        XCTAssertFalse(
            paths.contains(document.standardizedFileURL.path),
            "A document the person opened once is in this application's footprint. "
            + "The recent-documents record names it; that is not the same as owning it, "
            + "and a Markdown file outlives every application that ever opened it."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: document.path),
            "Scanning removed the document outright."
        )
    }

    /// Nothing anywhere under `~/Documents` is reachable, whatever named it.
    /// The location test in the plan is the first line of defence: Brim only
    /// goes where the inventory names, and the inventory names application
    /// storage.
    func testNoLocationInTheInventoryReachesTheDocumentsFolder() {
        let documents = root.url(for: .userLibrary)
            .deletingLastPathComponent()
            .appendingPathComponent("Documents").standardizedFileURL.path
        for location in LocationInventory.standard.locations {
            let path = root.url(for: location.domain).standardizedFileURL.path
            XCTAssertFalse(
                path == documents || path.hasPrefix(documents + "/"),
                "\(location.domain) reaches into the person's Documents folder."
            )
        }
    }

    /// The structural half. Reading a recorded path is not wrong in itself;
    /// turning one into something Brim acts on is. Nothing in the shipping
    /// sources resolves bookmark data at all, and a change that starts to
    /// should have to come past this test and say why.
    func testNothingResolvesARecordedBookmarkIntoAPath() throws {
        let banned = [
            "URLByResolvingBookmarkData",
            "resolvingBookmarkData",
            "URL(resolvingBookmarkData",
        ]
        for file in Self.productSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in banned {
                XCTAssertFalse(
                    text.contains(needle),
                    "\(file.lastPathComponent) resolves a bookmark. A bookmark is an index "
                    + "into the person's own files, recorded because they chose that file in "
                    + "a save panel. Brim removes the record, never what it points at."
                )
            }
        }
    }

    private static func productSources() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var files: [URL] = []
        for directory in ["BrimCore/Sources", "Brim"] {
            let url = root.appendingPathComponent(directory)
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let entry = walker?.nextObject() as? URL {
                if entry.pathExtension == "swift" { files.append(entry) }
            }
        }
        return files
    }

    // MARK: - And the record itself

    /// Having established what must not happen: the record is this
    /// application's and has to be found. It is keyed exactly on the bundle
    /// identifier, and it was missing from all six footprints measured.
    func testTheRecentDocumentsRecordIsFound() throws {
        let document = try makeDocument(named: "Thesis.md")
        let record = try makeRecentDocumentsRecord(for: "com.example.app", naming: document)

        let identity = Identity(bundleID: "com.example.app", name: "App")
        let found = LocationInventorySource(budget: { .unlimited })
            .findings(for: identity, in: root).evidence

        XCTAssertTrue(
            found.contains { $0.url.standardizedFileURL == record.standardizedFileURL },
            "The recent-documents record is keyed on this application's identifier and was "
            + "not found."
        )
    }

    /// Somebody else's record stays somebody else's.
    func testAnotherApplicationsRecordIsLeftAlone() throws {
        let document = try makeDocument(named: "Thesis.md")
        let mine = try makeRecentDocumentsRecord(for: "com.example.app", naming: document)
        let theirs = try makeRecentDocumentsRecord(for: "com.other.app", naming: document)

        let identity = Identity(bundleID: "com.example.app", name: "App")
        let paths = Set(
            LocationInventorySource(budget: { .unlimited })
                .findings(for: identity, in: root).evidence
                .map { $0.url.standardizedFileURL.path }
        )

        XCTAssertTrue(paths.contains(mine.standardizedFileURL.path))
        XCTAssertFalse(
            paths.contains(theirs.standardizedFileURL.path),
            "com.other.app's recent documents are not com.example.app's."
        )
    }
}
