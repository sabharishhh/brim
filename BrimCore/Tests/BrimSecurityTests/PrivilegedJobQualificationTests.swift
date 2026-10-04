@testable import BrimPrivileged
import Foundation
import Testing

struct PrivilegedJobQualificationTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func malformedProgramFieldsDoNotAuthorizeJobRemoval(_ variant: Int) throws {
        // A failed cast formerly became an empty job and could authorize
        // stopping a loaded service whose replacement plist was malformed.
        let fields: [[String: Any]] = [
            ["Program": 42], ["Program": ""], ["ProgramArguments": "helper"],
            ["ProgramArguments": [42]], ["ProgramArguments": [String]()],
            ["Program": "/missing\0/present"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: fields[variant], format: .binary, options: 0)
        #expect(!PrivilegedJobRemoval.isDefunct(plist: data, programExists: { _ in false }))
    }

    @Test(arguments: ["Program", "ProgramArguments"])
    func loadedProgramMustMatchTheReviewedDeclaration(_ key: String) throws {
        let fixture = try PrivilegedJobQualificationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let missing = fixture.folder.appendingPathComponent("missing-helper").path
        let working = fixture.folder.appendingPathComponent("working-helper")
        try Data("helper".utf8).write(to: working)
        var dictionary: [String: Any] = ["Label": "org.example.helper"]
        if key == "Program" {
            dictionary[key] = missing
        } else {
            dictionary[key] = [missing, "--daemon"]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        let path = fixture.folder.appendingPathComponent("job.plist").path
        #expect(PrivilegedJobRemoval.isDefunct(plist: data, programExists: {
            FileManager.default.fileExists(atPath: $0)
        }))
        #expect(PrivilegedJobRemoval.loadedJobMatchesReviewedDefinition(
            "path = \(path)\nprogram = \(missing)", reviewedPath: path, reviewedPlist: data
        ))
        #expect(!PrivilegedJobRemoval.loadedJobMatchesReviewedDefinition(
            "path = \(path)\nprogram = \(working.path)", reviewedPath: path, reviewedPlist: data
        ))
    }

    @Test func anEmptyDeclarationCannotAuthorizeStoppingALoadedProgram() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "org.example.helper"], format: .binary, options: 0
        )
        #expect(PrivilegedJobRemoval.isDefunct(plist: data, programExists: { _ in false }))
        #expect(!PrivilegedJobRemoval.loadedJobMatchesReviewedDefinition(
            "path = /fixture/job.plist\nprogram = /fixture/working-helper",
            reviewedPath: "/fixture/job.plist", reviewedPlist: data
        ))
    }

    @Test func changedDeclarationIsRefusedAtThePreStopCheck() throws {
        let fixture = try PrivilegedJobQualificationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let target = fixture.folder.appendingPathComponent("job.plist")
        try Data("reviewed".utf8).write(to: target)
        let parent = open(fixture.folder.path, O_RDONLY | O_DIRECTORY)
        try #require(parent >= 0)
        defer { close(parent) }
        var reviewed = stat()
        try #require(fstatat(parent, "job.plist", &reviewed, AT_SYMLINK_NOFOLLOW) == 0)
        _ = try PrivilegedJobRemoval.readReviewedPlist(parent: parent, name: "job.plist", reviewed: reviewed)
        try PrivilegedJobRemoval.validateReviewedEntry(parent: parent, name: "job.plist", reviewed: reviewed)
        try Data("changed after the runtime lookup".utf8).write(to: target)
        #expect(throws: PrivilegedJobRemoval.Refusal.unreadable) {
            try PrivilegedJobRemoval.validateReviewedEntry(parent: parent, name: "job.plist", reviewed: reviewed)
        }
    }

    @Test func swappedJobCannotSupplyContentsForTheReviewedEntry() throws {
        let fixture = try PrivilegedJobQualificationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let target = fixture.folder.appendingPathComponent("job.plist")
        try Data("original".utf8).write(to: target)
        let parent = open(fixture.folder.path, O_RDONLY | O_DIRECTORY)
        try #require(parent >= 0)
        defer { close(parent) }
        var reviewed = stat()
        try #require(fstatat(parent, "job.plist", &reviewed, AT_SYMLINK_NOFOLLOW) == 0)
        try FileManager.default.moveItem(at: target, to: fixture.folder.appendingPathComponent("original.plist"))
        try Data("replacement".utf8).write(to: target)
        #expect(throws: PrivilegedJobRemoval.Refusal.unreadable) {
            try PrivilegedJobRemoval.readReviewedPlist(parent: parent, name: "job.plist", reviewed: reviewed)
        }
    }

    @Test(arguments: [false, true])
    func reviewedFileReadIsBoundedAndPreservesOrdinaryContents(_ oversized: Bool) throws {
        let fixture = try PrivilegedJobQualificationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let contents = Data(repeating: 1, count: oversized ? 64 * 1024 + 1 : 128)
        try contents.write(to: fixture.folder.appendingPathComponent("job.plist"))
        let parent = open(fixture.folder.path, O_RDONLY | O_DIRECTORY)
        try #require(parent >= 0)
        defer { close(parent) }
        var reviewed = stat()
        try #require(fstatat(parent, "job.plist", &reviewed, AT_SYMLINK_NOFOLLOW) == 0)
        if oversized {
            #expect(throws: PrivilegedJobRemoval.Refusal.unreadable) {
                try PrivilegedJobRemoval.readReviewedPlist(parent: parent, name: "job.plist", reviewed: reviewed)
            }
        } else {
            #expect(try PrivilegedJobRemoval.readReviewedPlist(parent: parent, name: "job.plist", reviewed: reviewed)
                == contents)
        }
    }
}

private struct PrivilegedJobQualificationFixture {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
