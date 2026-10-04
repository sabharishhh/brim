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
            case .localAgents: "/Library/LaunchAgents"
            case .localDaemons: "/Library/LaunchDaemons"
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
            case let .unknownDomain(domain):
                "\(domain) is not a place this can touch."
            case let .notAPlainName(name):
                "\(name) is not a plain file name."
            case let .notAJobFile(name):
                "\(name) is not a launchd job file."
            case let .belongsToApple(name):
                "\(name) belongs to macOS."
            case .notThere:
                "It is not there any more."
            case .notARegularFile:
                "That is not a plain file."
            case let .tooBigForAJobFile(bytes):
                "\(bytes) bytes is far too large for a job file."
            case .unreadable:
                "It could not be read."
            case .stillWorking:
                "That job still runs something that is on this Mac, so it is not a "
                    + "leftover and this will not remove it."
            case let .couldNotQuarantine(why):
                "It could not be set aside: \(why)"
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

        guard let program = reviewedProgram(in: job) else { return false }
        switch program {
        case .absent:
            // No program at all. Google's uninstaller leaves four of these
            // behind, 181 bytes of empty dictionary, and launchd has
            // nothing to run from any of them.
            return true
        case let .path(path):
            return !programExists(path)
        }
    }

    /// A declaration replaced with a missing program cannot authorize
    /// stopping the working program launchd loaded from its earlier contents.
    static func loadedJobMatchesReviewedDefinition(
        _ output: String, reviewedPath: String, reviewedPlist: Data
    ) -> Bool {
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: reviewedPlist, options: [], format: nil
        ), let dictionary = parsed as? [String: Any],
        case let .path(program)? = reviewedProgram(in: dictionary) else { return false }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func field(_ name: String) -> String? {
            let prefix = name + " = "
            let matches = lines.filter { $0.hasPrefix(prefix) }
            guard matches.count == 1 else { return nil }
            return String(matches[0].dropFirst(prefix.count))
        }
        return field("path") == reviewedPath && field("program") == program
    }

    private enum ReviewedProgram {
        case absent
        case path(String)
    }

    private static func reviewedProgram(in job: [String: Any]) -> ReviewedProgram? {
        // App-relative or searched executables cannot be treated as absent
        // by a root process probing its own working directory.
        guard job["BundleProgram"] == nil else { return nil }
        if let arguments = job["ProgramArguments"], !(arguments is [String]) {
            return nil
        }
        let program: String
        if let declared = job["Program"] {
            guard let path = declared as? String else { return nil }
            program = path
        } else if let declared = job["ProgramArguments"] {
            guard let arguments = declared as? [String], let first = arguments.first else { return nil }
            program = first
        } else {
            return .absent
        }
        guard program.hasPrefix("/"), !program.contains("\0") else { return nil }
        return .path(program)
    }

    /// Bind the parsed contents to the entry that was reviewed, and cap
    /// reading even if another process replaces or grows the job file.
    static func readReviewedPlist(parent: Int32, name: String, reviewed: stat) throws -> Data {
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw Refusal.unreadable }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(file, &opened) == 0, sameEntry(opened, reviewed),
              (opened.st_mode & S_IFMT) == S_IFREG, opened.st_size >= 0,
              opened.st_size <= 64 * 1024 else { throw Refusal.unreadable }
        guard let contents = try handle.read(upToCount: 64 * 1024 + 1),
              contents.count == Int(opened.st_size), contents.count <= 64 * 1024
        else {
            throw Refusal.unreadable
        }
        var after = stat()
        guard fstat(file, &after) == 0, sameEntry(after, opened),
              fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0, sameEntry(after, opened)
        else {
            throw Refusal.unreadable
        }
        return contents
    }

    static func validateReviewedEntry(parent: Int32, name: String, reviewed: stat) throws {
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, sameEntry(current, reviewed) else {
            throw Refusal.unreadable
        }
    }

    private static func sameEntry(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}
