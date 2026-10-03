import Darwin
import Foundation
import os
import Security

/// A private socket lives for one administrator operation, never a launchd job.
/// These blocking operations belong on the caller's dedicated work queue.
public enum TemporaryAdminChannel {
    public struct Listener: Sendable {
        public let descriptor: Int32
        public let path: String
        public let directory: String
    }

    public enum Failure: Error, LocalizedError {
        case unavailable(String)
        case refusedPeer
        case disconnected
        case timedOut
        case invalidFrame

        public init(_ detail: String) {
            self = .unavailable(detail)
        }

        public var errorDescription: String? {
            switch self {
            case let .unavailable(detail): "The administrator connection could not be opened: " + detail
            case .refusedPeer: "The administrator connection could not verify its peer."
            case .disconnected: "The administrator connection closed."
            case .timedOut: "The administrator connection timed out."
            case .invalidFrame: "The administrator process sent an invalid response."
            }
        }
    }

    private static let frameLimit = 1024 * 1024
    private static let frameTimeout: TimeInterval = 120
    private static let authenticationLog = Logger(
        subsystem: "com.sabharishhh.brim.jobhelper", category: "authentication"
    )

    public static func makeListener() throws -> Listener {
        // /tmp keeps sockaddr_un below its 104-byte limit, unlike Darwin's cache path.
        var template = Array("/tmp/brim-admin-XXXXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw systemFailure() }
        let directory = String(cString: template)
        let path = directory + "/channel"
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(atPath: directory)
            }
        }
        guard chmod(directory, 0o700) == 0 else { throw systemFailure() }
        let descriptor = try socketDescriptor()
        defer {
            if !succeeded {
                Darwin.close(descriptor)
            }
        }
        var address = try address(for: path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0,
              Darwin.listen(descriptor, 1) == 0 else { throw systemFailure() }
        succeeded = true
        return Listener(descriptor: descriptor, path: path, directory: directory)
    }

