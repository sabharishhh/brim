import Foundation
import Combine
import BrimCore
import BrimProtocol

/// One application's discovered footprint, grouped for display.
///
/// The grouping is by *mechanism* rather than by folder, because the point
/// the UI has to make is not "here are some files" but "here is how Brim
/// knows each of these belongs to this app".
public struct FootprintGroup: Identifiable, Equatable, Sendable {
    public let mechanism: String
    public let items: [FootprintItem]

    public var id: String { mechanism }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    /// The strongest tier in the group — evidence quality, shown per group.
    public var strongestTier: EvidenceTier {
        items.map(\.evidence.tier).min(by: { $0.rank < $1.rank }) ?? .C
    }
    /// The sentence the evidence engine produced, shared by the group.
    public var explanation: String { items.first?.evidence.humanSentence ?? "" }
}

extension EvidenceTier {
    /// Sort order for the footprint list. Lower comes first.
    ///
    /// Shared items lead, because they are the ones a person most needs to
    /// see: everything else in the list is going, and these are staying.
    /// This is an ordering, not a confidence ranking; S is not on that
    /// scale at all.
    var rank: Int {
        switch self {
        case .S: return 0
        case .A: return 1
        case .B: return 2
        case .C: return 3
        }
    }

    public var shortLabel: String {
        switch self {
        case .S: return "Shared"
        case .A: return "Direct"
        case .B: return "Strong"
        case .C: return "Heuristic"
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
    @Published public private(set) var footprint: Footprint?
    @Published public private(set) var isInspecting = false
    @Published public private(set) var errorMessage: String?

    private var service: (any BrimServiceProtocol)?
    private var inspectionTask: Task<Void, Never>?

    public init() {}

    deinit { inspectionTask?.cancel() }

    public var visibleApplications: [InstalledApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.identity.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Groups the selected app's footprint by the mechanism that found each
    /// item, strongest evidence first.
    public var footprintGroups: [FootprintGroup] {
        guard let footprint else { return [] }
        let byMechanism = Dictionary(grouping: footprint.items, by: \.evidence.mechanism)
        return byMechanism
            .map { FootprintGroup(mechanism: $0.key, items: $0.value) }
            .sorted {
                if $0.strongestTier.rank != $1.strongestTier.rank {
                    return $0.strongestTier.rank < $1.strongestTier.rank
                }
                return $0.totalBytes > $1.totalBytes
            }
    }

    /// Lists only if the list is empty. Enumerating and sizing every
    /// installed bundle takes seconds, and paying that on each visit to the
    /// section is what made switching panels feel broken.
    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard applications.isEmpty, !isLoading else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        isLoading = applications.isEmpty
        defer { isLoading = false }

        do {
            applications = try await service.installedApplications()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        // After the enumeration, because enumerating is what writes this
        // run's snapshot. Asking first would compare the machine against
        // itself.
        history = await service.whatChanged()
    }

    /// What has changed since Brim last looked, and what came across from
    /// another Mac and never ran here.
    @Published public private(set) var history = InstallHistory(changes: [], snapshots: 0)

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
        if selected?.id == application.id {
            inspectionTask?.cancel()
            selected = nil
            footprint = nil
            isInspecting = false
        }
        return true
    }

    /// Selects an application and discovers its footprint.
    ///
    /// Selecting again while a scan is in flight cancels it, so clicking
    /// down a list does not queue a scan per row.
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

    public func select(_ application: InstalledApplication?) {
        selected = application
        footprint = nil
        errorMessage = nil

        inspectionTask?.cancel()
        guard let application, let service else {
            isInspecting = false
            return
        }

        isInspecting = true
        inspectionTask = Task { [service] in
            let discovered = try? await service.inspect(identity: application.identity)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Ignore a result that arrived after the user moved on.
                guard self.selected?.id == application.id else { return }
                self.footprint = discovered
                self.isInspecting = false
            }
        }
    }

    /// Whether an uninstall can be offered for the current selection.
    public var canUninstallSelection: Bool {
        guard let selected else { return false }
        return !selected.isSystemProtected
    }

    /// Why the selected application cannot be removed, in the user's terms.
    public var uninstallBlockedReason: String? {
        guard let selected else { return nil }
        guard selected.isSystemProtected else { return nil }
        return "macOS protects this application. It is part of the system and cannot be removed."
    }
}
