import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Background section: what macOS runs on your behalf, and what it
/// is still being told to run for software that has gone.
///
/// Loads in two stages, and the split is the point. Launchd agents and
/// daemons are plain files anyone can read, so they appear as soon as the
/// section opens. Background Task Management needs an administrator
/// password, so it waits until somebody asks for it, and until then the view
/// says it has not looked rather than showing a number it did not earn.
@MainActor
public final class BackgroundModel: ObservableObject {

    @Published public private(set) var report: RegistrationReport = .empty
    @Published public private(set) var isLoading = false
    /// Whether login items are included. A toggle rather than a one way
    /// button: turning it off and on again reads from the cached dump, so
    /// it costs at most one administrator prompt for the whole session.
    @Published public var showsLoginItems = false {
        didSet {
            guard showsLoginItems != oldValue, let service else { return }
            Task { await load(service: service) }
        }
    }
    @Published public var searchText = ""
    @Published public var showsSystemOwned = false

    private var service: (any BrimServiceProtocol)?

    public init() {}

    /// Entries pointing at a program that has gone, which the user can do
    /// something about. Apple ships jobs whose programs are absent by
    /// design, and those are already filtered out.
    public var stale: [Registration] { filtered(report.stale) }

    /// Entries still pointing at something real.
    public var live: [Registration] {
        filtered(report.live.filter { showsSystemOwned || !$0.isSystemOwned })
    }

    public var hiddenSystemCount: Int {
        showsSystemOwned ? 0 : report.live.filter(\.isSystemOwned).count
    }

    public var gaps: [RegistrationCoverage] { report.gaps }

    private func filtered(_ items: [Registration]) -> [Registration] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
                || ($0.programPath?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        self.service = service
        guard report.registrations.isEmpty, !isLoading else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }
        report = await service.registrations(includingBackgroundItems: showsLoginItems)
    }
}
