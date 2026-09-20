
import BrimCore
import BrimIndex

do {
    try SelfVerification.verifyCodeSignature()
    let dbURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Brim/brim.sqlite")
    if FileManager.default.fileExists(atPath: dbURL.path) {
        let dbManager = try DatabaseManager(databaseURL: dbURL)
        try dbManager.checkIntegrity()
    }
} catch {
    print("Self-verification failed: \(error)")
    // exit(1) in production
}

import Foundation
import ArgumentParser
import BrimProtocol
import BrimCore
import BrimService

struct BrimOptions: ParsableArguments {
}


struct BrimCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brim",
        abstract: "Brim Command Line Interface",
        subcommands: [
            Apps.self,
            FootprintCmd.self,
            PlanCmd.self,
            ApproveRequest.self,
            Apply.self,
            Verify.self,
            History.self,
            LeftoversCmd.self,
            DryRunUninstall.self,
            Install.self
        ]
    )
    
    
    
    nonisolated(unsafe) static var sharedListener: NSXPCListener?
    nonisolated(unsafe) static var sharedDelegate: BrimXPCListenerDelegate?
    nonisolated(unsafe) static var sharedClient: BrimXPCClient?
    
    // Shared service accessor
    static func getService() -> BrimServiceProtocol {
        if let client = sharedClient {
            return client
        }
        
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let brimAppURL = URL(fileURLWithPath: "/Applications/Brim.app")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Brim")
        let planDir = appSupport.appendingPathComponent("Plans")
        let journalDir = appSupport.appendingPathComponent("Journals")
        
        try? FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        
        let realService = BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planDir, journalStoreDirectory: journalDir)
        
        // Spin up anonymous XPC listener
        let listener = NSXPCListener.anonymous()
        let delegate = BrimXPCListenerDelegate(service: realService, requireCodeSigning: false)
        listener.delegate = delegate
        listener.resume()
        
        // Connect client to anonymous listener
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        connection.resume()
        
        let client = BrimXPCClient(connection: connection, requireCodeSigning: false)
        
        sharedListener = listener
        sharedDelegate = delegate
        sharedClient = client
        
        return client
    }
}

// MARK: - Formatters

func outputJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    
    if let data = try? encoder.encode(value),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    } else {
        print("{}")
    }
}

// MARK: - Commands

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apps", abstract: "List installed applications")
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let appsURL = await root.url(for: .applications)
        let contents = (try? FileManager.default.contentsOfDirectory(at: appsURL, includingPropertiesForKeys: nil)) ?? []
        let apps = contents.filter { $0.pathExtension == "app" }.map { $0.lastPathComponent }
        
        if json {
            outputJSON(apps)
        } else {
            for app in apps {
                print(app)
            }
        }
    }
}

struct FootprintCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "footprint", abstract: "Calculate footprint for an app")
    @Argument(help: "Bundle ID of the app") var bundleID: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let identity = Identity(bundleID: bundleID, name: bundleID)
        let footprint = try await BrimCLI.getService().inspect(identity: identity)
        if json {
            outputJSON(footprint)
        } else {
            print("Footprint for \(bundleID): \(footprint.totalSizeBytes) bytes across \(footprint.items.count) items.")
            for item in footprint.items {
                let capStr = item.capability == .ok ? "" : " [\(item.capability.rawValue)]"
                print(" - \(item.evidence.url.path) (\(item.sizeBytes) bytes)\(capStr)")
            }
        }
    }
}

struct PlanCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Plan operations", subcommands: [Uninstall.self, Reset.self, Archive.self])
}

extension PlanCmd {
    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Create an uninstall plan")
        @Argument(help: "Bundle ID of the app") var bundleID: String
        @OptionGroup var globalOptions: BrimOptions
        @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
        
        mutating func run() async throws {
            let identity = Identity(bundleID: bundleID, name: bundleID)
            let intent = PlanIntent(type: .uninstall, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName())
            let plan = try await BrimCLI.getService().plan(intent: intent)
            if json {
                outputJSON(plan)
            } else {
                print("Created uninstall plan \(plan.planId) with \(plan.steps.count) steps.")
            }
        }
    }
    
    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset", abstract: "Create a reset plan")
        @Argument(help: "Bundle ID of the app") var bundleID: String
        @OptionGroup var globalOptions: BrimOptions
        @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
        
        mutating func run() async throws {
            let identity = Identity(bundleID: bundleID, name: bundleID)
            let intent = PlanIntent(type: .reset, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName())
            let plan = try await BrimCLI.getService().plan(intent: intent)
            if json {
                outputJSON(plan)
            } else {
                print("Created reset plan \(plan.planId) with \(plan.steps.count) steps.")
            }
        }
    }
    
    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "archive", abstract: "Create an archive plan")
        @Argument(help: "Bundle ID of the app") var bundleID: String
        @Argument(help: "Destination directory for the archive") var destination: String
        @OptionGroup var globalOptions: BrimOptions
        @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
        
        mutating func run() async throws {
            let identity = Identity(bundleID: bundleID, name: bundleID)
            let destURL = URL(fileURLWithPath: destination)
            let intent = PlanIntent(type: .archive, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName(), destinationTarget: destURL)
            let plan = try await BrimCLI.getService().plan(intent: intent)
            if json {
                outputJSON(plan)
            } else {
                print("Created archive plan \(plan.planId) with \(plan.steps.count) steps. Destination: \(destination)")
            }
        }
    }
}

