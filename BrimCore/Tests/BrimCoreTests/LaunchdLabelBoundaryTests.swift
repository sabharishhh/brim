import BrimCore
@testable import BrimScan
import XCTest

/// A launchd label that merely starts with an application's identifier is
/// not that application's job. The identifier has to end where a dot begins.
///
/// `LaunchdSource` proved a job belonged to an application when its label
/// started with the bundle identifier, with nothing required after it. Tier A
/// is ticked by default, and a ticked launchd job is unloaded and its property
/// list removed, so `com.example.app` could take `com.example.applet`'s
/// background job with it.
///
/// It was not hypothetical. On the Mac this was found on, the News
/// application claimed `com.apple.newsyslog`, the system's log rotation
/// daemon, and Clock claimed `com.apple.clocksyncd`, the daemon that keeps
/// the time right. Both are Apple's, protected, and out of Brim's reach, so
/// nothing was unloaded; the footprint view simply presented the system log
/// rotator as the News application's background service. The same rule ran
/// unguarded for every third-party application.
///
/// The rest of the codebase already draws the line at the dot:
/// `LocationInventorySource` matches `name.hasPrefix(bundleID + ".")`, and
/// `LocationInventorySourceTests` holds `com.example.applet` out of reach.
final class LaunchdLabelBoundaryTests: XCTestCase {
    private var rootURL: URL!
    private var root: FileSystemRoot!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launchd-boundary-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: rootURL)
    }

    @discardableResult
    private func makeJob(
        label: String,
        program: String = "/usr/local/libexec/helper",
        in directory: URL? = nil
    ) throws -> URL {
        let directory = directory ?? root.url(for: .systemLaunchDaemons)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(label).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "Program": program], format: .xml, options: 0
        )
        try data.write(to: url)
        return url
    }

    private func claimed(by identity: Identity) async throws -> [Evidence] {
        try await LaunchdSource().evidence(for: identity, in: root)
    }

    private var app: Identity {
        Identity(bundleID: "com.example.app", name: "App")
    }

    // MARK: - The boundary

    /// **`com.example.applet` is another product.** Sharing the first letters
    /// of an identifier is not sharing an identifier.
    func testAnotherProductsJobThatSharesTheIdentifierAsAPrefixIsNotClaimed() async throws {
        try makeJob(label: "com.example.applet.helper")

        let found = try await claimed(by: app)
        XCTAssertTrue(
            found.isEmpty,
            "com.example.app claimed com.example.applet.helper. That job belongs to another "
                + "product, and a Tier A claim unloads it along with this application."
        )
    }

    /// **The incident on the Mac this was found on.** The News application's
    /// identifier is `com.apple.news`, and the system's log rotation daemon is
    /// `com.apple.newsyslog`.
    func testTheNewsApplicationDoesNotClaimTheSystemLogRotator() async throws {
        let systemDaemons = rootURL.appendingPathComponent("System/Library/LaunchDaemons")
        try makeJob(label: "com.apple.newsyslog", program: "/usr/sbin/newsyslog", in: systemDaemons)

        let news = Identity(bundleID: "com.apple.news", name: "News")
        let found = try await claimed(by: news)
        XCTAssertTrue(
            found.isEmpty,
            "The News application claimed newsyslog as its own background service."
        )
    }

    /// A dash or no separator at all is still a different label. Kept strict
    /// on purpose; the program-path test below is what proves a helper whose
    /// developer did not use a dot.
    func testNoSeparatorAndADashAreNotABoundary() async throws {
        try makeJob(label: "com.example.appHelper")
        try makeJob(label: "com.example.app-helper")

        let found = try await claimed(by: app)
        XCTAssertTrue(
            found.isEmpty,
            "A label was claimed on the strength of starting with the identifier: "
                + found.map(\.url.lastPathComponent).joined(separator: ", ")
        )
    }

    // MARK: - What still counts

    /// The label equal to the identifier is the application's own job.
    func testALabelEqualToTheIdentifierIsStillDirect() async throws {
        try makeJob(label: "com.example.app")

        let found = try await claimed(by: app)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .A)
    }

    /// The identifier followed by a dot is the ordinary way a helper is named,
    /// and a privileged helper blessed by `SMJobBless` has to be named that way
    /// because its label is its own bundle identifier.
    func testTheIdentifierFollowedByADotIsStillDirect() async throws {
        try makeJob(label: "com.example.app.helper")

        let found = try await claimed(by: app)
        XCTAssertEqual(found.first?.tier, .A)
    }

    /// **Recall is not lost for a developer who skipped the dot.** A helper
    /// whose program lives inside the application's bundle is proven by where
    /// it runs from, whatever its label says.
    func testAHelperWithoutADotIsStillProvenByWhereItRunsFrom() async throws {
        let bundle = root.url(for: .applications).appendingPathComponent("App.app")
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.app"],
            format: .xml, options: 0
        )
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let program = bundle.appendingPathComponent(
            "Contents/Library/LaunchServices/com.example.appHelper"
        ).path
        try makeJob(label: "com.example.appHelper", program: program)

        let found = try await claimed(by: app)
        XCTAssertEqual(
            found.first?.tier, .A,
            "The program lives inside this application's bundle, which is proof on its own."
        )
    }
}
