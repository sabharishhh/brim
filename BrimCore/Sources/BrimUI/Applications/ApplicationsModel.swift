import Foundation
import Combine
import BrimCore
import BrimProtocol

/// One application's discovered footprint, grouped for display.
///
/// The grouping is by *how Brim knows* rather than by folder, because the
/// point the UI has to make is not "here are some files" but "here is how
/// Brim knows each of these belongs to this app".
///
/// **A heading is a claim about every row under it**, so a group is exactly
/// the rows that share a sentence and a tier. It used to be the rows that
/// shared a source, with the heading borrowed from the first row and the
/// label from the strongest, which held only while every source said one
/// thing. `LocationInventorySource` says something different for every place
/// it looks. In the running app that put "the list macOS keeps of documents
/// this application opened" above a group of caches, and "Brim will not tick
/// it for you" beside a Strong label, because the same source had also
/// found a Tier B preferences file.
public struct FootprintGroup: Identifiable, Equatable, Sendable {
    /// How strong the evidence is. The same for every row in the group.
    public let tier: EvidenceTier
    /// The sentence the evidence engine produced. The same for every row in
    /// the group, so it can head them.
    public let explanation: String
    public let items: [FootprintItem]

    public init(tier: EvidenceTier, explanation: String, items: [FootprintItem]) {
        self.tier = tier
        self.explanation = explanation
        self.items = items
    }

    /// Which part of Brim found the rows. Shown only when the engine gave
    /// no sentence, and part of the identity only then, so two sources with
    /// nothing to say are not merged under one of their names.
    public var mechanism: String { items.first?.evidence.mechanism ?? "" }

    public var id: String {
        "\(tier.rawValue)|\(explanation)|\(explanation.isEmpty ? mechanism : "")"
    }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    /// The tier every row shares. Kept under this name because it is what
    /// the list sorts and labels on.
    public var strongestTier: EvidenceTier { tier }
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

    /// Groups the selected app's footprint by what Brim can say about each
    /// item and how sure it is, strongest evidence first.
    public var footprintGroups: [FootprintGroup] {
        guard let footprint else { return [] }
        struct Key: Hashable {
            let tier: EvidenceTier
            let sentence: String
            /// Only set when there is no sentence to group on.
            let mechanism: String
        }
        let byReason = Dictionary(grouping: footprint.items) { item in
            Key(
                tier: item.evidence.tier,
                sentence: item.evidence.humanSentence,
                mechanism: item.evidence.humanSentence.isEmpty ? item.evidence.mechanism : ""
            )
        }
        return byReason
            .map { FootprintGroup(tier: $0.key.tier, explanation: $0.key.sentence, items: $0.value) }
            .sorted {
                if $0.strongestTier.rank != $1.strongestTier.rank {
                    return $0.strongestTier.rank < $1.strongestTier.rank
                }
                if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
                // Stable when two groups weigh the same, so the list does not
                // reshuffle every time the footprint is recomputed.
                return $0.id < $1.id
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
