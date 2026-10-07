import BrimCore
import BrimProtocol
import Combine
import Foundation
import os

extension EvidenceTier {
    /// Sort order for the footprint list. Lower comes first.
    ///
    /// Shared items lead, because they are the ones a person most needs to
    /// see: everything else in the list is going, and these are staying.
    /// This is an ordering, not a confidence ranking; S is not on that
    /// scale at all.
    var rank: Int {
        switch self {
        case .S: 0
        case .A: 1
        case .B: 2
        case .C: 3
        }
    }

    public var shortLabel: String {
        switch self {
        case .S: "Shared"
        case .A: "Direct"
        case .B: "Strong"
        case .C: "Heuristic"
        }
    }
}

/// Backs the Applications view: the installed list, and the footprint of
/// whichever one is selected.
///
/// The list and the footprint are loaded separately on purpose. Listing is
/// cheap; discovering a footprint walks the disk, so it is paid for only
/// when the user asks about one application.
@MainActor
public final class ApplicationsModel: ObservableObject {
    @Published public private(set) var applications: [InstalledApplication] = []
    @Published public private(set) var isLoading = false
    @Published public var searchText = ""

    @Published public private(set) var selected: InstalledApplication?
    /// Apps marked with Command-click for one review together. Empty, or at
    /// least two: a single mark is just a selection.
    @Published public private(set) var marked: [InstalledApplication] = []
    @Published public private(set) var footprint: Footprint? {
        didSet { footprintSections = footprint.map(FootprintSection.arrange) ?? [] }
    }

    @Published public private(set) var isInspecting = false
    /// Why the list could not be read.
    @Published public private(set) var errorMessage: String?
    /// Why the selected app's footprint could not be read. Its own fact:
    /// sharing `errorMessage` meant a failed inspection was never shown,
    /// and the pane read as an app that had put nothing on the Mac.
    @Published public private(set) var inspectionError: String?

    /// When this launch last listed the apps from the disk. Nil while the
    /// list on screen is the one kept from the last launch.
    @Published public private(set) var listedAt: Date?

    private var service: (any BrimServiceProtocol)?
    private var inspectionTask: Task<Void, Never>?
    private let cache: PageCache<[InstalledApplication]>?

    /// With a cache, the list opens on what the last launch found while
    /// this one lists the disk. Every action reads the bundle again, so a
    /// kept row is safe to select.
    public init(cache: PageCache<[InstalledApplication]>? = nil) {
        self.cache = cache
        applications = cache?.load()?.value ?? []
    }

    deinit { inspectionTask?.cancel() }

