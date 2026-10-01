import Foundation

public enum FeedbackDeliveryError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidReceipt
    case unavailable
    case rateLimited
    case browserUnavailable
    case draftTooLong
    case payloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Reporting is not configured correctly. Copy your report and open GitHub instead."
        case .invalidReceipt:
            "Your report could not be confirmed. Your draft is kept. You can safely retry the same report."
        case .unavailable:
            "The reporting service could not be reached. Your draft is kept. Try again when you are online."
        case .rateLimited: "Too many reports were sent recently. Your draft is kept. Please try again in a minute."
        case .browserUnavailable: "Brim could not open your browser. Copy your report and open GitHub yourself."
        case .draftTooLong:
            "This report is too long for a browser link. Copy it, then paste it into a new GitHub issue."
        case .payloadTooLarge:
            "This report is too large to send. Shorten it, or copy it and paste it into a new GitHub issue."
        }
    }
}

/// A receipt is accepted only for this repository and this exact report.
public struct FeedbackReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let number: Int
    public let url: URL
    public let title: String
    public let createdAt: Date

    public init(id: UUID, number: Int, url: URL, title: String, createdAt: Date = .now) {
        self.id = id
        self.number = number
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }
}

public enum FeedbackDelivery {
    public static let issuesURL = URL(string: "https://github.com/sabharishhh/brim/issues")!
    public static let newIssueURL = URL(string: "https://github.com/sabharishhh/brim/issues/new")!

    public typealias Send = @Sendable (FeedbackReport) async throws -> FeedbackReceipt

    /// No labels parameter: people with ordinary GitHub access cannot assign
    /// labels through a URL, which can make the draft link return a 404.
    public static func browserURL(for report: FeedbackReport) throws -> URL {
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: report.title),
            URLQueryItem(name: "body", value: report.body)
        ]
        guard let url = components?.url, url.absoluteString.utf8.count <= 8000 else {
            throw FeedbackDeliveryError.draftTooLong
        }
        return url
    }

    public static func relay(endpoint: URL, session: URLSession = .shared) -> Send {
        { report in
            guard endpoint.scheme == "https", endpoint.host != nil,
                  endpoint.user == nil, endpoint.password == nil,
                  endpoint.query == nil, endpoint.fragment == nil
            else {
                throw FeedbackDeliveryError.invalidEndpoint
            }
            var request = URLRequest(url: endpoint, timeoutInterval: 25)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(report.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
            request.httpBody = try JSONEncoder().encode(report)
            guard let body = request.httpBody, body.count <= 48000 else {
                throw FeedbackDeliveryError.payloadTooLarge
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FeedbackDeliveryError.unavailable
            }
            guard let http = response as? HTTPURLResponse else { throw FeedbackDeliveryError.invalidReceipt }
            if http.statusCode == 429 {
                throw FeedbackDeliveryError.rateLimited
            }
            guard [200, 201].contains(http.statusCode), data.count <= 16384 else {
                throw FeedbackDeliveryError.unavailable
            }
            struct Reply: Decodable {
                let id: UUID
                let number: Int
                let url: URL
            }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  reply.id == report.id, reply.number > 0,
                  reply.url.scheme == "https", reply.url.host == "github.com",
                  reply.url.user == nil, reply.url.password == nil, reply.url.port == nil,
                  reply.url.query == nil, reply.url.fragment == nil,
                  reply.url.path == "/sabharishhh/brim/issues/\(reply.number)"
            else {
                throw FeedbackDeliveryError.invalidReceipt
            }
            return FeedbackReceipt(id: report.id, number: reply.number, url: reply.url, title: report.title)
        }
    }
}
