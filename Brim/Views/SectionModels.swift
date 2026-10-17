import BrimUI
import Combine
import SwiftUI

/// The models behind each section, owned by the window rather than the
/// views. A `NavigationSplitView` tears down the detail view on every
/// selection change, which made coming back to a section a full rescan and
/// discarded the person's selection.
@MainActor
final class SectionModels: ObservableObject {
    /// Apps, Remnants and Developer open on what the last launch found,
    /// kept in Brim's caches folder, while this launch checks it.
    let applications = ApplicationsModel(cache: PageCache("applications", version: 1))
    let leftovers = LeftoversModel(cache: PageCache("remnants", version: 1))
    let background = BackgroundModel()
    /// Takes its estimate from Remnants rather than scanning again.
    let storage: StorageModel
    /// Every installed app's data, for Space.
    let appData = AppDataModel()
    let energy = EnergyModel()
    let developer = DeveloperModel(cache: PageCache("developer", version: 1))
    let updates = UpdatesModel()
    /// What each available update changes, read once per version.
    let whatsNew = WhatsNewModel()
    let history = RemovalHistoryModel()
    /// An install being recorded, from Home, the menu bar or a preview.
    let recording = InstallRecordingModel()

    /// Shared, because the Trash is one thing and two watchers would disagree.
    let recovery = RecoveryStatusModel()
    let fullDiskAccess = FullDiskAccessModel()

    /// Which places are still working, for the sidebar and the brim line.
    lazy var activity = ScanActivity(models: self)

    init() {
        storage = StorageModel(leftovers: leftovers)
    }
}

/// Which places are still scanning, for the sidebar's spinners and the line
/// under the toolbar. Nested models do not publish through their container,
/// so their flags are merged here.
@MainActor
final class ScanActivity: ObservableObject {
    @Published private(set) var busy: Set<Destination> = []
    private var subscription: AnyCancellable?

    init(models: SectionModels) {
        let apps = Publishers.CombineLatest(models.applications.$isLoading, models.updates.$isChecking)
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
            // Home summarises the others, so it is working while any of them is.
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
