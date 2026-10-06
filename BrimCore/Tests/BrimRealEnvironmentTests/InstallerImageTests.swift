@testable import BrimOps
@testable import BrimScan
import Foundation
import XCTest

/// A disk image is mounted read-only and hidden, read, and ejected on every
/// way out. Real environment only: it attaches an image to this Mac.
final class InstallerImageTests: XCTestCase {
    func testADiskImageIsReadAndEjected() throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(RealEnvironmentFixture.marker)image-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source")
        let contents = source.appendingPathComponent("Demo.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.brimharness.demo", "CFBundleName": "Demo",
            "CFBundleShortVersionString": "2.0", "CFBundleExecutable": "Demo", "CFBundlePackageType": "APPL",
            "NSMicrophoneUsageDescription": "Calls"
        ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/Demo"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
        let image = folder.appendingPathComponent("Demo.dmg")
        let created = ToolOutput.run("/usr/bin/hdiutil", [
            "create", "-quiet", "-srcfolder", source.path, "-volname", "Demo", "-format", "UDZO", image.path
        ], timeout: 120)
        XCTAssertEqual(created?.status, 0)

        let before = ToolOutput.run("/usr/bin/hdiutil", ["info"])?.output ?? ""
        let preview = try InstallerReader(installed: [:]).read(image)
        XCTAssertEqual(preview.kind, .diskImage)
        XCTAssertEqual(preview.contents.map(\.name), ["Demo"])
        XCTAssertEqual(preview.contents.first?.permissions, ["Microphone"])
        XCTAssertEqual(preview.contents.first?.apps.first?.version, "2.0")
        // The image is gone from the list of attached images once read.
        let after = ToolOutput.run("/usr/bin/hdiutil", ["info"])?.output ?? ""
        XCTAssertFalse(after.contains(image.path), "The disk image was left attached.")
        XCTAssertEqual(before.components(separatedBy: "image-path").count,
                       after.components(separatedBy: "image-path").count)
    }

    /// Installing from an image copies the app out and leaves the image
    /// detached, as reading one does.
    func testAnAppIsInstalledFromADiskImage() throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(RealEnvironmentFixture.marker)install-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = folder.appendingPathComponent("source/Demo.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.brimharness.demo", "CFBundleExecutable": "Demo",
            "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/Demo"))
        let image = folder.appendingPathComponent("Demo.dmg")
        XCTAssertEqual(ToolOutput.run("/usr/bin/hdiutil", [
            "create", "-quiet", "-srcfolder", folder.appendingPathComponent("source").path, "-volname", "Demo",
            "-format", "UDZO", image.path
        ], timeout: 120)?.status, 0)
        let applications = folder.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        let installed = try AppInstaller.install(from: image, identifier: "com.example.brimharness.demo",
                                                 trusted: false, applications: applications)
        XCTAssertEqual(installed.lastPathComponent, "Demo.app")
        let info = installed.appendingPathComponent("Contents/Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path))
        let attached = ToolOutput.run("/usr/bin/hdiutil", ["info"])?.output ?? ""
        XCTAssertFalse(attached.contains(image.path), "The disk image was left attached.")
    }
}
