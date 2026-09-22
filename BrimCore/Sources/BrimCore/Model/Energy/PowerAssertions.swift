import Foundation
import IOKit
import IOKit.pwr_mgt

/// What is stopping this Mac from going to sleep, and which software asked.
///
/// The most useful thing in an energy panel and the thing nothing else says
/// plainly. System Settings shows a charge graph and a line reading "No Apps
/// Using Significant Energy". Activity Monitor has a Preventing Sleep column
/// that answers Yes or No and stops there. Neither says which kind of sleep
/// is being held off, what the program called the assertion, or how long it
/// has been held, and those three are the whole answer to "why was my
/// battery flat this morning".
///
/// `IOPMCopyAssertionsByProcess` is a documented public IOKit call that
/// returns exactly that, grouped by the process holding it. No entitlement,
/// no helper, no sudo.
public struct PowerAssertions: Sendable, Equatable {

    /// One thing a process is holding.
    public struct Held: Sendable, Equatable, Identifiable {
        public let pid: Int32
        /// The process that asked, resolved to a name a person knows.
        public let owner: String
        public let bundlePath: String?
        public let kind: Kind
        /// The name the program gave its assertion, which is often the most
        /// informative thing on the row: "Playing audio", "Backup in
        /// progress", "com.apple.WebKit wants to keep the display on".
        public let reason: String?
        /// Whether quitting the owner would release it.
        ///
        /// Read on this Mac: `Music` holding one for `com.apple.Music.playback`
        /// and `Claude` holding one for `Electron` are both a person's to
        /// stop. `powerd` holding "Prevent sleep while display is on" and
        /// `coreaudiod` holding one for the headphone output are macOS's own
        /// bookkeeping, downstream of the first two, and listing them as
        /// equals would send somebody after the wrong thing.
        public let isYours: Bool

        public var id: String { "\(pid):\(kind.rawValue):\(reason ?? "")" }

        public init(
            pid: Int32, owner: String, bundlePath: String?, kind: Kind,
            reason: String?, isYours: Bool
        ) {
            self.pid = pid
            self.owner = owner
            self.bundlePath = bundlePath
            self.kind = kind
            self.reason = reason
            self.isYours = isYours
        }
    }

    /// The two that cost a person something, and nothing else.
    ///
    /// macOS defines a dozen assertion types, most of which are internal
    /// bookkeeping that would fill the list with noise. These are the two
    /// that change what the Mac does overnight.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// The whole Mac stays awake. The expensive one.
        case systemAwake
        /// The screen stays on. Expensive on a laptop, and usually a video.
        case displayAwake

        public var title: String {
            switch self {
            case .systemAwake: return "Keeping the Mac awake"
            case .displayAwake: return "Keeping the screen on"
            }
        }

        public var consequence: String {
            switch self {
            case .systemAwake:
                return "The Mac will not sleep on its own while this is held, so it keeps "
                     + "drawing power with the lid shut."
            case .displayAwake:
                return "The screen will not switch off on its own, which is the single most "
                     + "expensive thing a laptop can leave running."
            }
        }

        public var symbolName: String {
            switch self {
            case .systemAwake: return "powersleep"
            case .displayAwake: return "sun.max"
            }
        }

        /// The IOKit assertion names that mean this.
        static func of(_ assertionType: String) -> Kind? {
            switch assertionType {
            case kIOPMAssertionTypeNoIdleSleep,
                 kIOPMAssertionTypePreventUserIdleSystemSleep,
                 "PreventSystemSleep", "PreventUserIdleSystemSleep", "NoIdleSleepAssertion":
                return .systemAwake
            case kIOPMAssertionTypeNoDisplaySleep,
                 kIOPMAssertionTypePreventUserIdleDisplaySleep,
                 "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion":
                return .displayAwake
            default:
                return nil
            }
        }
    }

    public let held: [Held]
    /// Whether the read worked at all, so "nothing is holding it awake" is
    /// told apart from "Brim did not manage to look".
    public let wasRead: Bool

    public init(held: [Held], wasRead: Bool) {
        self.held = held
        self.wasRead = wasRead
    }

    public static let notRead = PowerAssertions(held: [], wasRead: false)

    /// Whatever is keeping the machine awake, worst first, one row per
    /// process and kind rather than one per assertion. A browser holds one
    /// per playing tab and a list of nine identical rows helps nobody.
    public static func current(
        resolve: (Int32) -> (name: String, bundlePath: String?, isYours: Bool)? = Self.resolveProcess
    ) -> PowerAssertions {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return .notRead }

        var seen: Set<String> = []
        var held: [Held] = []

        for (pidNumber, assertions) in byProcess {
            let pid = pidNumber.int32Value
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey] as? String,
                      let kind = Kind.of(type) else { continue }
                // A held assertion only counts while it is on.
                if let level = assertion[kIOPMAssertionLevelKey] as? Int, level == 0 { continue }

                let resolved = resolve(pid)
                let owner = resolved?.name
                    ?? (assertion["Process Name"] as? String)
                    ?? "Process \(pid)"
                let key = "\(owner):\(kind.rawValue)"
                guard seen.insert(key).inserted else { continue }

                held.append(Held(
                    pid: pid,
                    owner: owner,
                    bundlePath: resolved?.bundlePath,
                    kind: kind,
                    reason: (assertion[kIOPMAssertionNameKey] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 },
                    isYours: resolved?.isYours ?? false
                ))
            }
        }

        // What a person can act on leads, then the more expensive kind.
        return PowerAssertions(
            held: held.sorted { left, right in
                if left.isYours != right.isYours { return left.isYours }
                if left.kind != right.kind { return left.kind == .systemAwake }
                return left.owner < right.owner
            },
            wasRead: true
        )
    }

    /// The name and bundle behind a pid. Injected so the parsing above can
    /// be tested without a live process table.
    public static func resolveProcess(_ pid: Int32) -> (name: String, bundlePath: String?, isYours: Bool)? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        let bundle = EnclosingBundle.component(of: URL(fileURLWithPath: path)).map { component -> String in
            let parts = path.components(separatedBy: "/" + component)
            return (parts.first ?? "") + "/" + component
        }
        let identity = RunningProcessIdentity.of(bundlePath: bundle, executablePath: path)
        return (identity.displayName, identity.bundlePath, identity.kind.isActionable)
    }

    /// One line for the card, or nil when there is nothing to say.
    public var sentence: String? {
        guard wasRead else { return nil }
        guard !held.isEmpty else { return nil }

        // Led by what a person can act on. macOS holds its own assertions
        // whenever the screen is on and whenever audio is routed, and those
        // are consequences of the first list rather than causes.
        let yours = held.filter(\.isYours)
        let candidates = yours.isEmpty ? held : yours

        let awake = candidates.filter { $0.kind == .systemAwake }
        let display = candidates.filter { $0.kind == .displayAwake }

        if !awake.isEmpty {
            let names = ListSentence.join(awake.map(\.owner))
            return "\(names) \(awake.count == 1 ? "is" : "are") keeping this Mac awake, so it "
                 + "will not sleep on its own."
        }
        let names = ListSentence.join(display.map(\.owner))
        return "\(names) \(display.count == 1 ? "is" : "are") keeping the screen on."
    }
}

/// Names in a sentence, joined the way a person writes them.
enum ListSentence {
    static func join(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
