import XCTest
@testable import AgentCore

/// Model that replays a fixed script of replies and records what it was sent.
private actor ScriptedModel: LanguageModel {
    private var replies: [Message]
    private(set) var receivedHistories: [[Message]] = []

    init(_ replies: [Message]) { self.replies = replies }

    func complete(system: String, messages: [Message], tools: [ToolSpec]) async throws -> Message {
        receivedHistories.append(messages)
        guard !replies.isEmpty else { throw CancellationError() }
        return replies.removeFirst()
    }
}

private struct EchoTool: Tool {
    var spec: ToolSpec { ToolSpec(name: "echo", description: "Echoes input", inputSchema: ["type": "object"]) }
    var access: ToolAccess { .readOnly }
    func run(_ input: JSONValue) async throws -> String { input["say"]?.stringValue ?? "(nothing)" }
}

private struct FailingTool: Tool {
    var spec: ToolSpec { ToolSpec(name: "fail", description: "Always fails", inputSchema: ["type": "object"]) }
    var access: ToolAccess { .readOnly }
    func run(_ input: JSONValue) async throws -> String { throw ToolError.unavailable("nope") }
}

private func collect(_ stream: AsyncThrowingStream<Agent.Event, Error>) async throws -> [Agent.Event] {
    var events: [Agent.Event] = []
    for try await event in stream { events.append(event) }
    return events
}

final class AgentTests: XCTestCase {
    private let config = Agent.Configuration(systemPrompt: "test", maxModelCalls: 3)

    func testPlainReplyEndsTurn() async throws {
        let agent = Agent(model: ScriptedModel([.assistant("hi")]), tools: ToolRegistry([]), configuration: config)
        let events = try await collect(agent.send("hello"))
        XCTAssertEqual(events, [.assistantText("hi")])
        let history = await agent.history
        XCTAssertEqual(history, [.user("hello"), .assistant("hi")])
    }

    func testToolCallResultIsFedBackToModel() async throws {
        let call = ToolCall(id: "1", name: "echo", input: ["say": "pong"])
        let model = ScriptedModel([
            Message(role: .assistant, content: [.text("checking"), .toolCall(call)]),
            .assistant("done"),
        ])
        let agent = Agent(model: model, tools: ToolRegistry([EchoTool()]), configuration: config)

        let events = try await collect(agent.send("ping"))

        let result = ToolResult(toolCallID: "1", content: "pong")
        XCTAssertEqual(events, [.assistantText("checking"), .toolStarted(call), .toolFinished(result), .assistantText("done")])
        let secondRequest = await model.receivedHistories[1]
        XCTAssertEqual(secondRequest.last, Message(role: .user, content: [.toolResult(result)]))
    }

    func testUnknownAndFailingToolsBecomeErrorResults() async throws {
        let registry = ToolRegistry([FailingTool()])

        let unknown = await registry.execute(ToolCall(id: "a", name: "missing"))
        XCTAssertTrue(unknown.isError)
        XCTAssertEqual(unknown.content, "Unknown tool: missing")

        let failed = await registry.execute(ToolCall(id: "b", name: "fail"))
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.content, "Unavailable: nope")
    }

    func testModelCallLimitStopsLoopAndRollsBackHistory() async throws {
        let looping = Message(role: .assistant, content: [.toolCall(ToolCall(id: "x", name: "echo"))])
        let agent = Agent(
            model: ScriptedModel(Array(repeating: looping, count: 5)),
            tools: ToolRegistry([EchoTool()]),
            configuration: config)

        do {
            _ = try await collect(agent.send("loop"))
            XCTFail("expected limit error")
        } catch let error as Agent.AgentError {
            XCTAssertEqual(error, .modelCallLimitReached(3))
        }
        let history = await agent.history
        XCTAssertTrue(history.isEmpty)
    }

    func testStubModelRoutesKeywordToToolThenEchoesResult() async throws {
        let stub = StubModel(routes: [.init(keywords: ["Echo"], toolName: "echo")])
        let agent = Agent(model: stub, tools: ToolRegistry([EchoTool()]), configuration: config)

        let events = try await collect(agent.send("please echo"))

        guard case .toolStarted(let call) = events.first else { return XCTFail("expected a tool call, got \(events)") }
        XCTAssertEqual(call.name, "echo")
        XCTAssertEqual(events.count, 3)
    }

    func testJSONValueRoundTrips() throws {
        let value: JSONValue = ["a": [1, true, nil, "s"], "b": ["c": 2.5]]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }
}
