import Foundation
import XCTest

/// Provisions disposable targets in the **real** user domains so the pipeline
/// can be exercised against the machine Brim actually runs on.
///
/// Synthetic fixtures (T-0.3) remain where correctness is proven: they are
/// deterministic and independent of whoever's Mac is running them. This
/// fixture exists for the class of defect those cannot reach — TCC refusals,
/// real Trash semantics, live scanning of protected domains — each of which
/// has already shipped a bug that every synthetic test passed.
///
/// Because it writes to real locations, every path is namespaced and every
/// removal is checked against that namespace before it happens. The fixture
/// will refuse to delete anything it did not create.
struct RealEnvironmentFixture {

    /// Every path this fixture creates contains this marker, and nothing
    /// without it may be removed.
    static let marker = "BrimHarness-"

    /// Real-environment tests touch the user's own disk and are therefore
    /// opt-in: `BRIM_REAL_ENV=1 swift test`. CI and ordinary runs skip them.
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

    init() {
        self.runID = "\(Self.marker)\(UUID().uuidString.prefix(8))"
    }

    // MARK: - Real domains

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/Library/Caches` — low cost of error, so the planner disposes of it
    /// permanently.
    var cachesDomain: URL { home.appendingPathComponent("Library/Caches") }

    /// `~/Library/Application Support` — medium cost, so it is trashed and
    /// stays recoverable.
    var applicationSupportDomain: URL { home.appendingPathComponent("Library/Application Support") }

    // MARK: - Provisioning

    /// Creates a disposable directory with a sparse payload: it reports the
    /// requested logical size to the scanner while occupying almost no disk,
    /// so a harness run costs kilobytes rather than gigabytes.
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

    /// A bundle identifier carrying the harness marker, so every path derived
    /// from it lands inside the namespace the safety rail will allow.
    var harnessBundleID: String { "\(runID).deepuninstall" }

    /// Whether this process may create a sandbox container it can later
    /// remove.
    ///
    /// Creating `~/Library/Containers/<id>` makes `containermanagerd` adopt
    /// the directory and write protected metadata inside it. Removing that
    /// afterwards needs Full Disk Access, which the app has and a plain
    /// `swift test` run usually does not — so a harness without it would
    /// strand a directory in the user's Library on every run. Probed the same
    /// way the app probes, by attempting the operation that actually fails.
    static var canManageContainers: Bool {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let fd = open(trash.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Lays down the footprint a real application scatters across the user's
    /// Library — the whole point of a deep uninstall being that every one of
    /// these is found from the identity alone, with nothing named explicitly.
    ///
    /// - Returns: every path created, labelled by the mechanism that should
    ///   discover it, so a failure names what was missed.
    mutating func makeAppFootprint() throws -> [(label: String, url: URL)] {
        let id = harnessBundleID
        let library = home.appendingPathComponent("Library")

        var directories: [(String, URL)] = [
            ("Application Support", library.appendingPathComponent("Application Support/\(id)")),
            ("Caches", library.appendingPathComponent("Caches/\(id)")),
            ("HTTPStorages", library.appendingPathComponent("HTTPStorages/\(id)")),
            ("WebKit", library.appendingPathComponent("WebKit/\(id)")),
            ("Logs", library.appendingPathComponent("Logs/\(id)")),
            ("Application Scripts", library.appendingPathComponent("Application Scripts/\(id)")),
            ("Saved Application State", library.appendingPathComponent("Saved Application State/\(id).savedState"))
        ]

        if Self.canManageContainers {
            directories.append(("Containers", library.appendingPathComponent("Containers/\(id)")))
        }

        var made: [(String, URL)] = []
        for (label, url) in directories {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "harness\n".write(to: url.appendingPathComponent("data.bin"), atomically: true, encoding: .utf8)
            created.append(url)
            made.append((label, url))
        }

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

    /// A real application bundle in `~/Applications`, registered with Launch
    /// Services exactly as an installed app is.
    ///
    /// Needed because the registration is a separate surface from the files:
    /// deleting the bundle leaves the record behind, and only an actually
    /// registered bundle can prove the record is retracted.
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

    /// Removes everything this run created. Call from `tearDown`, and treat
    /// failures as test failures: a harness that leaks real directories into
    /// a user's Library is worse than one that fails.
    func cleanUp(file: StaticString = #filePath, line: UInt = #line) {
        for url in created where url.pathExtension == "app" {
            // Retract before removing: a harness that leaves a registration
            // behind is leaving exactly the leftover these tests exist to
            // catch. Harmless when the test already unregistered it.
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
                // Never silent: a harness that cannot clean up after itself
                // leaves real directories in the user's Library, and a
                // swallowed error here is how four of them accumulated.
                XCTFail(
                    "Harness could not remove \(url.path): \(error.localizedDescription). "
                    + "Remove it by hand before running again.",
                    file: file, line: line
                )
            }
        }
    }

    /// The only directories this harness may create in, and therefore the
    /// only ones it may remove from. `~/Applications` is here because a
    /// Launch Services registration can only be proven against a bundle that
    /// really is installed where applications go; the system-wide
    /// `/Applications` is deliberately absent.
    static var removableRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library").standardizedFileURL,
            home.appendingPathComponent("Applications").standardizedFileURL
        ]
    }

    /// The one rule that keeps this harness from being dangerous: a path is
    /// removable only if the harness marker appears in its own last component
    /// *and* it sits inside one of the roots above. Checking the whole path
    /// would let `~/BrimHarness-x/../../Documents` through, so the component
    /// is checked directly and the path is standardized first.
    static func isSafeToRemove(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.lastPathComponent.hasPrefix(marker) else { return false }
        return removableRoots.contains { standardized.path.hasPrefix($0.path + "/") }
    }
}
