import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Duplicates section.
///
/// Scans a folder the user picks rather than the whole disk. A full home
/// directory pass reads every byte of every file that shares a size with
/// another, which is minutes of work and gigabytes of reading for a
/// question usually asked about one folder.
@MainActor
public final class DuplicatesModel: ObservableObject {

    @Published public private(set) var groups: [DuplicateGroup] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var scannedFolder: URL?
    @Published public private(set) var errorMessage: String?

    /// Paths chosen for removal. A group always keeps at least one copy,
    /// which the model enforces rather than trusting the view to.
    @Published public var selection: Set<String> = []

    public init() {}

    /// What the copies occupy in total, if every one were counted.
    public var logicalBytes: Int64 { groups.reduce(0) { $0 + $1.logicalSize } }

    /// What removing the extra copies would actually give back. Lower than
    /// the logical figure wherever files already share storage.
    public var recoverableBytes: Int64 { groups.reduce(0) { $0 + $1.recoverableBytes } }

    /// Groups whose copies already share their blocks, so removing one
    /// frees nothing. Worth naming rather than hiding.
    public var alreadySharingStorage: [DuplicateGroup] {
        groups.filter { $0.recoverableBytes == 0 && $0.paths.count > 1 }
    }

    public var selectedBytes: Int64 {
        groups.reduce(0) { total, group in
            let chosen = group.paths.filter { selection.contains($0) }.count
            guard chosen > 0, group.recoverableBytes > 0 else { return total }
            // Each copy removed gives back one file's worth, never more
            // than the group can actually release.
            return total + min(group.recoverableBytes, group.size * Int64(chosen))
        }
    }

    public var canRemove: Bool { !selection.isEmpty }

    public func scan(directory: URL, service: any BrimServiceProtocol) async {
        isScanning = true
        scannedFolder = directory
        selection = []
        defer { isScanning = false }

        do {
            groups = try await service.scanDuplicates(in: directory)
                .sorted { $0.recoverableBytes > $1.recoverableBytes }
            errorMessage = nil
        } catch {
            groups = []
            errorMessage = error.localizedDescription
        }
    }

    /// Whether this copy may be removed. The first path in a group is the
    /// one kept, so there is always something left.
    public func canSelect(_ path: String, in group: DuplicateGroup) -> Bool {
        group.recoverableBytes > 0 && group.paths.first != path
    }

    public func toggle(_ path: String, in group: DuplicateGroup) {
        guard canSelect(path, in: group) else { return }
        if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
    }

    /// Selects every copy except the first in each group.
    public func selectExtras() {
        for group in groups where group.recoverableBytes > 0 {
            for path in group.paths.dropFirst() { selection.insert(path) }
        }
    }

    public func clearSelection() { selection = [] }

    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        let targets = selection.sorted().map { URL(fileURLWithPath: $0) }
        guard !targets.isEmpty else { return nil }
        return PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: "Duplicates"),
            requesterKind: "ui",
            requesterIdentity: requesterIdentity,
            specificTargets: targets
        )
    }
}