    public static func acceptHelper(_ listener: Listener, timeoutSeconds: TimeInterval = 120) throws -> Int32 {
        try wait(listener.descriptor, events: Int16(POLLIN),
                 deadline: ProcessInfo.processInfo.systemUptime + timeoutSeconds)
        let descriptor = Darwin.accept(listener.descriptor, nil, nil)
        guard descriptor >= 0 else { throw systemFailure() }
        do {
            try configure(descriptor)
            let uid = try authenticate(descriptor, requirement: BrimJobHelper.daemonRequirement())
            guard uid == 0 else { throw Failure.refusedPeer }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public static func connectToApp(path: String) throws -> (descriptor: Int32, requesterUID: uid_t) {
        guard geteuid() == 0 else { throw Failure.refusedPeer }
        let descriptor = try socketDescriptor()
        do {
            var address = try address(for: path)
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw systemFailure()
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw systemFailure() }
                try wait(descriptor, events: Int16(POLLOUT),
                         deadline: ProcessInfo.processInfo.systemUptime + frameTimeout)
                var failure: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: failure))
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0,
                      failure == 0 else { throw Failure.disconnected }
            }
            guard fcntl(descriptor, F_SETFL, flags) == 0 else { throw systemFailure() }
            let uid = try authenticate(descriptor, requirement: BrimJobHelper.clientRequirement())
            guard uid != 0 else { throw Failure.refusedPeer }
            return (descriptor, uid)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public static func close(_ descriptor: Int32) {
        _ = shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    public static func cleanup(_ listener: Listener) {
        close(listener.descriptor)
        try? FileManager.default.removeItem(atPath: listener.directory)
    }

    public static func send(request: TemporaryAdminRequest, to descriptor: Int32) throws {
        try writeFrame(JSONEncoder().encode(request), to: descriptor)
    }

    public static func receiveResponse(from descriptor: Int32) throws -> TemporaryAdminResponse {
        try JSONDecoder().decode(TemporaryAdminResponse.self, from: readFrame(from: descriptor))
    }

    static func receiveRequest(from descriptor: Int32) throws -> TemporaryAdminRequest {
        try JSONDecoder().decode(TemporaryAdminRequest.self, from: readFrame(from: descriptor))
    }

    static func sendResponse(_ response: TemporaryAdminResponse, to descriptor: Int32) throws {
        try writeFrame(JSONEncoder().encode(response), to: descriptor)
    }

    private static func socketDescriptor() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw systemFailure() }
        do { try configure(descriptor) } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        let optionLength = socklen_t(MemoryLayout.size(ofValue: enabled))
        let timeoutLength = socklen_t(MemoryLayout.size(ofValue: timeout))
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, optionLength) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLength) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLength) == 0
        else { throw systemFailure() }
    }

    private static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard !path.contains("\0"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.invalidFrame
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { source in buffer.copyBytes(from: source) }
        }
        return address
    }

    private static func readFrame(from descriptor: Int32) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + frameTimeout
        let header = try readExactly(4, from: descriptor, deadline: deadline)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= UInt32(frameLimit) else { throw Failure.invalidFrame }
        return try readExactly(Int(count), from: descriptor, deadline: deadline)
    }

    private static func readExactly(_ count: Int, from descriptor: Int32, deadline: TimeInterval) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let received = data.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received < 0, errno == EINTR {
                continue
            }
            guard received > 0 else { throw Failure.disconnected }
            offset += received
        }
        return data
    }

    private static func writeFrame(_ data: Data, to descriptor: Int32) throws {
        guard !data.isEmpty, data.count <= frameLimit else { throw Failure.invalidFrame }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        let deadline = ProcessInfo.processInfo.systemUptime + frameTimeout
        var offset = 0
        while offset < frame.count {
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let sent = frame.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0)
            }
            if sent < 0, errno == EINTR {
                continue
            }
            guard sent > 0 else { throw Failure.disconnected }
            offset += sent
        }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timedOut }
            var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&descriptorState, 1, Int32(min(remaining * 1000, Double(Int32.max))))
            if ready < 0, errno == EINTR {
                continue
            }
            guard ready > 0 else { throw Failure.timedOut }
            if descriptorState.revents & events != 0 {
                return
            }
            throw Failure.disconnected
        }
    }

    private static func systemFailure() -> Failure {
        .unavailable(String(cString: strerror(errno)))
    }
}

private extension TemporaryAdminChannel {
    private static func authenticate(_ descriptor: Int32, requirement: String) throws -> uid_t {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else {
            authenticationLog.error("administrator peer credentials unavailable: errno \(errno, privacy: .public)")
            throw Failure.refusedPeer
        }
        // The kernel supplies all 32 bytes, including the process generation.
        // Passing this token to Security avoids authorizing a reused process identifier.
        var token = [UInt32](repeating: 0, count: 8)
        var length = socklen_t(token.count * MemoryLayout<UInt32>.size)
        let result = token.withUnsafeMutableBytes {
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, $0.baseAddress, &length)
        }
        guard result == 0, length == 32 else {
            authenticationLog.error("""
            administrator peer audit token unavailable: errno \(errno, privacy: .public), \
            length \(length, privacy: .public)
            """)
            throw Failure.refusedPeer
        }
        let audit = token.withUnsafeBytes { Data($0) }
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: audit] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard guestStatus == errSecSuccess, let guest else {
            authenticationLog.error("""
            administrator peer code unavailable: status \(guestStatus, privacy: .public), \
            peer UID \(uid, privacy: .public)
            """)
            throw Failure.refusedPeer
        }
        var compiled: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard requirementStatus == errSecSuccess, let compiled else {
            authenticationLog.error("""
            administrator peer requirement unavailable: status \(requirementStatus, privacy: .public)
            """)
            throw Failure.refusedPeer
        }
        let validityStatus = SecCodeCheckValidity(guest, [], compiled)
        guard validityStatus == errSecSuccess else {
            authenticationLog.error("""
            administrator peer signature refused: status \(validityStatus, privacy: .public), \
            peer UID \(uid, privacy: .public)
            """)
            throw Failure.refusedPeer
        }
        return uid
    }
}
