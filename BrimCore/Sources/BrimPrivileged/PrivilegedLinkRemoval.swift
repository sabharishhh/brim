import Foundation

/// The rules applied before setting aside a command link in a root-owned
/// folder such as `/usr/local/bin`:
/// 1. The interface cannot express an arbitrary path: a domain from a fixed
///    list and one plain name, and the path is built here.
/// 2. It proves the link dead itself: only a link whose destination is
///    missing is touched. A working link or a real file never is.
/// 3. It is set aside, not deleted, in the same quarantine as job files.
public enum PrivilegedLinkRemoval {
    /// The only folders this touches; both hold machine-wide commands and belong
    /// to root.
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

    /// Where the link points, when that is nothing; refuses otherwise. Followed
    /// from the folder's descriptor, resolving relative destinations and chains
    /// as running the command would. Only "nothing there" counts: a destination
    /// this process cannot see, or a loop, might still be something.
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
