@testable import BrimCore
@testable import BrimScan
import Foundation
import Testing

/// `pkgutil --expand` keeps a script that is a symbolic link. It must be
/// reported as a link, never followed: a link to a payload file read as
/// missing, and a link to a file on this Mac showed that file.
struct LinkedScriptTests {
    @Test func `a script that is a link is shown as one, and never followed`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scripts-\(UUID().uuidString)")
        let scripts = folder.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let elsewhere = folder.appendingPathComponent("private-notes.txt")
        try Data("not a script\n".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: scripts.appendingPathComponent("postinstall").path,
                                                   withDestinationPath: "/Library/Application Support/Demo/run.sh")
        try FileManager.default.createSymbolicLink(atPath: scripts.appendingPathComponent("preinstall").path,
                                                   withDestinationPath: elsewhere.path)
        let component = try #require(PackageComponent.parse("""
        <pkg-info identifier="com.example.demo" version="1" install-location="/" auth="root"></pkg-info>
        """))

        let found = InstallerReader.scripts(of: component, in: scripts)

        #expect(Set(found.map(\.name)) == ["preinstall", "postinstall"])
        #expect(found.allSatisfy { $0.text == nil && $0.linkDestination != nil })
        #expect(found.first { $0.name == "postinstall" }?.linkDestination == "/Library/Application Support/Demo/run.sh")
    }
}
