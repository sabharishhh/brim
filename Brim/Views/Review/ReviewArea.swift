/// The areas this summary ranks, each one a place in the window. Updates
/// and Energy are lenses on Apps now, which is why this is not simply
/// `Destination`.
enum ReviewArea: Hashable {
    case applications, leftovers, background, storage, energy, developer, updates, history

    var place: (destination: Destination, lens: AppsLens?) {
        switch self {
        case .applications: (.apps, .all)
        case .updates: (.apps, .updates)
        case .energy: (.apps, .energy)
        case .leftovers: (.leftovers, nil)
        case .background: (.background, nil)
        case .storage: (.space, nil)
        case .developer: (.developer, nil)
        case .history: (.journal, nil)
        }
    }
}
