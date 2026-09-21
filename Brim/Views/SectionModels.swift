import SwiftUI
import Combine
import BrimUI

/// The models behind each section, owned by the window rather than by the
/// views that display them.
///
/// A `NavigationSplitView` tears down the detail view when the selection
/// changes, taking every `@StateObject` inside it with it. That made leaving
/// a section and coming back cost a full rescan — the Review Queue walks the
/// whole Library, the Applications list sizes every installed bundle — so
/// switching panels was measured in seconds and any selection the user had
/// made was silently discarded.
///
/// Holding them here makes a section change what the user expects it to be:
/// a change of view, not a reload of the machine.
@MainActor
final class SectionModels: ObservableObject {
    /// Declared explicitly: nothing observes this container itself — each
    /// section observes its own model — and the compiler will not synthesise
    /// a publisher for a type with no `@Published` properties.
    nonisolated let objectWillChange = ObservableObjectPublisher()

    let review = ReviewQueueViewModel()
    let applications = ApplicationsModel()
    let leftovers = LeftoversModel()
    let background = BackgroundModel()
    let storage = StorageModel()
    let energy = EnergyModel()
    let history = RemovalHistoryModel()

    /// Shared, because the Trash is one thing. Two watchers on two views
    /// would poll twice and disagree while doing it.
    let recovery = RecoveryStatusModel()
    let fullDiskAccess = FullDiskAccessModel()
}
