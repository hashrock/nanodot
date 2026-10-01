import Foundation

/// MCP のツール 1 つ
public struct MCPTool {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    public let run: (MCPArgs) throws -> MCPResult

    public init(_ name: String, _ description: String, properties: [String: [String: Any]] = [:], required: [String] = [],
                run: @escaping (MCPArgs) throws -> MCPResult) {
        self.name = name
        self.description = description
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        inputSchema = schema
        self.run = run
    }
}

/// ツールの結果（MCP の content の並び）
public struct MCPResult {
    public var content: [[String: Any]]
    public var isError = false

    public static func text(_ s: String) -> MCPResult { MCPResult(content: [["type": "text", "text": s]]) }

    /// JSON にして返す
    public static func json(_ v: Any) -> MCPResult {
        let data = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return .text(String(decoding: data, as: UTF8.self))
    }

    public static func image(png: Data, caption: String) -> MCPResult {
        MCPResult(content: [
            ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
            ["type": "text", "text": caption],
        ])
    }
}

public struct MCPError: Error, LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// ツールの引数
public struct MCPArgs {
    public let values: [String: Any]

    public init(_ v: [String: Any]) { values = v }

    public func has(_ k: String) -> Bool { values[k] != nil && !(values[k] is NSNull) }

    public func int(_ k: String) throws -> Int {
        guard let v = optInt(k) else { throw MCPError("\(k) (整数) が必要です") }
        return v
    }

    public func optInt(_ k: String) -> Int? {
        if let n = values[k] as? NSNumber { return n.intValue }
        if let s = values[k] as? String { return Int(s) }
        return nil
    }

    public func optDouble(_ k: String) -> Double? {
        if let n = values[k] as? NSNumber { return n.doubleValue }
        if let s = values[k] as? String { return Double(s) }
        return nil
    }

    public func string(_ k: String) throws -> String {
        guard let v = values[k] as? String else { throw MCPError("\(k) (文字列) が必要です") }
        return v
    }

    public func optString(_ k: String) -> String? { values[k] as? String }

    public func optBool(_ k: String) -> Bool? {
        if let b = values[k] as? Bool { return b }
        if let n = values[k] as? NSNumber { return n.boolValue }
        return nil
    }

    public func color(_ k: String) throws -> RGBA {
        guard let s = values[k] as? String else { throw MCPError("\(k) (色。#rrggbb / #rrggbbaa / transparent) が必要です") }
        return try Self.parseColor(s)
    }

    public static func parseColor(_ s: String) throws -> RGBA {
        if s.lowercased() == "transparent" { return .clear }
        guard let c = RGBA(hex: s) else { throw MCPError("色 \(s) を読めません（#rrggbb / #rrggbbaa / transparent）") }
        return c
    }

    public func array(_ k: String) -> [Any]? { values[k] as? [Any] }
}

/// JSON-RPC 2.0 で MCP のメッセージを処理する（通信路とは独立）
public final class MCPServer {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public let name: String
    public let version: String
    public let instructions: String
    public private(set) var tools: [MCPTool]

    public init(name: String, version: String, instructions: String, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// 受け取った JSON を処理し、返す JSON（通知だけなら nil）
    public func handle(_ data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return encode(errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = obj as? [[String: Any]] {
            let out = batch.compactMap(handleMessage)
            return out.isEmpty ? nil : encode(out)
        }
        guard let msg = obj as? [String: Any] else {
            return encode(errorResponse(id: NSNull(), code: -32600, message: "Invalid Request"))
        }
        return handleMessage(msg).map(encode)
    }

    private func encode(_ v: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: v)) ?? Data()
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    func handleMessage(_ m: [String: Any]) -> [String: Any]? {
        guard let method = m["method"] as? String else { return nil } // レスポンスは受け取らない
        // id がなければ通知なので返さない
        guard let id = m["id"], !(id is NSNull) else { return nil }
        let params = m["params"] as? [String: Any] ?? [:]
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.supportedVersions[0]
            let v = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return ok([
                "protocolVersion": v,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions,
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return errorResponse(id: id, code: -32602, message: "Unknown tool: \(params["name"] ?? "")")
            }
            let args = MCPArgs(params["arguments"] as? [String: Any] ?? [:])
            do {
                let r = try tool.run(args)
                return ok(["content": r.content, "isError": r.isError])
            } catch {
                return ok(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }
}