    public var visibleApplications: [InstalledApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.identity.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Current inventory rows installed within five days, newest first.
    /// Removing a row also removes it here; a reinstall receives its latest
    /// installation date from the snapshot history.
    public func recentlyInstalled(now: Date = Date()) -> [InstalledApplication] {
        let cutoff = now.addingTimeInterval(-5 * 86400)
        return applications.filter {
            guard let installed = $0.installedAt else { return false }
            return installed >= cutoff && installed <= now && !$0.isSystemProtected && $0.enclosingApp == nil
        }.sorted {
            if $0.installedAt != $1.installedAt {
                return ($0.installedAt ?? .distantPast) > ($1.installedAt ?? .distantPast)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Cached once per inspection, rather than regrouped during hover or disclosure.
    @Published public private(set) var footprintSections: [FootprintSection] = []

    /// Lists once per launch; after that the folders' own changes keep it
    /// current. A visit to the section is a change of view, not a reason
    /// to list again.
    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard listedAt == nil, !isLoading else { return }
        await load(service: service)
    }

    private var loadTask: Task<Void, Never>?

    /// The section owns its scan. Navigation can cancel a view's waiter without
    /// discarding the result or leaving a second view waiting on an empty model.
    public func load(service: any BrimServiceProtocol) async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.performLoad(service: service) }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    private func performLoad(service: any BrimServiceProtocol) async {
        guard !isLoading else { return }
        self.service = service
        isLoading = true
        let interval = BrimLog.signposter.beginInterval("Apps listing")
        defer {
            isLoading = false
            BrimLog.signposter.endInterval("Apps listing", interval)
        }

        do {
            let found = try await service.installedApplications()
            try Task.checkCancellation()
            if found != applications {
                applications = found
            }
            listedAt = Date()
            cache?.save(found)
            errorMessage = nil
            // A selection outlives the panel that removed its app, so the
            // inspector went on offering eqMac's old footprint and a Remove
            // button after the app was gone. The fresh list is the record.
            let listed = Set(found.map(\.id))
            marked.removeAll { !listed.contains($0.id) }
            if let selected, !listed.contains(selected.id) {
                inspectionTask?.cancel()
                self.selected = nil
                footprint = nil
                isInspecting = false
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops an application the UI already knows is gone, without waiting
    /// for a full re-enumeration.
    ///
    /// Listing every bundle and sizing each one takes seconds, and a row
    /// that lingers after the sheet says "nothing remains" reads as a
    /// failure. The check is on disk rather than on the sheet's word, so a
    /// removal that quietly did not happen leaves the row where it is.
    @discardableResult
    public func forgetIfRemoved(_ application: InstalledApplication) -> Bool {
        guard !FileManager.default.fileExists(atPath: application.url.path) else { return false }
        applications.removeAll { $0.id == application.id }
        marked.removeAll { $0.id == application.id }
        if selected?.id == application.id {
            inspectionTask?.cancel()
            selected = nil
            footprint = nil
            isInspecting = false
        }
        return true
    }

    /// Only for tests: stands in for an enumeration.
    func acceptForTesting(_ applications: [InstalledApplication]) {
        self.applications = applications
    }

    /// Selects whichever installed application a dropped file belongs to.
    ///
    /// Takes the bundle a path is inside, so dropping an application, or
    /// anything within one, lands on the same row. Returns false when the
    /// drop was not an installed application, so the view can say so
    /// rather than doing nothing.
    @discardableResult
    public func selectApplication(at url: URL) -> Bool {
        let dropped = url.resolvingSymlinksInPath().path
        let match = applications.first { application in
            let bundle = application.url.resolvingSymlinksInPath().path
            return dropped == bundle || dropped.hasPrefix(bundle + "/")
        }
        guard let match else { return false }
        searchText = ""
        select(match)
        return true
    }

    /// Command-click: adds the app to the ones marked, or takes it out.
    /// The app already selected is the first mark, as in Finder. Apps that
    /// are part of macOS cannot be removed, so they cannot be marked.
    public func toggleMark(_ application: InstalledApplication) {
        var next = marked
        if next.isEmpty, let selected, selected.id != application.id, !selected.isSystemProtected {
            next = [selected]
        }
        if let index = next.firstIndex(where: { $0.id == application.id }) {
            next.remove(at: index)
        } else if !application.isSystemProtected {
            next.append(application)
        }
        if next.count >= 2 {
            marked = next
        } else {
            marked = []
            select(next.first ?? application)
        }
    }

    /// Choosing, from the Select button: a click ticks an app rather than
    /// opening it. Command-click did this already and nobody could find it,
    /// in the list or the table.
    @Published public private(set) var isChoosing = false

    /// Starts with the app already open, as Command-click does.
    public func startChoosing() {
        isChoosing = true
        marked = selected.map { $0.isSystemProtected ? [] : [$0] } ?? []
    }

    public func stopChoosing() {
        isChoosing = false
        marked = []
    }

    /// Ticks or unticks one app while choosing. One or none is allowed
    /// here: the person is still picking.
    public func toggleChoice(_ application: InstalledApplication) {
        guard !application.isSystemProtected else { return }
        if let index = marked.firstIndex(where: { $0.id == application.id }) {
            marked.remove(at: index)
        } else {
            marked.append(application)
        }
    }

    public func isMarked(_ application: InstalledApplication) -> Bool {
        marked.contains { $0.id == application.id }
    }

    /// A table's selection, which can be several rows at once.
    public func mark(_ applications: [InstalledApplication]) {
        let removable = applications.filter { !$0.isSystemProtected }
        if removable.count >= 2 {
            marked = removable
        } else {
            select(applications.first)
        }
    }

    /// Selects an application and discovers its footprint.
    ///
    /// Selecting again while a scan is in flight cancels it, so clicking
    /// down a list does not queue a scan per row.
    public func select(_ application: InstalledApplication?) {
        marked = []
        isChoosing = false
        selected = application
        footprint = nil
        inspectionError = nil

        inspectionTask?.cancel()
        guard let application, let service else {
            isInspecting = false
            return
        }

        isInspecting = true
        inspectionTask = Task { [service] in
            let interval = BrimLog.signposter.beginInterval("Inspection")
            defer { BrimLog.signposter.endInterval("Inspection", interval) }
            do {
                let discovered = try await service.inspect(identity: application.identity)
                guard !Task.isCancelled, self.selected?.id == application.id else { return }
                self.footprint = discovered
                self.isInspecting = false
            } catch {
                guard !Task.isCancelled, self.selected?.id == application.id else { return }
                self.inspectionError = error.localizedDescription
                self.isInspecting = false
            }
        }
    }

    /// Why the selected application cannot be removed, in the user's terms.
    public var uninstallBlockedReason: String? {
        guard let selected else { return nil }
        guard selected.isSystemProtected else { return nil }
        if let host = selected.enclosingApp {
            // Taking one app out of another breaks the host's signature.
            return "Part of \(host), and removed with it"
        }
        return "macOS protects this application. It is part of the system and cannot be removed."
    }
}
