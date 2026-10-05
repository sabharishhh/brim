@testable import BrimUI
import Foundation
import Synchronization
import XCTest

@MainActor
final class FeedbackTests: XCTestCase {
    private let environment = FeedbackEnvironment(
        appVersion: "1.2", build: "42", operatingSystem: "26.0", architecture: "Apple silicon"
    )

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "feedback-\(UUID().uuidString)")!
    }

    private func draft() -> FeedbackDraft {
        var draft = FeedbackDraft()
        draft.title = "The last section reaches the edge"
        draft.details = "Collapsing the last group loses its bottom padding."
        return draft
    }

    func testSystemVersionsAreAutomaticAndHiddenBugFieldsAreNotShared() {
        var draft = draft()
        draft.reproduction = "A private reproduction note"
        draft.expected = "A private expected result"
        draft.kind = .feature
        XCTAssertFalse(draft.markdown(environment: environment).contains("private"))
        XCTAssertTrue(draft.markdown(environment: environment).contains(environment.text))
    }

    func testWhitespaceAndOversizedInputsCannotBeSubmitted() {
        var draft = draft()
        draft.title = " \n "
        XCTAssertNotNil(draft.validationMessage)
        draft.title = "A title"
        draft.details = String(repeating: "a", count: FeedbackDraft.Limit.details + 1)
        XCTAssertNotNil(draft.validationMessage)
        draft.details = "Description"
        draft.reproduction = String(repeating: "a", count: FeedbackDraft.Limit.reproduction + 1)
        XCTAssertNotNil(draft.validationMessage)
        draft.kind = .feature
        XCTAssertNil(draft.validationMessage)
    }

    func testDraftSurvivesClosingAndRelaunching() {
        let defaults = defaults()
        let first = FeedbackModel(defaults: defaults, environment: environment)
        first.draft = draft()
        let reopened = FeedbackModel(defaults: defaults, environment: environment)
        XCTAssertEqual(reopened.draft, first.draft)
    }

    func testExistingDraftKeepsItsTextAndGetsAutomaticSystemVersions() throws {
        let defaults = defaults()
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft())) as? [String: Any])
        saved["includesEnvironment"] = false
        try defaults.set(JSONSerialization.data(withJSONObject: saved), forKey: "feedback.draft.v1")
        let reopened = FeedbackModel(defaults: defaults, environment: environment)
        XCTAssertEqual(reopened.draft, draft())
        XCTAssertTrue(reopened.report.body.contains(environment.text))
    }

    /// A browser opening is not evidence that somebody submitted an issue.
    func testBrowserHandoffKeepsTheDraftAndDoesNotCreateAReceipt() async {
        let model = FeedbackModel(defaults: defaults(), environment: environment)
        model.draft = draft()
        await model.submit { url in
            XCTAssertEqual(url.host, "github.com")
            XCTAssertEqual(url.path, "/sabharishhh/brim/issues/new")
            return true
        }
        XCTAssertTrue(model.openedBrowser)
        XCTAssertNil(model.receipt)
        XCTAssertTrue(model.recent.isEmpty)
        XCTAssertEqual(model.draft, draft())
    }

    func testBrowserFailureKeepsTheDraftAndOffersRecovery() async {
        let model = FeedbackModel(defaults: defaults(), environment: environment)
        model.draft = draft()
        await model.submit { _ in false }
        XCTAssertFalse(model.openedBrowser)
        XCTAssertNotNil(model.problem)
        XCTAssertEqual(model.draft, draft())
    }

    func testURLRoundTripsUnicodeAmpersandsAndNewlinesWithoutLabels() throws {
        var draft = draft()
        draft.title = "空间 & + # ?"
        draft.details = "First line\nSecond line & + # ?"
        let report = FeedbackReport(draft: draft, environment: environment)
        let url = try FeedbackDelivery.browserURL(for: report)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "title" }?.value, draft.title)
        XCTAssertEqual(items.first { $0.name == "body" }?.value, report.body)
        XCTAssertFalse(items.contains { $0.name == "labels" })
    }

    func testLongUnicodeReportsAreKeptForCopyInsteadOfOpeningAnInvalidURL() async {
        let model = FeedbackModel(defaults: defaults(), environment: environment)
        model.draft = draft()
        model.draft.details = String(repeating: "空间", count: 1500)
        XCTAssertNil(model.draft.validationMessage)
        await model.submit { _ in
            XCTFail("A report beyond the browser URL limit must not be opened")
            return true
        }
        XCTAssertNotNil(model.problem)
        XCTAssertFalse(model.draft.isEmpty)
    }

    /// A timeout can arrive after the server has created an issue. Retrying
    /// the same text, even after relaunch, must keep its idempotency key.
    func testFailedDeliveryReusesTheReportIDAfterRelaunch() async {
        let defaults = defaults()
        let attempts = FeedbackAttempts()
        let sender: FeedbackDelivery.Send = { report in
            await attempts.record(report.id)
            throw FeedbackDeliveryError.unavailable
        }
        let first = FeedbackModel(defaults: defaults, environment: environment, send: sender)
        first.draft = draft()
        await first.submit { _ in false }
        let reopened = FeedbackModel(defaults: defaults, environment: environment, send: sender)
        await reopened.submit { _ in false }
        let ids = await attempts.ids
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last)
        reopened.draft.details += " Updated information."
        await reopened.submit { _ in false }
        let changedIDs = await attempts.ids
        XCTAssertNotEqual(changedIDs[1], changedIDs[2])
    }

    func testConfirmedDeliveryClearsTheDraftAndPersistsAReceipt() async throws {
        let defaults = defaults()
        let model = FeedbackModel(defaults: defaults, environment: environment, send: { report in
            FeedbackReceipt(
                id: report.id, number: 123,
                url: URL(string: "https://github.com/sabharishhh/brim/issues/123")!, title: report.title
            )
        })
        model.draft = draft()
        await model.submit { _ in false }
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.receipt?.number, 123)
        XCTAssertTrue(model.draft.isEmpty)
        let reopened = FeedbackModel(defaults: defaults, environment: environment)
        XCTAssertEqual(reopened.recent, try [XCTUnwrap(model.receipt)])
    }

    func testConcurrentSubmitClicksSendOnlyOneReport() async {
        let attempts = FeedbackAttempts()
        let model = FeedbackModel(defaults: defaults(), environment: environment, send: { report in
            await attempts.record(report.id)
            try await Task.sleep(for: .milliseconds(50))
            throw FeedbackDeliveryError.unavailable
        })
        model.draft = draft()
        let first = Task { await model.submit { _ in false } }
        while !model.isSending {
            await Task.yield()
        }
        await model.submit { _ in false }
        await first.value
        let ids = await attempts.ids
        XCTAssertEqual(ids.count, 1)
        XCTAssertFalse(model.isSending)
    }

    func testRelayRejectsReceiptsForAnotherReportOrRepository() async throws {
        let report = FeedbackReport(draft: draft(), environment: environment)
        let response = Data("""
        {"id":"\(report.id.uuidString)","number":42,"url":"https://github.com/another/repo/issues/42"}
        """.utf8)
        let session = session(answer: response, status: 201)
        let endpoint = try XCTUnwrap(URL(string: "https://feedback.example/report"))
        let send = FeedbackDelivery.relay(endpoint: endpoint, session: session)
        do {
            _ = try await send(report)
            XCTFail("A different repository is not a receipt for this report")
        } catch {
            XCTAssertEqual(error as? FeedbackDeliveryError, .invalidReceipt)
        }
    }

    func testRelayRecognizesRateLimits() async throws {
        let session = session(answer: Data(), status: 429)
        let endpoint = try XCTUnwrap(URL(string: "https://feedback.example/report"))
        let send = FeedbackDelivery.relay(endpoint: endpoint, session: session)
        do {
            _ = try await send(FeedbackReport(draft: draft(), environment: environment))
            XCTFail("A rate limit cannot be reported as success")
        } catch {
            XCTAssertEqual(error as? FeedbackDeliveryError, .rateLimited)
        }
    }

    func testRelaySendsPOSTWithAnIdempotencyKeyAndAcceptsTheMatchingReceipt() async throws {
        let report = FeedbackReport(draft: draft(), environment: environment)
        let response = Data("""
        {"id":"\(report.id.uuidString)","number":42,"url":"https://github.com/sabharishhh/brim/issues/42"}
        """.utf8)
        let session = session(answer: response, status: 201)
        let endpoint = try XCTUnwrap(URL(string: "https://feedback.example/report"))
        let send = FeedbackDelivery.relay(endpoint: endpoint, session: session)
        let receipt = try await send(report)
        XCTAssertEqual(receipt.id, report.id)
        let request = try XCTUnwrap(FeedbackURLProtocol.lastRequest.withLock { $0 })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), report.id.uuidString)
    }

    func testRelayRefusesPlainHTTPBeforeSendingAnything() async throws {
        let send = try FeedbackDelivery.relay(endpoint: XCTUnwrap(URL(string: "http://feedback.example/report")))
        do {
            _ = try await send(FeedbackReport(draft: draft(), environment: environment))
            XCTFail("Feedback must not be transmitted without TLS")
        } catch {
            XCTAssertEqual(error as? FeedbackDeliveryError, .invalidEndpoint)
        }
    }

    private func session(answer: Data, status: Int) -> URLSession {
        FeedbackURLProtocol.answer.withLock { $0 = (answer, status) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor FeedbackAttempts {
    var ids: [UUID] = []
    func record(_ id: UUID) {
        ids.append(id)
    }
}

private final class FeedbackURLProtocol: URLProtocol, @unchecked Sendable {
    static let answer = Mutex((Data(), 200))
    static let lastRequest = Mutex<URLRequest?>(nil)

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest.withLock { $0 = request }
        let (data, status) = Self.answer.withLock { $0 }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
