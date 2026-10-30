import Foundation

/// Offline stand-in for a real model so the app and loop run end to end
/// without an API key. Routes a user message to a tool by keyword, then
/// echoes the tool's output back as the answer.
public struct StubModel: LanguageModel {
    public struct Route: Sendable {
        public var keywords: [String]
        public var toolName: String

        public init(keywords: [String], toolName: String) {
            self.keywords = keywords.map { $0.lowercased() }
            self.toolName = toolName
        }
    }

    private let routes: [Route]

    public init(routes: [Route]) {
        self.routes = routes
    }

    public func complete(system: String, messages: [Message], tools: [ToolSpec]) async throws -> Message {
        guard let last = messages.last else { return .assistant("Ask me something.") }

        let results = last.toolResults
        if !results.isEmpty {
            let body = results.map { $0.isError ? "The tool failed: \($0.content)" : $0.content }
            return .assistant(body.joined(separator: "\n\n"))
        }

        let text = last.text.lowercased()
        let available = Set(tools.map(\.name))
        if let route = routes.first(where: { route in
            available.contains(route.toolName) && route.keywords.contains { text.contains($0) }
        }) {
            return Message(role: .assistant, content: [
                .toolCall(ToolCall(id: "stub_\(UUID().uuidString)", name: route.toolName)),
            ])
        }

        let names = tools.map(\.name).joined(separator: ", ")
        return .assistant("I'm the offline stub model. I can only route keywords to tools right now. Tools: \(names).")
    }
}
