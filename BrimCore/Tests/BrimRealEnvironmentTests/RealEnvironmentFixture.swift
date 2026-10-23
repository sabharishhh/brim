import Foundation
import XCTest
import BrimOps

/// Disposable targets in the real user domains, for defects synthetic
/// fixtures cannot reach: TCC refusals, real Trash semantics and live
/// scanning of protected domains. Every path is namespaced, and the fixture
/// refuses to delete anything it did not create.
struct RealEnvironmentFixture {

    /// Every path this fixture creates contains this marker, and nothing
    /// without it may be removed.
    static let marker = "BrimHarness-"

    /// Opt-in, because these touch the user's own disk:
    /// `BRIM_REAL_ENV=1 swift test`.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BRIM_REAL_ENV"] == "1"
    }

    /// Skips the calling test unless real-environment runs were requested.
    static func requireEnabled(
        _ test: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard isEnabled else {
            throw XCTSkip(
                "Real-environment test. Run with BRIM_REAL_ENV=1 to exercise the actual machine.",
                file: file, line: line
            )
        }
    }

    let runID: String
    private(set) var created: [URL] = []
    /// Whether this run put a bundle into Launch Services, and therefore has
    /// a registration to clean up afterwards.
    private var registeredAnyBundle = false

    init() {
        self.runID = "\(Self.marker)\(UUID().uuidString.prefix(8))"
    }

    // MARK: - Real domains

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Low cost of error, so the planner deletes permanently.
    var cachesDomain: URL { home.appendingPathComponent("Library/Caches") }

    /// Medium cost, so it is trashed and stays recoverable.
    var applicationSupportDomain: URL { home.appendingPathComponent("Library/Application Support") }

    // MARK: - Provisioning

    /// A sparse payload that reports the requested logical size while occupying
    /// almost no disk.
    mutating func makeTarget(
        in domain: URL,
        name: String,
        logicalBytes: Int64 = 64 * 1024 * 1024
    ) throws -> URL {
        let url = domain.appendingPathComponent("\(runID)-\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let blob = url.appendingPathComponent("payload.bin")
        FileManager.default.createFile(atPath: blob.path, contents: nil)
        let handle = try FileHandle(forWritingTo: blob)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(logicalBytes))

        try "Disposable Brim harness target. Safe to delete.\n"
            .write(to: url.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        created.append(url)
        return url
    }

    /// Carries the harness marker, so every derived path is inside the
    /// namespace the safety rail allows.
    var harnessBundleID: String { "\(runID).deepuninstall" }

    /// The harness never creates sandbox containers. `containermanagerd` writes
    /// a metadata file into `~/Library/Containers/<id>` that nothing but the
    /// owning daemon can unlink, not Full Disk Access and not root, and probing
    /// whether removal works would mean creating one. Containers belong to the
    /// synthetic fixtures.

    /// The footprint a real application scatters across Library, to be found
    /// from the identity alone.
    ///
    /// - Returns: every path created, labelled by the mechanism that should
    ///   discover it, so a failure names what was missed.
    mutating func makeAppFootprint() throws -> [(label: String, url: URL)] {
        let id = harnessBundleID
        let library = home.appendingPathComponent("Library")

        let directories: [(String, URL)] = [
            ("Application Support", library.appendingPathComponent("Application Support/\(id)")),
            ("Caches", library.appendingPathComponent("Caches/\(id)")),
            ("HTTPStorages", library.appendingPathComponent("HTTPStorages/\(id)")),
            ("WebKit", library.appendingPathComponent("WebKit/\(id)")),
            ("Logs", library.appendingPathComponent("Logs/\(id)")),
            ("Application Scripts", library.appendingPathComponent("Application Scripts/\(id)")),
            ("Saved Application State", library.appendingPathComponent("Saved Application State/\(id).savedState"))
        ]

        var made: [(String, URL)] = []
        for (label, url) in directories {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "harness\n".write(to: url.appendingPathComponent("data.bin"), atomically: true, encoding: .utf8)
            created.append(url)
            made.append((label, url))
        }

        // The LaunchAgents plist makes macOS post a background activity
        // notification naming "(null)", since it carries only a Label. That is
        // expected: this tests discovery, not running.
        let files: [(String, URL)] = [
            ("Preferences", library.appendingPathComponent("Preferences/\(id).plist")),
            ("LaunchAgents", library.appendingPathComponent("LaunchAgents/\(id).plist"))
        ]
        for (label, url) in files {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Label</key><string>\(id)</string></dict></plist>
            """
            try plist.write(to: url, atomically: true, encoding: .utf8)
            created.append(url)
            made.append((label, url))
        }

        return made
    }

    /// A bundle in `~/Applications` registered with Launch Services, because
    /// only a registered bundle can prove the record is retracted.
    mutating func makeRegisteredAppBundle(suffix: String = "") throws -> URL {
        let applications = home.appendingPathComponent("Applications")
        let bundle = applications.appendingPathComponent("\(runID)\(suffix).app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        created.append(bundle)

        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>\(harnessBundleID)</string>
          <key>CFBundleName</key><string>\(runID)</string>
          <key>CFBundleExecutable</key><string>harness</string>
          <key>CFBundleShortVersionString</key><string>1.0</string>
        </dict></plist>
        """
        try info.write(
            to: bundle.appendingPathComponent("Contents/Info.plist"),
            atomically: true, encoding: .utf8
        )
        let executable = macOS.appendingPathComponent("harness")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try Self.lsregister(["-f", bundle.path])
        registeredAnyBundle = true
        return bundle
    }

    /// Runs `lsregister` with fixed arguments. Used only by the harness, to
    /// put a bundle into the state a real installation leaves it in.
    static func lsregister(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks"
            + "/LaunchServices.framework/Versions/A/Support/lsregister")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - Teardown

    /// Removes everything this run created. Failures are test failures: a
    /// harness that leaks into a user's Library is worse than one that fails.
    func cleanUp(file: StaticString = #filePath, line: UInt = #line) {
        // Anything trashed stays in the user's Trash, and Launch Services keeps
        // re-registering a `.app` there. The harness cannot list `~/.Trash` without
        // Full Disk Access, but can remove a path it names, and each run's names
        // are unique.
        let trash = home.appendingPathComponent(".Trash")
        for url in created {
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.marker) else { continue }
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
        }

        // Then retract any registration left, best effort: Launch Services prunes
        // on its own schedule once the files are gone.
        if registeredAnyBundle {
            for url in LaunchServicesRegistration
                .registeredApplicationURLs(forBundleID: harnessBundleID) {
                try? Self.lsregister(["-u", url.path])
            }
        }
        for url in created where url.pathExtension == "app" {
            try? Self.lsregister(["-u", url.path])
        }

        for url in created {
            guard Self.isSafeToRemove(url) else {
                XCTFail("Refusing to remove \(url.path): outside the harness namespace", file: file, line: line)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // Never silent: a swallowed error leaves real directories behind.
                XCTFail(
                    "Harness could not remove \(url.path): \(error.localizedDescription). "
                    + "Remove it by hand before running again.",
                    file: file, line: line
                )
            }
        }
    }

    /// The only directories the harness may create in or remove from.
    /// `~/Applications` is here so a registration can be proven; `/Applications`
    /// is deliberately absent.
    static var removableRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library").standardizedFileURL,
            home.appendingPathComponent("Applications").standardizedFileURL
        ]
    }

    /// Removable only if the marker is in the last component and the path sits
    /// inside one of the roots. Checking the whole path would let
    /// `~/BrimHarness-x/../../Documents` through, so the path is standardized
    /// and the component checked directly.
    static func isSafeToRemove(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.lastPathComponent.hasPrefix(marker) else { return false }
        return removableRoots.contains { standardized.path.hasPrefix($0.path + "/") }
    }
}
