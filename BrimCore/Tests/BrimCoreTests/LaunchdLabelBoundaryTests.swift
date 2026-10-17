import BrimCore
@testable import BrimScan
import XCTest

/// A launchd label that merely starts with an app's identifier is not that
/// app's job; the identifier must end where a dot begins. A bare prefix
/// made `com.apple.news` claim `com.apple.newsyslog`, and a ticked job is
/// unloaded.
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

    /// `com.example.applet` is another product.
    func testAnotherProductsJobThatSharesTheIdentifierAsAPrefixIsNotClaimed() async throws {
        try makeJob(label: "com.example.applet.helper")

        let found = try await claimed(by: app)
        XCTAssertTrue(
            found.isEmpty,
            "com.example.app claimed com.example.applet.helper. That job belongs to another "
                + "product, and a Tier A claim unloads it along with this application."
        )
    }

    /// `com.apple.news` does not claim `com.apple.newsyslog`.
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

    /// A dash or no separator is a different label. A helper without a dot is
    /// proven by its program path instead.
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

    /// The identifier and a dot is how helpers are named, and how `SMJobBless`
    /// requires a privileged helper's label to be.
    func testTheIdentifierFollowedByADotIsStillDirect() async throws {
        try makeJob(label: "com.example.app.helper")

        let found = try await claimed(by: app)
        XCTAssertEqual(found.first?.tier, .A)
    }

    /// A helper whose program runs from inside the bundle is proven by where it
    /// runs, whatever its label.
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
