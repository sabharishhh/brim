import Foundation

/// The registrations one application is responsible for, gathered together.
///
/// The flat list read as though the same software were listed over and over.
/// Visual Studio Code appeared twice, once as itself and once as its
/// background tasks. ChatGPT appeared beside a dock tile plugin nobody would
/// connect to it. Google Keystone appeared four times in a row, identically
/// labelled, because it installs two jobs and installs each of them twice,
/// once for the account and once for the machine, and the row showed nothing
/// that told the copies apart.
///
/// None of those were wrong. Every row named a real, separate record. They
/// were just organised by mechanism, which is how Brim finds them, rather
/// than by application, which is how a person thinks about them. The same
/// mistake the leftovers list made, and the same fix.
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

    /// Whether macOS clears every stale entry here without help. Mixed
    /// groups count as needing attention, since the part that needs it
    /// still does.
    public var staleClearsItself: Bool {
        !stale.isEmpty && stale.allSatisfy(\.isClearedByMacOS)
    }

    /// Who signed the code behind this, when every item agrees. Shown on
    /// the group rather than on each row, because an application and the
    /// helpers it ships are signed by the same team and repeating it is
    /// noise.
    /// Items with no code to examine, such as a background-tasks record
    /// with no path at all, are passed over rather than counted against
    /// the group. Requiring every item to be signed meant an application
    /// beside one pathless record showed nothing.
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

    /// What the "Signed by" column shows, which is never blank.
    ///
    /// `signedBy` is deliberately strict: it answers only when every item
    /// agrees on one team, and returns nothing for unsigned code, a broken
    /// signature, a team that has changed underneath macOS, and a group whose
    /// items disagree. The column used to render all four of those as a dash,
    /// so a background item signed by nobody looked exactly like one Brim had
    /// not got to. Each of those states already carries its own sentence.
    public var signerDescription: String {
        if let signedBy { return signedBy }

        let verdicts = items.compactMap(\.signing).filter {
            if case .notChecked = $0 { return false }
            return true
        }
        guard !verdicts.isEmpty else { return "No code to read" }
        if let trouble = verdicts.first(where: \.isTrouble) { return trouble.shortDescription }

        // Everything left is valid, so the two remaining cases are a
        // signature that carries no team identifier and a group whose items
        // carry more than one. Both are different from "unsigned" and from
        // "not examined", which is the distinction the dash lost.
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

    /// What a screen reader should say for the group's header row, so a
    /// reader hears one application rather than a name followed by
    /// unattached counts.
    /// Where this group's first located item sits, for a table column and
    /// for revealing it in Finder.
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

    /// Gathers registrations by the application that owns them.
    ///
    /// Keyed on the owning bundle identifier, falling back to the entry's
    /// own identifier when nothing claims it. Two launchd jobs from the
    /// same vendor stay apart, because they are two different jobs and
    /// merging them on a shared name prefix would be a guess.
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

    /// The application's name, taken from whichever record knows it.
    ///
    /// The record for the application itself carries a real name and points
    /// at a bundle; the records for what it ships carry names derived from
    /// it, like "Claude - background tasks". Preferring the one that points
    /// at an app bundle picks "Claude" over its own helpers, and the
    /// shortest label breaks the tie when nothing points at a bundle.
    static func name(for items: [Registration], key: String) -> String {
        let fromBundle = items.first {
            $0.programPath?.hasSuffix(".app") == true && !$0.label.isEmpty
        }
        if let fromBundle { return fromBundle.label }

        // An app extension is not its own application and its label is not a
        // name anybody knows. Prime Video's notification service listed
        // itself as "NotificationService", IINA's as "OpenInIINA", WhatsApp's
        // two as "Intents" and "ServiceExtension". None of those records
        // points at a `.app`, because each points at the `.appex` inside one,
        // so the check above missed them and the shortest-label tiebreak
        // named the group after the plug-in. The enclosing bundle is right
        // there in the path.
        let enclosing = items
            .compactMap { $0.programPath ?? $0.recordPath }
            .compactMap { EnclosingBundle.name(of: URL(fileURLWithPath: $0)) }
            .first
        if let enclosing { return enclosing }

        let shortest = items.map(\.label).filter { !$0.isEmpty }.min { $0.count < $1.count }
        return shortest ?? key
    }
}
