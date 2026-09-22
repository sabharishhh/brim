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
        var env = ProcessInfo.processInfo.environment
        env["BRIM_MCP_TEST"] = "1"
        process.environment = env
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

    func testBrimMCPSecurityT42() throws {
        let bundlePath = Bundle(for: type(of: self)).bundlePath
        let buildDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        let executableURL = buildDir.appendingPathComponent("BrimMCP")
        
        let process = Process()
        process.executableURL = executableURL
        
        let outPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardInput = inPipe
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["BRIM_MCP_TEST"] = "1"
        process.environment = env
        try process.run()
        
        let req = "{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"tools/call\", \"params\": {\"name\": \"plan\", \"arguments\": {\"bundleID\": \"com.apple.fake\", \"specificTarget\": \"/etc/passwd\"}}}\n"
        inPipe.fileHandleForWriting.write(req.data(using: .utf8)!)
        
        // Read until the answer arrives rather than sleeping a fixed half
        // second and hoping. This passed on its own and failed in a full
        // run, because a subprocess planning a footprint does not get the
        // machine to itself while the rest of the suite is running: the
        // half second ran out, the pipe was still empty, and the test
        // reported that Brim had failed to reject a path it rejects
        // perfectly well. A deadline that waits for the thing it is waiting
        // for costs nothing when the answer is quick.
        var output = ""
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            output += String(data: chunk, encoding: .utf8) ?? ""
            if output.contains("\"id\":1") || output.contains("is not in the footprint") { break }
        }

        process.terminate()
        process.waitUntilExit()

        XCTAssertTrue(
            output.contains("is not in the footprint"),
            "Should reject out of footprint specificTarget. Got: \(output)"
        )
    }

}
