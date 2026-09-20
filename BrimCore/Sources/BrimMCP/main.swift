import Foundation
import BrimProtocol
import BrimService
import BrimCore

enum MCPError: Error {
    case invalidRequest(String)
}

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: [String: JSONValue]?
}

struct JSONRPCResponse: Encodable {
    let jsonrpc: String
    let id: JSONValue?
    let result: JSONValue?
    let error: JSONRPCError?
}

struct JSONRPCError: Encodable {
    let code: Int
    let message: String
}

enum JSONValue: Codable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(String.self) { self = .string(x) }
        else if let x = try? container.decode(Bool.self) { self = .bool(x) }
        else if let x = try? container.decode(Double.self) { self = .number(x) }
        else if let x = try? container.decode([String: JSONValue].self) { self = .object(x) }
        else if let x = try? container.decode([JSONValue].self) { self = .array(x) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSONValue") }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let x): try container.encode(x)
        case .number(let x): try container.encode(x)
        case .bool(let x): try container.encode(x)
        case .object(let x): try container.encode(x)
        case .array(let x): try container.encode(x)
        case .null: try container.encodeNil()
        }
    }
    
    var stringValue: String? { if case .string(let x) = self { return x } else { return nil } }
    var numberValue: Double? { if case .number(let x) = self { return x } else { return nil } }
    var boolValue: Bool? { if case .bool(let x) = self { return x } else { return nil } }
    var objectValue: [String: JSONValue]? { if case .object(let x) = self { return x } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let x) = self { return x } else { return nil } }
}

extension Encodable {
    func toJSONValue() -> JSONValue {
        let data = try! JSONEncoder().encode(self)
        return try! JSONDecoder().decode(JSONValue.self, from: data)
    }
}

func log(_ message: String) {
    fputs(message + "\n", stderr)
}

class MCPServer {
    let service: BrimServiceProtocol
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    
    init() {
        let connection = NSXPCConnection(machServiceName: "com.google.Brim.daemon", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        connection.resume()
        self.service = BrimXPCClient(connection: connection, requireCodeSigning: false)
    }
    
    func send(response: JSONRPCResponse) {
        let data = try! encoder.encode(response)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
            fflush(stdout)
        }
    }
    
    func run() async {
        log("BrimMCP server started on stdio.")
        while let line = readLine() {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            do {
                let req = try decoder.decode(JSONRPCRequest.self, from: data)
                await handle(request: req)
            } catch {
                log("Failed to parse request: \(error)")
                send(response: JSONRPCResponse(jsonrpc: "2.0", id: nil, result: nil, error: JSONRPCError(code: -32700, message: "Parse error")))
            }
        }
    }
    
