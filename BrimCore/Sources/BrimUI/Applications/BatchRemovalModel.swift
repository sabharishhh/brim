import BrimCore
import BrimProtocol
import Foundation

/// Several apps removed from one review. Each app gets its own plan from
/// `UninstallExecutionModel`, planned, approved, applied and checked exactly
/// as it would be alone. One press runs them in turn; Touch ID is asked once
/// because approval lasts five minutes. An app whose plan fails or that will
/// not quit is reported and does not stop the others.
@MainActor
public final class BatchRemovalModel: ObservableObject {
    public struct Entry: Identifiable {
        public let app: InstalledApplication
        public let removal: UninstallExecutionModel
        public var id: String {
            app.id
        }
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var isPreparing = false
    @Published public private(set) var isRemoving = false
    @Published public private(set) var isFinished = false

    public init() {}

    /// Planned one after another, so a suite does not scan the disk several
    /// times at once.
    public func prepare(_ apps: [InstalledApplication], service: any BrimServiceProtocol) async {
        isPreparing = true
        isFinished = false
        // Two apps inside one host both arrive as the host, and one app is one
        // plan.
        var seen = Set<String>()
        let unique = apps.filter { !$0.isSystemProtected && seen.insert($0.id).inserted }
        entries = unique.map { Entry(app: $0, removal: UninstallExecutionModel()) }
        for entry in entries {
            await entry.removal.prepare(
                intent: PlanIntent(type: .uninstall, subjectIdentity: entry.app.identity,
                                   requesterKind: "ui", requesterIdentity: NSUserName()),
                service: service
            )
        }
        isPreparing = false
    }

    /// The apps whose plans are ready to run.
    public var ready: [Entry] {
        entries.filter {
            if case .ready = $0.removal.phase {
                true
            } else {
                false
            }
        }
    }

    /// What the plans will move, in total.
    public var totalBytes: Int64 {
        ready.compactMap(\.removal.plan).reduce(0) { $0 + $1.expectedTotalBytes }
    }

    /// Each ready plan in turn, through the same approval and check as one.
    public func removeAll(requesterIdentity: String) async {
        guard !isRemoving, !isPreparing else { return }
        isRemoving = true
        for entry in ready {
            await entry.removal.authorize(requesterIdentity: requesterIdentity)
            objectWillChange.send()
        }
        isRemoving = false
        isFinished = true
    }
}
