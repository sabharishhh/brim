import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Background section: what macOS runs on your behalf, and what
/// it is still being told to run for software that has gone.
///
/// One load, everything in it. This used to arrive in two stages, because
/// login items came from `sfltool` and cost an administrator prompt, so
/// they waited behind a toggle. They are read from the Background Task
/// Management store now, at the same price as everything else, which is
/// nothing.
@MainActor
public final class BackgroundModel: ObservableObject {

    @Published public private(set) var report: RegistrationReport = .empty
    @Published public private(set) var isLoading = false
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
        report = await service.registrations()
    }
}
