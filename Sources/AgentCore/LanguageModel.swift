/// A chat model that can request tool calls. A real implementation (e.g. the
/// Anthropic Messages API) maps `Message`/`ToolSpec` to its wire format.
public protocol LanguageModel: Sendable {
    func complete(system: String, messages: [Message], tools: [ToolSpec]) async throws -> Message
}
