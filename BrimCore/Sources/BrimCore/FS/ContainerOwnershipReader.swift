import Darwin
import Foundation

/// Reads only the container manager's owner records, never the container's data.
/// UUID directory names carry no ownership information. Conflicting records
/// remain useful for protecting live claimants but cannot justify selection.
public enum ContainerOwnershipReader {
    public struct Reading: Sendable {
        public let identifiers: Set<String>
        public let uncertainty: String?
        public let completeness: ScanCompleteness

        public var identifier: String? {
            uncertainty == nil && identifiers.count == 1 ? identifiers.first : nil
        }
    }

    public static let metadataName = ".com.apple.containermanagerd.metadata.plist"
    private static let ownerAttribute = "com.apple.containermanager.identifier"
    private static let metadataLimit = 64 * 1024

    public static func read(at container: URL, budget: ScanBudget = ScanBudget()) -> Reading {
        var identifiers: Set<String> = []
        let name = container.lastPathComponent
        if UUID(uuidString: name) == nil, name.contains("."), validIdentifier(name) {
            identifiers.insert(name)
        }
        guard !budget.hasRunOut else {
            return Reading(identifiers: identifiers, uncertainty: "Container ownership was not fully checked.",
                           completeness: ScanCompleteness(timedOut: [container.path]))
        }
        var unreadable: [String] = []
        var uncertain = false
        let metadata = container.appendingPathComponent(metadataName)
        for (record, path) in [
            (attribute(at: container), container.path),
            (metadataIdentifier(at: metadata), metadata.path)
        ] {
            switch record {
            case .absent: break
            case let .value(value): identifiers.insert(value)
            case .invalid: uncertain = true
            case .refused: unreadable.append(path); uncertain = true
            }
        }
        let timedOut = budget.hasRunOut ? [container.path] : []
        let completeness = ScanCompleteness(unreadable: unreadable, timedOut: timedOut)
        let uncertainty: String? = if identifiers.count > 1 {
            "Container ownership records disagree."
        } else if uncertain || !timedOut.isEmpty {
            "Container ownership could not be fully read."
        } else {
            nil
        }
        return Reading(identifiers: identifiers, uncertainty: uncertainty, completeness: completeness)
    }

    private enum Record {
        case absent, invalid, refused
        case value(String)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        IdentitySurface.isPathComponent(value) && value.utf8.count < 4096
            && !value.contains("\0") && !value.contains(where: \.isWhitespace)
    }

    private static func attribute(at container: URL) -> Record {
        let length = getxattr(container.path, ownerAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else {
            return [ENOATTR, ENOENT, ENOTSUP].contains(errno) ? .absent : .refused
        }
        guard length > 0, length < 4096 else { return .invalid }
        var bytes = [UInt8](repeating: 0, count: length)
        let count = bytes.withUnsafeMutableBytes {
            getxattr(container.path, ownerAttribute, $0.baseAddress, length, 0, XATTR_NOFOLLOW)
        }
        guard count >= 0 else { return .refused }
        guard let value = String(bytes: bytes.prefix(count), encoding: .utf8), validIdentifier(value)
        else { return .invalid }
        return .value(value)
    }

    private static func metadataIdentifier(at metadata: URL) -> Record {
        let descriptor = open(metadata.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .absent : .refused }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .refused }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
              info.st_size <= Int64(metadataLimit) else { return .invalid }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        let capacity = bytes.count
        var offset = 0
        while offset < capacity {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), capacity - offset)
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }; return .refused
            }
            if count == 0 {
                break
            }
            offset += count
        }
        guard offset <= metadataLimit,
              let plist = try? PropertyListSerialization.propertyList(from: Data(bytes.prefix(offset)), format: nil)
              as? [String: Any],
              let identifier = plist["MCMMetadataIdentifier"] as? String,
              validIdentifier(identifier) else { return .invalid }
        return .value(identifier)
    }
}
