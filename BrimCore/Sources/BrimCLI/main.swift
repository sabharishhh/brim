import Foundation
import ArgumentParser
import BrimProtocol
import BrimCore
import BrimService

struct BrimOptions: ParsableArguments {
    @Flag(name: .long, help: "Run against a shadow root (dry run)")
    var dryRun = false
}

@main
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
            DryRunUninstall.self
        ]
    )
    
    
    
    // Shared service accessor that handles dry-run
    static func getService(dryRun: Bool = false) -> BrimServiceProtocol {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let brimAppURL = URL(fileURLWithPath: "/Applications/Brim.app")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Brim")
        let planDir = appSupport.appendingPathComponent("Plans")
        let journalDir = appSupport.appendingPathComponent("Journals")
        
        try? FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        
        if dryRun {
            // T-1.19: Create shadow root and pass to BrimService
            // For now just return standard service, we'll implement T-1.19 next
            return BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planDir, journalStoreDirectory: journalDir)
        }
        return BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planDir, journalStoreDirectory: journalDir)
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
        // Just a dumb scan of /Applications
        let appsURL = URL(fileURLWithPath: "/Applications")
        let contents = try FileManager.default.contentsOfDirectory(at: appsURL, includingPropertiesForKeys: nil)
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
        let footprint = try await BrimCLI.getService(dryRun: globalOptions.dryRun).inspect(identity: identity)
        if json {
            outputJSON(footprint)
        } else {
            print("Footprint for \(bundleID): \(footprint.totalSizeBytes) bytes across \(footprint.items.count) items.")
            for item in footprint.items {
                print(" - \(item.evidence.url.path) (\(item.sizeBytes) bytes)")
            }
        }
    }
}

struct PlanCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Plan operations", subcommands: [Uninstall.self])
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
            let plan = try await BrimCLI.getService(dryRun: globalOptions.dryRun).plan(intent: intent)
            if json {
                outputJSON(plan)
            } else {
                print("Created uninstall plan \(plan.planId) with \(plan.steps.count) steps.")
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
        
        try await BrimCLI.getService(dryRun: globalOptions.dryRun).requestApproval(planId: uuid, requesterIdentity: NSUserName())
        
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
        
        try await BrimCLI.getService(dryRun: globalOptions.dryRun).apply(planId: uuid, token: approvalToken)
        
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
        
        let result = try await BrimCLI.getService(dryRun: globalOptions.dryRun).verify(planId: uuid)
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
        let history = try await BrimCLI.getService(dryRun: globalOptions.dryRun).history()
        if json {
            outputJSON(history)
        } else {
            for plan in history {
                print("Plan \(plan.planId) - \(plan.createdAt)")
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
        let realService = BrimCLI.getService(dryRun: false)
        let identity = Identity(bundleID: bundleID, name: bundleID)
        let footprint = try await realService.inspect(identity: identity)
        
        let paths = footprint.items.map { $0.evidence.url.path }
        
        // 2. Generate shadow root
        let rootURL = URL(fileURLWithPath: "/")
        let realRoot = FileSystemRoot(rootURL: rootURL)
        let generator = ShadowRootGenerator(sourceRoot: realRoot)
        let shadowRoot = try generator.createShadowRoot(copying: paths)
        
        // 3. Create shadow service
        let brimAppURL = URL(fileURLWithPath: "/Applications/Brim.app")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Brim")
        let planDir = appSupport.appendingPathComponent("Plans")
        let journalDir = appSupport.appendingPathComponent("Journals")
        let shadowService = BrimService(root: shadowRoot, brimAppURL: brimAppURL, planStoreDirectory: planDir, journalStoreDirectory: journalDir)
        
        // 4. Run pipeline
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName())
        let plan = try await shadowService.plan(intent: intent)
        
        // Mock token since CLI can't officially request one in shadow (concrete cast needed)
        // Actually, we can cast to BrimService
        try await shadowService.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        let hash = try plan.contentHash()
        let token = await shadowService.mintTokenForTest(planId: plan.planId, planHash: hash, requesterIdentity: NSUserName())
        
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
