import Foundation

/// The registrations one application is responsible for, together. Brim
/// finds them by mechanism, but people think by application, so the list
/// is grouped by owner.
public struct RegistrationGroup: Identifiable, Equatable, Sendable {
    /// The owner's identifier, and what the grouping is keyed on.
    public let id: String
    /// What to call the owner. The application's name when one of its
    /// records carries it, otherwise the identifier.
    public let displayName: String
    public let items: [Registration]

    public init(id: String, displayName: String, items: [Registration]) {
        self.id = id
        self.displayName = displayName
        self.items = items
    }

    public var isSystemOwned: Bool { items.allSatisfy(\.isSystemOwned) }

    /// Entries pointing at something that is not there.
    public var stale: [Registration] { items.filter(\.isStale) }

    /// Whether macOS clears every stale entry here without help. A mixed group
    /// needs attention.
    public var staleClearsItself: Bool {
        !stale.isEmpty && stale.allSatisfy(\.isClearedByMacOS)
    }

    /// Who signed the code behind this, when every item agrees, shown once for
    /// the group. Items with no code to examine, such as a record with no path,
    /// are passed over rather than counted against the group.
    public var signedBy: String? {
        var teams: Set<String> = []
        for item in items {
            switch item.signing {
            case .valid(let team):
                guard let team else { return nil }
                teams.insert(team)
            case .none, .notChecked:
                continue
            case .teamChanged, .invalid, .unsigned:
                return nil
            }
        }
        return teams.count == 1 ? teams.first : nil
    }

    /// What the "Signed by" column shows, which is never blank. `signedBy`
    /// answers only when every item agrees on one team; unsigned, broken,
    /// changed and mixed signatures each get their own words instead of a dash.
    public var signerDescription: String {
        if let signedBy { return signedBy }

        let verdicts = items.compactMap(\.signing).filter {
            if case .notChecked = $0 { return false }
            return true
        }
        guard !verdicts.isEmpty else { return "No code to read" }
        if let trouble = verdicts.first(where: \.isTrouble) { return trouble.shortDescription }

        // Everything left is valid: either a signature with no team identifier, or
        // items with more than one team.
        var teams: Set<String> = []
        for verdict in verdicts {
            if case .valid(let team) = verdict, let team { teams.insert(team) }
        }
        switch teams.count {
        case 0: return "Signed"
        case 1: return teams.first ?? "Signed"
        default: return "Several teams"
        }
    }

    /// One line saying what this application has registered, so the group
    /// header carries the shape of the list underneath it.
    public var composition: String {
        var counts: [Registration.Kind: Int] = [:]
        for item in items { counts[item.kind, default: 0] += 1 }
        return counts
            .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map { kind, count in
                count == 1 ? kind.displayName.lowercased()
                           : "\(count) \(kind.displayName.lowercased())s"
            }
            .joined(separator: ", ")
    }

    /// Where this group's first located item sits, for a table column and for
    /// revealing it in Finder.
    public var location: String? {
        items.compactMap { $0.programPath ?? $0.recordPath }.first
    }

    public var spokenDescription: String {
        var parts = [displayName, composition]
        if let signedBy { parts.append("signed by \(signedBy)") }
        if isSystemOwned { parts.append("belongs to macOS") }
        if !stale.isEmpty {
            parts.append(staleClearsItself
                ? "macOS has not tidied this away yet"
                : "\(stale.count) of these point at nothing")
        }
        return parts.joined(separator: ", ")
    }

    /// Gathers registrations by owning bundle identifier, falling back to the
    /// entry's own identifier. Two jobs from one vendor stay apart: merging on a
    /// shared prefix would be a guess.
    public static func group(_ registrations: [Registration]) -> [RegistrationGroup] {
        var order: [String] = []
        var buckets: [String: [Registration]] = [:]

        for registration in registrations {
            let key = registration.owningBundleID ?? registration.identifier
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(registration)
        }

        return order.map { key in
            let items = buckets[key] ?? []
            return RegistrationGroup(id: key, displayName: name(for: items, key: key), items: items)
        }
    }

    /// The application's name from whichever record knows it. The record for the
    /// app itself points at a bundle, so it is preferred over its helpers'
    /// derived names; the shortest label breaks a tie.
    static func name(for items: [Registration], key: String) -> String {
        let fromBundle = items.first {
            $0.programPath?.hasSuffix(".app") == true && !$0.label.isEmpty
        }
        if let fromBundle { return fromBundle.label }

        // An app extension points at the `.appex` inside an app, so the check above
        // misses it and its own label ("NotificationService") is no name anyone
        // knows. The enclosing bundle in the path names the group instead.
        let enclosing = items
            .compactMap { $0.programPath ?? $0.recordPath }
            .compactMap { EnclosingBundle.name(of: URL(fileURLWithPath: $0)) }
            .first
        if let enclosing { return enclosing }

        let shortest = items.map(\.label).filter { !$0.isEmpty }.min { $0.count < $1.count }
        return shortest ?? key
    }
}
