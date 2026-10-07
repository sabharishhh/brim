@testable import BrimOps
import Foundation
import Testing

/// Brim puts an app into Applications only if it is still the app the
/// preview showed, and never over another. Its quarantine is removed only
/// once Gatekeeper accepts it, so it opens from Applications rather than a
/// translocated copy; an app Gatekeeper refuses keeps it.
struct AppInstallerTests {
    private struct Fixture {
        let folder: URL
        let applications: URL
        let app: URL

        init(identifier: String = "com.vendorco.demo") throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-install-\(UUID().uuidString)")
            applications = folder.appendingPathComponent("Applications")
            app = folder.appendingPathComponent("Downloads/Demo.app")
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundleName": "Demo", "CFBundleExecutable": "Demo"
            ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Demo"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// An unsigned fixture is never accepted, so macOS still checks it.
    @Test func `an app Gatekeeper does not accept keeps its quarantine`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let quarantine = "0083;66f00000;Safari;"
        _ = quarantine.withCString { setxattr(fixture.app.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        let installed = try AppInstaller.install(from: fixture.app, identifier: "com.vendorco.demo", trusted: false,
                                                 applications: fixture.applications)
        #expect(installed.path == fixture.applications.appendingPathComponent("Demo.app").path)
        #expect(UpdateInstaller.identifier(of: installed) == "com.vendorco.demo")
        #expect(getxattr(installed.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        // A copy: the installer is still where it was, for the person to
        // keep or move to the Trash.
        #expect(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    /// Figma's installer app, copied with its quarantine, ran from a
    /// translocated copy, could not replace itself and asked to be moved
    /// to Applications.
    @Test func `an app Gatekeeper accepts loses its quarantine, inside too`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let quarantine = "0083;66f00000;Safari;"
        for path in [fixture.app.path, fixture.app.appendingPathComponent("Contents/MacOS/Demo").path] {
            _ = quarantine.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }
        let installed = try AppInstaller.install(from: fixture.app, identifier: "com.vendorco.demo", trusted: true,
                                                 applications: fixture.applications, accepts: { _ in true })
        #expect(getxattr(installed.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        let executable = installed.appendingPathComponent("Contents/MacOS/Demo").path
        #expect(getxattr(executable, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        // The installer itself is not touched.
        #expect(getxattr(fixture.app.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }

    @Test func `an app that changed since the preview is refused`() throws {
        let fixture = try Fixture(identifier: "com.someone.else")
        defer { fixture.remove() }
        #expect(throws: AppInstaller.Failure.differentApplication) {
            try AppInstaller.install(from: fixture.app, identifier: "com.vendorco.demo", trusted: false,
                                     applications: fixture.applications)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.applications.path).isEmpty)
    }

    @Test func `nothing is installed over an app of the same name`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.applications.appendingPathComponent("Demo.app"),
                                                withIntermediateDirectories: true)
        #expect(throws: AppInstaller.Failure.exists("Demo")) {
            try AppInstaller.install(from: fixture.app, identifier: "com.vendorco.demo", trusted: false,
                                     applications: fixture.applications)
        }
    }

    /// The preview said Gatekeeper accepted it, so the copy must still be
    /// accepted. An unsigned fixture never is.
    @Test func `a trusted install is checked by Gatekeeper again`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: AppInstaller.Failure.gatekeeper) {
            try AppInstaller.install(from: fixture.app, identifier: "com.vendorco.demo", trusted: true,
                                     applications: fixture.applications)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.applications.path).isEmpty)
    }
}
