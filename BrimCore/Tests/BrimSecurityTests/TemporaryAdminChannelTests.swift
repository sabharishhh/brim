@testable import BrimPrivileged
import Darwin
import Foundation
import Synchronization
import Testing

struct TemporaryAdminChannelTests {
    @Test func disconnectSchedulesOneBoundedExitWithoutAsyncJobs() async throws {
        // Quitting during synchronous recovery deletion used to wait for that
        // deletion, potentially leaving root work alive for fifteen minutes.
        // Exercise the shutdown hook without a root process or any mutation.
        let helper = Helper()
        let exits = Mutex(0)
        helper.disconnect(after: .milliseconds(10)) { exits.withLock { $0 += 1 } }
        helper.disconnect(after: .milliseconds(10)) { exits.withLock { $0 += 1 } }

        #expect(helper.connectionCancelled)
        // Suspend rather than blocking a cooperative worker. A loaded CI
        // runner can delay dispatch without changing the shutdown behavior.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while exits.withLock({ $0 }) == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exits.withLock { $0 } == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(exits.withLock { $0 } == 1)
    }

    @Test(arguments: [UInt32(0), UInt32(1024 * 1024 + 1)])
    func refusesInvalidFrameLength(length: UInt32) throws {
        let pair = try sockets()
        defer { Darwin.close(pair.0); Darwin.close(pair.1) }
        var header = length.bigEndian
        let data = withUnsafeBytes(of: &header) { Data($0) }
        try send(data, to: pair.0)
        do {
            _ = try TemporaryAdminChannel.receiveResponse(from: pair.1)
            Issue.record("An invalid frame length was accepted.")
        } catch TemporaryAdminChannel.Failure.invalidFrame {
            // Refuse before allocating or waiting for an attacker-controlled body.
        }
    }

    @Test func refusesTruncatedFrameWithoutWaitingForTimeout() throws {
        let pair = try sockets()
        defer { Darwin.close(pair.0); Darwin.close(pair.1) }
        try send(Data([0, 0, 0, 20, 123]), to: pair.0)
        try #require(shutdown(pair.0, SHUT_WR) == 0)
        do {
            _ = try TemporaryAdminChannel.receiveResponse(from: pair.1)
            Issue.record("A truncated response was accepted.")
        } catch TemporaryAdminChannel.Failure.disconnected {
            // EOF must end the selection, even halfway through a frame.
        }
    }

    @Test func refusesAnUnpinnedSocketPeer() throws {
        let listener = try TemporaryAdminChannel.makeListener()
        defer { TemporaryAdminChannel.cleanup(listener) }
        let peer = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(peer >= 0)
        defer { Darwin.close(peer) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(listener.path.utf8CString)
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(peer, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(connected == 0)
        do {
            let accepted = try TemporaryAdminChannel.acceptHelper(listener, timeoutSeconds: 1)
            Darwin.close(accepted)
            Issue.record("An unsigned test process was accepted as the administrator helper.")
        } catch TemporaryAdminChannel.Failure.refusedPeer {
            // A socket in the user's private directory is not proof of identity.
        }
    }

    @Test func requestAndResponseKeepTheirBoundedFields() throws {
        let pair = try sockets()
        defer { Darwin.close(pair.0); Darwin.close(pair.1) }
        try TemporaryAdminChannel.send(request: .removeRecoveryItem(
            identifier: "stamp/Applications/Selected.app", expectedDevice: 3, expectedInode: 42
        ), to: pair.0)
        let request = try TemporaryAdminChannel.receiveRequest(from: pair.1)
        guard case let .removeRecoveryItem(identifier, device, inode) = request else {
            Issue.record("The request changed its operation.")
            return
        }
        #expect(identifier == "stamp/Applications/Selected.app")
        #expect(device == 3)
        #expect(inode == 42)
        try TemporaryAdminChannel.sendResponse(TemporaryAdminResponse(
            data: Data([1, 2, 3]), complaint: "The selected copy changed."
        ), to: pair.1)
        let response = try TemporaryAdminChannel.receiveResponse(from: pair.0)
        #expect(response.data == Data([1, 2, 3]))
        #expect(response.complaint == "The selected copy changed.")
    }

    @Test func shellQuotingPreservesLiteralCommandCharacters() throws {
        let value = "a 'quoted' path\n$HOME $(printf injected) `printf injected`"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + TemporaryAdminSession.shellQuote(value)]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/should-not-expand"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(data: data, encoding: .utf8) == value)
    }

    @Test func appleScriptQuotingEscapesControlCharacters() {
        #expect(TemporaryAdminSession.appleScriptQuote("a\"b\\c\nd\re") == "\"a\\\"b\\\\c\\nd\\re\"")
    }

    private func sockets() throws -> (Int32, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        return (descriptors[0], descriptors[1])
    }

    private func send(_ data: Data, to descriptor: Int32) throws {
        let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        try #require(count == data.count)
    }
}
