import Foundation

/// The rules a root daemon applies before it removes anything.
///
/// A daemon running as root that takes a path and deletes it is a local
/// privilege escalation waiting to be found. Every rule here exists so that
/// a caller who gets past the code signing check still cannot do damage
/// with what the interface offers.
///
/// Three ideas, in order of how much they are worth:
///
/// 1. **The interface cannot express an arbitrary path.** A caller names a
///    domain from a fixed list and a single file name. The daemon builds
///    the path. There is no way to say `../..`, no way to pass an absolute
///    path, and nothing to traverse.
/// 2. **The daemon refuses to remove a job that works.** It removes a job
///    file only when launchd could not usefully run it: an empty plist, or
///    one whose program is not on the disk. So even a caller who got past
///    everything else cannot switch off a working system service.
/// 3. **Nothing of Apple's, ever.** Refused by name, by the daemon, rather
///    than trusting the caller to have filtered them out.
public enum PrivilegedJobRemoval {

    /// The only places this daemon will touch. `/Library/LaunchAgents` and
    /// `/Library/LaunchDaemons` are where a third party installs a job for
    /// the whole machine, and they belong to root, which is the entire
    /// reason a daemon is involved. A job in someone's own Library needs
    /// no privileges and must never come through here.
    public enum Domain: String, Sendable, CaseIterable {
        case localAgents
        case localDaemons

        public var directory: String {
            switch self {
            case .localAgents: return "/Library/LaunchAgents"
            case .localDaemons: return "/Library/LaunchDaemons"
            }
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case unknownDomain(String)
        case notAPlainName(String)
        case notAJobFile(String)
        case belongsToApple(String)
        case notThere
        case notARegularFile
        case tooBigForAJobFile(Int)
        case unreadable
        case stillWorking
        case couldNotQuarantine(String)

        public var explanation: String {
            switch self {
            case .unknownDomain(let domain):
                return "\(domain) is not a place this can touch."
            case .notAPlainName(let name):
                return "\(name) is not a plain file name."
            case .notAJobFile(let name):
                return "\(name) is not a launchd job file."
            case .belongsToApple(let name):
                return "\(name) belongs to macOS."
            case .notThere:
                return "It is not there any more."
            case .notARegularFile:
                return "That is not a plain file."
            case .tooBigForAJobFile(let bytes):
                return "\(bytes) bytes is far too large for a job file."
            case .unreadable:
                return "It could not be read."
            case .stillWorking:
                return "That job still runs something that is on this Mac, so it is not a "
                     + "leftover and this will not remove it."
            case .couldNotQuarantine(let why):
                return "It could not be set aside: \(why)"
            }
        }
    }

    /// Turns a domain and a name into a path, or refuses.
    ///
    /// A single path component only. Anything with a separator, anything
    /// relative, anything hidden, anything that is not a plist, and
    /// anything of Apple's is refused before the filesystem is touched.
    public static func target(domain: String, name: String) throws -> URL {
        guard let domain = Domain(rawValue: domain) else {
            throw Refusal.unknownDomain(domain)
        }
        guard isPlainName(name) else { throw Refusal.notAPlainName(name) }
        guard name.hasSuffix(".plist") else { throw Refusal.notAJobFile(name) }
        guard !name.hasPrefix("com.apple.") else { throw Refusal.belongsToApple(name) }

        return URL(fileURLWithPath: domain.directory).appendingPathComponent(name)
    }

    /// One path component, and an ordinary one.
    static func isPlainName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count < 256 else { return false }
        guard !name.contains("/"), !name.contains("\0") else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.hasPrefix(".") else { return false }
        // A name that changes when it is put through path normalisation is
        // trying to be something other than a name.
        return (name as NSString).lastPathComponent == name
    }

    /// Whether launchd could usefully run this job, judged from the plist
    /// itself and from whether the program it names is on the disk.
    ///
    /// This is the check that makes the daemon safe to expose at all. A
    /// job that still works is never removed, whoever asks.
    public static func isDefunct(plist data: Data, programExists: (String) -> Bool) -> Bool {
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let job = parsed as? [String: Any]
        else {
            // Unparseable is not a licence to delete. launchd would ignore
            // it, but so should this.
            return false
        }

        let program = (job["Program"] as? String)
            ?? (job["ProgramArguments"] as? [String])?.first

        guard let program else {
            // No program at all. Google's uninstaller leaves four of these
            // behind, 181 bytes of empty dictionary, and launchd has
            // nothing to run from any of them.
            return true
        }
        return !programExists(program)
    }
}
