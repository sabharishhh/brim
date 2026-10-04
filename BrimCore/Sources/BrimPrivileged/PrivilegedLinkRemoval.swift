import Foundation

/// The rules the root daemon applies before it sets aside a command link.
///
/// `/usr/local/bin` belongs to root, so a link an installer left there
/// cannot be removed by the person using the Mac, however sure Brim is
/// that nothing needs it. Measured on a real Mac: nine links into a
/// deleted Docker and a deleted Python build, each one pointing at
/// nothing, and none of them removable without an administrator.
///
/// The same three ideas as `PrivilegedJobRemoval`, because they are what
/// make a root daemon safe to talk to:
///
/// 1. **The interface cannot express an arbitrary path.** A domain from a
///    fixed list and one plain name. The daemon builds the path.
/// 2. **The daemon proves it is dead, itself.** Only a symbolic link
///    whose destination is missing is ever touched. A link that reaches
///    something still works, and a real file is not a link, whoever asks
///    and whatever the caller believes about it.
/// 3. **It is set aside, not deleted.** The link goes into the same
///    root-owned quarantine as a job file, so it can be put back.
public enum PrivilegedLinkRemoval {
    /// The only folders this will touch. Both are where an installer puts
    /// a command for the whole machine, and both belong to root.
    public enum Domain: String, Sendable, CaseIterable {
        case usrLocalBin
        case usrLocalSbin

        public var directory: String {
            switch self {
            case .usrLocalBin: "/usr/local/bin"
            case .usrLocalSbin: "/usr/local/sbin"
            }
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case unknownDomain(String)
        case notAPlainName(String)
        case notThere
        case notALink
        case stillPointsAtSomething(String)
        case unreadable
        case couldNotQuarantine(String)

        public var explanation: String {
            switch self {
            case let .unknownDomain(domain):
                "\(domain) is not a place this can touch."
            case let .notAPlainName(name):
                "\(name) is not a plain file name."
            case .notThere:
                "It is not there any more."
            case .notALink:
                "That is a real file, not a link, so it is not a leftover this can prove."
            case let .stillPointsAtSomething(destination):
                "It still leads to \(destination), so it is not a leftover and this will not "
                    + "remove it."
            case .unreadable:
                "It could not be read."
            case let .couldNotQuarantine(why):
                "It could not be set aside: \(why)"
            }
        }
    }

    /// Turns a domain and a name into a path, or refuses before the disk
    /// is touched.
    public static func target(domain: String, name: String) throws -> URL {
        guard let domain = Domain(rawValue: domain) else {
            throw Refusal.unknownDomain(domain)
        }
        guard PrivilegedJobRemoval.isPlainName(name) else { throw Refusal.notAPlainName(name) }
        return URL(fileURLWithPath: domain.directory).appendingPathComponent(name)
    }

    /// Where the link points, when it points at nothing. Refuses otherwise.
    ///
    /// Everything goes through the directory's descriptor, so what is
    /// judged is what will be moved. Following the link from that
    /// descriptor resolves a relative destination against the link's own
    /// folder and walks a chain of links to its end, the way running the
    /// command would.
    ///
    /// Only "nothing there" counts as dead. A destination this process
    /// cannot see, or a loop, might still be something, and "might" is not
    /// enough for a root process to act on.
    public static func deadDestination(parent: Int32, name: String) throws -> String {
        var own = stat()
        guard fstatat(parent, name, &own, AT_SYMLINK_NOFOLLOW) == 0 else { throw Refusal.notThere }
        guard (own.st_mode & S_IFMT) == S_IFLNK else { throw Refusal.notALink }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlinkat(parent, name, &buffer, Int(PATH_MAX))
        guard length > 0 else { throw Refusal.unreadable }
        // readlinkat returns a byte count and does not append a terminator.
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        guard let destination = String(bytes: bytes, encoding: .utf8) else { throw Refusal.unreadable }

        var far = stat()
        if fstatat(parent, name, &far, 0) == 0 {
            throw Refusal.stillPointsAtSomething(destination)
        }
        guard errno == ENOENT || errno == ENOTDIR else {
            throw Refusal.stillPointsAtSomething(destination)
        }
        return destination
    }
}
