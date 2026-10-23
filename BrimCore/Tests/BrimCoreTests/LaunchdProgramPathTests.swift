import BrimCore
@testable import BrimScan
import XCTest

/// A launchd job whose program runs from inside the app's bundle is the
/// app's. The bundle is found in one place, by file name only (in
/// `/Applications` and `~/Applications`), and "inside" means the bundle path
/// and a slash.
final class LaunchdProgramPathTests: XCTestCase {
    private var rootURL: URL!
    private var root: FileSystemRoot!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launchd-program-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: rootURL)
    }

    private var userApplications: URL {
        root.url(for: .userLibrary).deletingLastPathComponent().appendingPathComponent("Applications")
    }

    /// A job whose label proves nothing, so only the program can.
    @discardableResult
    private func makeJob(label: String = "com.unrelated.label", program: String) throws -> URL {
        let directory = root.url(for: .userLaunchAgents)
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

    /// A per-user install's helper is proven by where it runs from.
    func testAPerUserInstallsHelperIsProvenByWhereItRunsFrom() async throws {
        let bundle = userApplications.appendingPathComponent("App.app")
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.app"],
            format: .xml, options: 0
        )
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let program = userApplications
            .appendingPathComponent("App.app/Contents/Library/LaunchServices/helper").path
        try makeJob(program: program)

        let found = try await claimed(by: app)
        XCTAssertEqual(
            found.first?.tier, .A,
            "A helper running from inside the per-user install of this application was not "
                + "proven, because only /Applications was looked in."
        )
    }

    /// `App.apple.app` is a different bundle that starts with the same letters.
    func testAProgramInABundleThatMerelyStartsWithTheSameNameIsNotProof() async throws {
        let program = root.url(for: .applications)
            .appendingPathComponent("App.apple.app/Contents/MacOS/helper").path
        try makeJob(program: program)

        let found = try await claimed(by: app)
        XCTAssertTrue(
            found.isEmpty,
            "A program inside App.apple.app was taken as proof that the job belongs to App."
        )
    }

    /// `Code.app` is not Visual Studio Code: locating the bundle must not use
    /// `CFBundleName`.
    func testAProgramInsideAnApplicationNamedLikeTheBundleNameIsNotProof() async throws {
        let program = root.url(for: .applications)
            .appendingPathComponent("Code.app/Contents/MacOS/helper").path
        try makeJob(program: program)

        let vsCode = Identity(
            bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", bundleName: "Code"
        )
        let found = try await claimed(by: vsCode)
        XCTAssertTrue(
            found.isEmpty,
            "A job running from Code.app, a different application, was claimed for Visual "
                + "Studio Code because its CFBundleName is \"Code\"."
        )
    }
}
