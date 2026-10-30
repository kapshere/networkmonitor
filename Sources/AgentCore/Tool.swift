/// What a tool is allowed to do to the system. The agent loop does not gate on
/// this yet; it exists so the UI can require confirmation for anything other
/// than `.readOnly` once mutating or privileged tools land.
public enum ToolAccess: String, Sendable {
    case readOnly
    case mutating
    case privileged
}

/// Description of a tool as advertised to the model.
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema for the tool's input object.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A capability the agent can invoke. Implementations validate their own
/// input and return text (usually JSON) that is handed back to the model.
public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    var access: ToolAccess { get }
    func run(_ input: JSONValue) async throws -> String
}

public enum ToolError: Error, Equatable, CustomStringConvertible {
    case invalidInput(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .invalidInput(let message): return "Invalid input: \(message)"
        case .unavailable(let message): return "Unavailable: \(message)"
        }
    }
}

/// Immutable set of tools keyed by name, in registration order.
public struct ToolRegistry: Sendable {
    private let tools: [any Tool]
    private let byName: [String: any Tool]

    public init(_ tools: [any Tool]) {
        var byName: [String: any Tool] = [:]
        for tool in tools {
            precondition(byName[tool.spec.name] == nil, "Duplicate tool name: \(tool.spec.name)")
            byName[tool.spec.name] = tool
        }
        self.tools = tools
        self.byName = byName
    }

    public var specs: [ToolSpec] { tools.map(\.spec) }

    public func tool(named name: String) -> (any Tool)? { byName[name] }

    /// Runs a call. Never throws: failures become error results the model can see and react to.
    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let tool = byName[call.name] else {
            return ToolResult(toolCallID: call.id, content: "Unknown tool: \(call.name)", isError: true)
        }
        do {
            return ToolResult(toolCallID: call.id, content: try await tool.run(call.input))
        } catch {
            return ToolResult(toolCallID: call.id, content: String(describing: error), isError: true)
        }
    }
}
