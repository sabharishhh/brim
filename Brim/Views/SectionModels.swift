import BrimUI
import Combine
import SwiftUI

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
    let applications = ApplicationsModel()
    let leftovers = LeftoversModel()
    let background = BackgroundModel()
    let storage = StorageModel()
    let energy = EnergyModel()
    let developer = DeveloperModel()
    let updates = UpdatesModel()
    let history = RemovalHistoryModel()

    /// Shared, because the Trash is one thing. Two watchers on two views
    /// would poll twice and disagree while doing it.
    let recovery = RecoveryStatusModel()
    let fullDiskAccess = FullDiskAccessModel()

    /// Which places are still working, for the sidebar and the brim line.
    lazy var activity = ScanActivity(models: self)
}

/// Which places are still scanning, gathered in one object.
///
/// A person who leaves Home before the scans finish should not have to
/// guess from an empty page whether Brim is still looking. The sidebar
/// shows a small spinner beside each place still working, and the brim
/// line under the toolbar runs while anything is. Nested models do not
/// publish through their container, so their flags are merged here.
@MainActor
final class ScanActivity: ObservableObject {
    @Published private(set) var busy: Set<Destination> = []
    private var subscription: AnyCancellable?

    init(models: SectionModels) {
        let apps = Publishers.CombineLatest(models.applications.$isLoading, models.updates.$isLoading)
            .map { $0 || $1 }
        let mac = Publishers.CombineLatest4(
            models.background.$isLoading, models.storage.$isLoading, models.developer.$isScanning,
            models.energy.$isSampling
        )
        subscription = Publishers.CombineLatest4(
            models.leftovers.$isScanning, apps, mac, models.history.$isLoading
        )
        .map { leftovers, apps, mac, journal in
            var busy: Set<Destination> = []
            if leftovers {
                busy.insert(.leftovers)
            }
            if apps {
                busy.insert(.apps)
            }
            if mac.0 {
                busy.insert(.background)
            }
            if mac.1 {
                busy.insert(.space)
            }
            if mac.2 {
                busy.insert(.developer)
            }
            if mac.3 {
                busy.insert(.energy)
            }
            if journal {
                busy.insert(.journal)
            }
            // Home is made of the others, so it is working while any of
            // the places it summarises are.
            if !busy.isDisjoint(with: [.leftovers, .apps, .background, .space, .developer]) {
                busy.insert(.home)
            }
            return busy
        }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.busy = $0 }
    }
}
