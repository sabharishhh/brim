import Foundation
import Observation

/// One draft across Settings windows. Only an acknowledged submission clears
/// it; opening the browser or losing the connection never does.
@MainActor
@Observable
public final class FeedbackModel {
    public var draft: FeedbackDraft {
        didSet { saveDraft() }
    }

    public private(set) var isSending = false
    public private(set) var problem: String?
    public private(set) var receipt: FeedbackReceipt?
    public private(set) var openedBrowser = false
    public private(set) var recent: [FeedbackReceipt]
    public let environment: FeedbackEnvironment
    public let usesRelay: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let send: FeedbackDelivery.Send?
    @ObservationIgnored private var pending: FeedbackReport?
    private static let draftKey = "feedback.draft.v1"
    private static let pendingKey = "feedback.pending.v1"
    private static let recentKey = "feedback.receipts.v1"

    public init(
        defaults: UserDefaults = .standard,
        environment: FeedbackEnvironment = .current,
        send: FeedbackDelivery.Send? = nil
    ) {
        self.defaults = defaults
        self.environment = environment
        self.send = send
        usesRelay = send != nil
        draft = Self.read(FeedbackDraft.self, key: Self.draftKey, defaults: defaults) ?? FeedbackDraft()
        pending = Self.read(FeedbackReport.self, key: Self.pendingKey, defaults: defaults)
        recent = Self.read([FeedbackReceipt].self, key: Self.recentKey, defaults: defaults) ?? []
    }

    public var report: FeedbackReport {
        FeedbackReport(draft: draft, environment: environment)
    }

    public func submit(openBrowser: (URL) -> Bool) async {
        guard !isSending else { return }
        problem = draft.validationMessage
        guard problem == nil else { return }
        receipt = nil
        openedBrowser = false
        let candidate = report
        let outgoing = pending?.hasSameContent(as: candidate) == true ? pending ?? candidate : candidate
        pending = outgoing
        save(outgoing, key: Self.pendingKey)
        if let send {
            isSending = true
            defer { isSending = false }
            do {
                let received = try await send(outgoing)
                guard received.id == outgoing.id else { throw FeedbackDeliveryError.invalidReceipt }
                receipt = received
                recent.insert(received, at: 0)
                recent = Array(recent.prefix(10))
                save(recent, key: Self.recentKey)
                pending = nil
                defaults.removeObject(forKey: Self.pendingKey)
                if report.hasSameContent(as: outgoing) {
                    draft = FeedbackDraft()
                }
            } catch {
                problem = (error as? FeedbackDeliveryError)?.errorDescription
                    ?? FeedbackDeliveryError.unavailable.errorDescription
            }
        } else {
            do {
                let url = try FeedbackDelivery.browserURL(for: outgoing)
                guard openBrowser(url) else { throw FeedbackDeliveryError.browserUnavailable }
                openedBrowser = true
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    public func editAgain() {
        guard !isSending else { return }
        receipt = nil
        openedBrowser = false
        problem = nil
    }

    public func clearDraft() {
        guard !isSending else { return }
        draft = FeedbackDraft()
        pending = nil
        defaults.removeObject(forKey: Self.pendingKey)
        editAgain()
    }

    private func saveDraft() {
        save(draft, key: Self.draftKey)
    }

    private func save(_ value: some Encodable, key: String) {
        // Encoding these fixed, string-only payloads cannot fail. UserDefaults
        // schedules persistence without doing disk I/O on each keystroke.
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func read<Value: Decodable>(_: Value.Type, key: String, defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