struct ApproveRequest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "approve-request", abstract: "Request approval for a plan")
    @Argument(help: "Plan ID") var planId: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        guard let uuid = UUID(uuidString: planId) else {
            throw ValidationError("Invalid UUID")
        }
        
        let token = try await BrimCLI.getService().requestApproval(planId: uuid, requesterIdentity: NSUserName())
        
        if json {
            outputJSON(["status": "approval_requested", "planId": uuid.uuidString])
        } else {
            print("Approval requested for \(uuid.uuidString).")
        }
    }
}

struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apply", abstract: "Apply an approved plan")
    @Argument(help: "Plan ID") var planId: String
    @Option(name: .long, help: "Approval token") var token: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        guard let uuid = UUID(uuidString: planId) else {
            throw ValidationError("Invalid UUID")
        }
        
        // Deserialize token
        guard let data = Data(base64Encoded: token),
              let approvalToken = try? JSONDecoder().decode(ApprovalToken.self, from: data) else {
            throw ValidationError("Invalid or unparseable token")
        }
        
        try await BrimCLI.getService().apply(planId: uuid, token: approvalToken)
        
        if json {
            outputJSON(["status": "applied", "planId": uuid.uuidString])
        } else {
            print("Successfully applied plan \(uuid.uuidString).")
        }
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Verify an executed plan")
    @Argument(help: "Plan ID") var planId: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        guard let uuid = UUID(uuidString: planId) else {
            throw ValidationError("Invalid UUID")
        }
        
        let result = try await BrimCLI.getService().verify(planId: uuid)
        if json {
            outputJSON(result)
        } else {
            print("Verification for \(uuid.uuidString): \(result.success ? "Success" : "Failure") - \(result.recoveredBytes) bytes recovered.")
        }
    }
}

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "history", abstract: "View execution history")
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let history = try await BrimCLI.getService().history()
        if json {
            outputJSON(history)
        } else {
            for plan in history {
                print("Plan \(plan.planId) - \(plan.createdAt)")
            }
        }
    }
}

struct LeftoversCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "leftovers", abstract: "Scan for leftovers and orphans")
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let leftovers = try await BrimCLI.getService().leftovers()
        if json {
            outputJSON(leftovers)
        } else {
            let orphaned = leftovers.filter { $0.category == .orphaned }
            let unclaimed = leftovers.filter { $0.category == .unclaimed }
            
            print("Found \(leftovers.count) potential leftovers.")
            print("\nOrphaned (\(orphaned.count)):")
            for item in orphaned {
                print(" - \(item.url.path) (\(item.size) bytes)")
            }
            
            print("\nUnclaimed (\(unclaimed.count)):")
            for item in unclaimed {
                print(" - \(item.url.path) (\(item.size) bytes)")
            }
        }
    }
}

struct DryRunUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dry-run-uninstall", abstract: "Run the full uninstall pipeline end-to-end against a shadow root")
    @Argument(help: "Bundle ID of the app") var bundleID: String
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        // 1. Get real footprint
        let realService = BrimCLI.getService()
        let identity = Identity(bundleID: bundleID, name: bundleID)
        let footprint = try await realService.inspect(identity: identity)
        
        let paths = footprint.items.map { $0.evidence.url.path }
        
        // 2. Generate shadow root
        let rootURL = URL(fileURLWithPath: "/")
        let realRoot = FileSystemRoot(rootURL: rootURL)
        let generator = ShadowRootGenerator(sourceRoot: realRoot)
        let shadowRoot = try generator.createShadowRoot(copying: paths)
        
        // 3. Create shadow service with ephemeral storage
        let brimAppURL = URL(fileURLWithPath: "/Applications/Brim.app")
        let ephemeralBase = shadowRoot.rootURL.appendingPathComponent(".brim_ephemeral")
        let planDir = ephemeralBase.appendingPathComponent("Plans")
        let journalDir = ephemeralBase.appendingPathComponent("Journals")
        try FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: shadowRoot.rootURL)
        }
        
        let shadowService = BrimService(root: shadowRoot, brimAppURL: brimAppURL, planStoreDirectory: planDir, journalStoreDirectory: journalDir)
        
        // 4. Run pipeline
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName())
        let plan = try await shadowService.plan(intent: intent)
        
        // Mock token since CLI can't officially request one in shadow (concrete cast needed)
        // Actually, we can cast to BrimService
        let token = try await shadowService.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        
        try await shadowService.apply(planId: plan.planId, token: token)
        
        let verification = try await shadowService.verify(planId: plan.planId)
        
        if json {
            outputJSON(verification)
        } else {
            print("Shadow run complete for \(bundleID).")
            print("Target paths successfully mirrored and trashed in \(shadowRoot.rootURL.path)")
            print("Verification result: \(verification.success ? "Success" : "Failure") - \(verification.recoveredBytes) bytes recovered.")
        }
    }
}

import ServiceManagement

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install the Brim privileged helper daemon")
    
    mutating func run() async throws {
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: "com.google.Brim.daemon.plist")
            do {
                try service.register()
                print("Successfully registered daemon. You may be prompted for authentication.")
            } catch {
                print("Failed to register daemon: \(error)")
            }
        } else {
            print("SMAppService requires macOS 13.0 or newer.")
        }
    }
}

await BrimCLI.main()
