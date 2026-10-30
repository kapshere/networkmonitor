/// Drives the model ⇄ tool loop for a single conversation.
///
/// Each `send` appends the user's text, asks the model for a reply, executes
/// any tool calls it makes, feeds the results back, and repeats until the
/// model answers without calling a tool or the round limit is hit.
public actor Agent {
    public struct Configuration: Sendable {
        public var systemPrompt: String
        /// Upper bound on model calls per user turn, to stop runaway tool loops.
        public var maxModelCalls: Int

        public init(systemPrompt: String, maxModelCalls: Int = 8) {
            precondition(maxModelCalls > 0)
            self.systemPrompt = systemPrompt
            self.maxModelCalls = maxModelCalls
        }
    }

    public enum Event: Sendable, Equatable {
        case assistantText(String)
        case toolStarted(ToolCall)
        case toolFinished(ToolResult)
    }

    public enum AgentError: Error, Equatable {
        case busy
        case modelCallLimitReached(Int)
    }

    private let model: any LanguageModel
    private let tools: ToolRegistry
    private let configuration: Configuration
    public private(set) var history: [Message] = []
    private var isRunning = false

    public init(model: any LanguageModel, tools: ToolRegistry, configuration: Configuration) {
        self.model = model
        self.tools = tools
        self.configuration = configuration
    }

    /// Streams the events of one user turn. Cancelling the consuming task
    /// cancels the turn; a turn that fails or is cancelled leaves no trace in
    /// `history`, so the conversation never holds a tool call without its result.
    public nonisolated func send(_ text: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runTurn(text) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func reset() {
        history.removeAll()
    }

    private func runTurn(_ text: String, emit: @Sendable (Event) -> Void) async throws {
        guard !isRunning else { throw AgentError.busy }
        isRunning = true
        defer { isRunning = false }

        let checkpoint = history.count
        do {
            history.append(.user(text))
            for _ in 0..<configuration.maxModelCalls {
                try Task.checkCancellation()
                let reply = try await model.complete(
                    system: configuration.systemPrompt, messages: history, tools: tools.specs)
                history.append(reply)

                for case .text(let chunk) in reply.content where !chunk.isEmpty {
                    emit(.assistantText(chunk))
                }

                let calls = reply.toolCalls
                if calls.isEmpty { return }

                var results: [ContentBlock] = []
                for call in calls {
                    try Task.checkCancellation()
                    emit(.toolStarted(call))
                    let result = await tools.execute(call)
                    emit(.toolFinished(result))
                    results.append(.toolResult(result))
                }
                history.append(Message(role: .user, content: results))
            }
            throw AgentError.modelCallLimitReached(configuration.maxModelCalls)
        } catch {
            history.removeSubrange(checkpoint...)
            throw error
        }
    }
}
