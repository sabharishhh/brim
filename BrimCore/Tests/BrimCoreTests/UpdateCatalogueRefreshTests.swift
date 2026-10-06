import BrimCore
@testable import BrimScan
import XCTest

/// ChatGPT offered a release while Check Again compared yesterday's catalogue
/// with the installed version. A requested check must ask the publisher again.
final class UpdateCatalogueRefreshTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("catalogue-refresh-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func catalogue(_ version: String) -> Data {
        Data("""
        [{"token":"chatgpt","version":"\(version)","url":"https://example.com/ChatGPT.zip",
          "sha256":"no_check","artifacts":[{"app":["ChatGPT.app"]}]}]
        """.utf8)
    }

    private func seed(_ data: Data) throws {
        try data.write(to: folder.appendingPathComponent("cask.json"))
        try "\"yesterday\"".write(to: folder.appendingPathComponent("cask.etag"),
                                  atomically: true, encoding: .utf8)
    }

    private func app() throws -> InstalledApplication {
        let url = folder.appendingPathComponent("ChatGPT.app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let version = "26.930.41038"
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.catalogue-chat", "CFBundleShortVersionString": version,
            "CFBundleVersion": "13022"
        ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return InstalledApplication(
            identity: Identity(bundleID: "com.example.catalogue-chat", name: "ChatGPT", version: version),
            url: url, bundleSizeBytes: 1, isSystemProtected: false
        )
    }

    func testARequestedCheckFindsAReleaseEvenWhenTheCachedCatalogueIsFresh() async throws {
        try seed(catalogue("26.930.41038"))
        let server = CatalogueServer(body: catalogue("26.930.51102"))
        let finder = UpdateFinder(fetch: { try await server.fetch($0) },
                                  catalogueDirectory: folder, installedCasks: [])
        let check = try await finder.check([app()])
        XCTAssertEqual(check.updates.first?.latestVersion, "26.930.51102")
        XCTAssertEqual(check.checked, 1)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-None-Match"), "\"yesterday\"")
        XCTAssertEqual(requests.first?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testNotModifiedUsesTheCatalogueThePublisherJustConfirmed() async throws {
        try seed(catalogue("26.930.51102"))
        let server = CatalogueServer(status: 304)
        let cache = CatalogueCache(directory: folder, fetch: { try await server.fetch($0) })
        let result = await cache.casks()
        XCTAssertEqual(result?.first?.displayVersion, "26.930.51102")
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-None-Match"), "\"yesterday\"")
    }

    func testReusingTheFinderStartsANewCatalogueValidation() async throws {
        let application = try app()
        let server = CatalogueServer(body: catalogue("26.930.41038"))
        let finder = UpdateFinder(fetch: { try await server.fetch($0) },
                                  catalogueDirectory: folder, installedCasks: [])
        let first = await finder.check([application])
        XCTAssertTrue(first.updates.isEmpty)
        await server.publish(catalogue("26.930.51102"))
        let second = await finder.check([application])
        XCTAssertEqual(second.updates.first?.latestVersion, "26.930.51102")
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testAResponseWithoutAnETagCannotKeepThePreviousTag() async throws {
        try seed(catalogue("26.930.41038"))
        let server = CatalogueServer(body: catalogue("26.930.51102"), etag: nil)
        let cache = CatalogueCache(directory: folder, fetch: { try await server.fetch($0) })
        let result = await cache.casks()
        XCTAssertEqual(result?.first?.displayVersion, "26.930.51102")
        let tag = try String(contentsOf: folder.appendingPathComponent("cask.etag"), encoding: .utf8)
        XCTAssertTrue(tag.isEmpty)
        let notModified = CatalogueServer(status: 304)
        let next = CatalogueCache(directory: folder, fetch: { try await notModified.fetch($0) })
        let unconfirmed = await next.casks()
        XCTAssertNil(unconfirmed, "An unsolicited 304 cannot confirm a cache without a matching tag")
    }

    func testFailedOrMalformedResponsesCannotReportTheCachedVersionAsCurrent() async throws {
        let old = catalogue("26.930.41038")
        let application = try app()
        for status in [-1, 503, 200] {
            try seed(old)
            let server = CatalogueServer(status: status, body: Data("not a catalogue".utf8))
            let finder = UpdateFinder(fetch: { try await server.fetch($0) },
                                      catalogueDirectory: folder, installedCasks: [])
            let check = await finder.check([application])
            XCTAssertEqual(check.checked, 0, "A failed refresh is not evidence of being current")
            XCTAssertEqual(check.unchecked.map(\.name), ["ChatGPT"])
            XCTAssertEqual(check.unchecked.first?.reason, "No update source answered.")
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("cask.json")), old)
        }
    }

    func testAnInvalidCacheCannotSupplyAnETagOrAcceptNotModified() async throws {
        try seed(Data("invalid".utf8))
        let server = CatalogueServer(status: 304)
        let cache = CatalogueCache(directory: folder, fetch: { try await server.fetch($0) })
        let result = await cache.casks()
        XCTAssertNil(result)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testSeveralApplicationsShareOneCatalogueRequest() async {
        let server = CatalogueServer(body: catalogue("26.930.51102"))
        let cache = CatalogueCache(directory: folder, fetch: { try await server.fetch($0) })
        let count = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 12 {
                group.addTask { await cache.casks()?.first?.displayVersion == "26.930.51102" }
            }
            var successful = 0
            for await found in group where found {
                successful += 1
            }
            return successful
        }
        XCTAssertEqual(count, 12)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
    }
}

private actor CatalogueServer {
    let status: Int
    private var body: Data
    let etag: String?
    private(set) var requests: [URLRequest] = []

    init(status: Int = 200, body: Data = Data(), etag: String? = "\"today\"") {
        self.status = status
        self.body = body
        self.etag = etag
    }

    func publish(_ data: Data) {
        body = data
    }

    func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard status != -1 else { throw URLError(.notConnectedToInternet) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: nil, headerFields: etag.map { ["ETag": $0] })
        else { throw URLError(.badServerResponse) }
        return (body, response)
    }
}
