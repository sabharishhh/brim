import XCTest
import Foundation

final class BrimMCPTests: XCTestCase {
    func testBrimMCPHasNoNetworkListeners() throws {
        // Find the built executable
        let bundlePath = Bundle(for: type(of: self)).bundlePath
        let buildDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        let executableURL = buildDir.appendingPathComponent("BrimMCP")
        
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            XCTFail("BrimMCP not found at \(executableURL.path)")
            return
        }
        
        let process = Process()
        process.executableURL = executableURL
        
        let pipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = inPipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        
        // Wait for it to start
        Thread.sleep(forTimeInterval: 0.2)
        
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-i", "-p", "\(process.processIdentifier)"]
        
        let lsofPipe = Pipe()
        lsof.standardOutput = lsofPipe
        
        try lsof.run()
        lsof.waitUntilExit()
        
        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        let lsofOutput = String(data: lsofData, encoding: .utf8) ?? ""
        
        process.terminate()
        process.waitUntilExit()
        
        XCTAssertTrue(lsofOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Process has open network sockets: \(lsofOutput)")
    }
}
