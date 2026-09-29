import Foundation
import Combine
import BrimCore

/// Whether a newer Brim has been published on GitHub.
///
/// Brim 1.0 is not notarised and has no updater of its own, so without
/// this nobody running it would learn that a fix had shipped. It asks
/// GitHub for the latest release when the app opens, at most once a day,
/// and when somebody chooses Check for Brim Updates. It only reports: the
/// download is the person's to make, from the release page.
@MainActor
public final class BrimReleaseCheck: ObservableObject {
    public struct Release: Equatable, Sendable {
        public let version: String
        public let page: URL
    }

    /// What a check asked for by name found, for the reply it owes.
    public enum Answer: Equatable, Sendable {
        case newer(Release)
        case current(String)
        case unreachable
    }

    /// A newer release than the one running, once a check has found it.
    @Published public private(set) var available: Release?
    @Published public private(set) var isChecking = false

    public nonisolated static let latestURL = URL(string: "https://api.github.com/repos/sabharishhh/brim/releases/latest")!
    public nonisolated static let releasesPage = URL(string: "https://github.com/sabharishhh/brim/releases/latest")!

    /// The latest release's JSON, or nil when nothing has been published.
    public typealias Fetch = @Sendable (URL) async throws -> Data?

    private let current: String
    private let fetch: Fetch
    private let defaults: UserDefaults
    private static let lastCheckKey = "brimRelease.lastCheck"

    public init(
        current: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
        defaults: UserDefaults = .standard,
        fetch: @escaping Fetch = BrimReleaseCheck.github
    ) {
        self.current = current
        self.defaults = defaults
        self.fetch = fetch
    }

    /// On opening: once a day, and silent when GitHub cannot be reached.
    public func checkIfDue(now: Date = Date()) async {
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(last) < 24 * 60 * 60 { return }
        _ = await check(now: now)
    }

    @discardableResult
    public func check(now: Date = Date()) async -> Answer {
        isChecking = true
        defer { isChecking = false }
        let answer: Data?
        do { answer = try await fetch(Self.latestURL) } catch { return .unreachable }
        defaults.set(now, forKey: Self.lastCheckKey)
        // No release yet is an answer: nothing newer exists.
        guard let data = answer, let release = Self.release(from: data) else {
            available = nil
            return .current(current)
        }
        guard VersionOrder.isNewer(release.version, than: current) else {
            available = nil
            return .current(current)
        }
        available = release
        return .newer(release)
    }

    /// The release GitHub calls latest, which already leaves out drafts and
    /// pre-releases. Tags are `v1.0.1`; the `v` is not part of the version.
    nonisolated static func release(from data: Data) -> Release? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL?
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true else { return nil }
        var version = payload.tag_name.trimmingCharacters(in: .whitespaces)
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        guard version.first?.isNumber == true else { return nil }
        return Release(version: version, page: payload.html_url ?? releasesPage)
    }

    public nonisolated static let github: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return data
        case 404: return nil
        default: throw URLError(.badServerResponse)
        }
    }
}
