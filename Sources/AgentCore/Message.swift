/// Conversation types. The shape deliberately mirrors tool-use chat APIs
/// (text / tool call / tool result blocks) so a real model client can map
/// onto it without the agent loop changing.
public enum Role: String, Sendable, Codable {
    case user
    case assistant
}

public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue = [:]) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ToolResult: Sendable, Equatable {
    public var toolCallID: String
    public var content: String
    public var isError: Bool

    public init(toolCallID: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
}

public struct Message: Sendable, Equatable {
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> Message { Message(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> Message { Message(role: .assistant, content: [.text(text)]) }

    /// All text blocks joined with newlines.
    public var text: String {
        content.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    public var toolCalls: [ToolCall] {
        content.compactMap { block in
            if case .toolCall(let call) = block { return call }
            return nil
        }
    }

    public var toolResults: [ToolResult] {
        content.compactMap { block in
            if case .toolResult(let result) = block { return result }
            return nil
        }
    }
}