    func handle(request: JSONRPCRequest) async {
        if request.method == "initialize" {
            let result: JSONValue = .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("brim-mcp"),
                    "version": .string("1.0.0")
                ])
            ])
            send(response: JSONRPCResponse(jsonrpc: "2.0", id: request.id, result: result, error: nil))
        } else if request.method == "notifications/initialized" {
            // Ignore
        } else if request.method == "tools/list" {
            let tools: [JSONValue] = [
                .object(["name": .string("inspect"), "description": .string("Get footprint of an app"), "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "bundleID": .object(["type": .string("string")]),
                        "teamID": .object(["type": .string("string")]),
                        "path": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("bundleID")])
                ])]),
                .object(["name": .string("plan"), "description": .string("Create an uninstall plan"), "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "bundleID": .object(["type": .string("string")]),
                        "teamID": .object(["type": .string("string")]),
                        "path": .object(["type": .string("string")]),
                        "specificTarget": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("bundleID")])
                ])]),
                .object(["name": .string("explain"), "description": .string("Explain a plan"), "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "planId": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("planId")])
                ])]),
                .object(["name": .string("request_approval"), "description": .string("Request user approval for a plan"), "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "planId": .object(["type": .string("string")]),
                        "requesterIdentity": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("planId"), .string("requesterIdentity")])
                ])]),
                .object(["name": .string("apply"), "description": .string("Apply an approved plan"), "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "planId": .object(["type": .string("string")]),
                        "token": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("planId"), .string("token")])
                ])]),
                .object(["name": .string("verify"), "description": .string("Verify an applied plan"), "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "planId": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("planId")])
                ])]),
                .object(["name": .string("history"), "description": .string("Get execution history"), "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])])
            ]
            let result: JSONValue = .object(["tools": .array(tools)])
            send(response: JSONRPCResponse(jsonrpc: "2.0", id: request.id, result: result, error: nil))
        } else if request.method == "tools/call" {
            guard let params = request.params,
                  let name = params["name"]?.stringValue,
                  let args = params["arguments"]?.objectValue else {
                send(response: JSONRPCResponse(jsonrpc: "2.0", id: request.id, result: nil, error: JSONRPCError(code: -32602, message: "Invalid params")))
                return
            }
            
            do {
                let resultText = try await handleTool(name: name, args: args)
                let result: JSONValue = .object([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(resultText)
                        ])
                    ])
                ])
                send(response: JSONRPCResponse(jsonrpc: "2.0", id: request.id, result: result, error: nil))
            } catch {
                let result: JSONValue = .object([
                    "isError": .bool(true),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("Error: \(error)")
                        ])
                    ])
                ])
                send(response: JSONRPCResponse(jsonrpc: "2.0", id: request.id, result: result, error: nil))
            }
        } else {
            send(response: JSONRPCResponse(jsonrpc: "2.0", id: request.id, result: nil, error: JSONRPCError(code: -32601, message: "Method not found")))
        }
    }
    
    func handleTool(name: String, args: [String: JSONValue]) async throws -> String {
        switch name {
        case "inspect":
            guard let bundleID = args["bundleID"]?.stringValue else { throw MCPError.invalidRequest("Missing bundleID") }
            let id = Identity(bundleID: bundleID, teamID: args["teamID"]?.stringValue, name: bundleID)
            let fp = try await service.inspect(identity: id)
            let data = try JSONEncoder().encode(fp)
            return String(data: data, encoding: .utf8) ?? ""
            
        case "plan":
            guard let bundleID = args["bundleID"]?.stringValue else { throw MCPError.invalidRequest("Missing bundleID") }
            let id = Identity(bundleID: bundleID, teamID: args["teamID"]?.stringValue, name: bundleID)
            let specificTarget = args["specificTarget"]?.stringValue
            let targetURL = specificTarget != nil ? URL(fileURLWithPath: specificTarget!) : nil
            let intent = PlanIntent(type: .uninstall, subjectIdentity: id, requesterKind: "mcp", requesterIdentity: "agent", specificTarget: targetURL)
            let plan = try await service.plan(intent: intent)
            let data = try JSONEncoder().encode(plan)
            return String(data: data, encoding: .utf8) ?? ""
            
        case "explain":
            guard let pidStr = args["planId"]?.stringValue, let pid = UUID(uuidString: pidStr) else { throw MCPError.invalidRequest("Invalid planId") }
            return try await service.explain(planId: pid)
            
        case "request_approval":
            guard let pidStr = args["planId"]?.stringValue, let pid = UUID(uuidString: pidStr), let reqId = args["requesterIdentity"]?.stringValue else { throw MCPError.invalidRequest("Invalid arguments") }
            try await service.requestApproval(planId: pid, requesterIdentity: reqId)
            return "Approval requested."
            
        case "apply":
            guard let pidStr = args["planId"]?.stringValue, let pid = UUID(uuidString: pidStr), let tokenStr = args["token"]?.stringValue else { throw MCPError.invalidRequest("Invalid arguments") }
            // Decode token? Wait, the API requires `ApprovalToken`. We need to parse it.
            let tokenData = tokenStr.data(using: .utf8)!
            let token = try JSONDecoder().decode(ApprovalToken.self, from: tokenData)
            try await service.apply(planId: pid, token: token)
            return "Plan applied."
            
        case "verify":
            guard let pidStr = args["planId"]?.stringValue, let pid = UUID(uuidString: pidStr) else { throw MCPError.invalidRequest("Invalid arguments") }
            let vr = try await service.verify(planId: pid)
            let data = try JSONEncoder().encode(vr)
            return String(data: data, encoding: .utf8) ?? ""
            
        case "history":
            let hist = try await service.history()
            let data = try JSONEncoder().encode(hist)
            return String(data: data, encoding: .utf8) ?? ""
            
        default:
            throw MCPError.invalidRequest("Unknown tool \(name)")
        }
    }
}

await MCPServer().run()
