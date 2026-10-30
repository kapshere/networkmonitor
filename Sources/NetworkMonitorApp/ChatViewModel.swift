import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case user
            case assistant
            case tool(name: String, state: ToolState)
            case error
        }

        enum ToolState: Equatable {
            case running
            case succeeded
            case failed
        }

        let id = UUID()
        var kind: Kind
        var text: String
    }

    private(set) var entries: [Entry] = []
    var draft = ""
    private(set) var isRunning = false

    private let agent: Agent
    private var turn: Task<Void, Never>?

    init(agent: Agent) {
        self.agent = agent
    }

    var canSend: Bool {
        !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty else { return }
        draft = ""
        entries.append(Entry(kind: .user, text: text))
        isRunning = true

        turn = Task {
            defer {
                isRunning = false
                turn = nil
            }
            var toolEntries: [String: Entry.ID] = [:]
            do {
                for try await event in agent.send(text) {
                    switch event {
                    case .assistantText(let reply):
                        entries.append(Entry(kind: .assistant, text: reply))
                    case .toolStarted(let call):
                        let entry = Entry(kind: .tool(name: call.name, state: .running), text: "")
                        toolEntries[call.id] = entry.id
                        entries.append(entry)
                    case .toolFinished(let result):
                        guard let id = toolEntries[result.toolCallID],
                            let index = entries.firstIndex(where: { $0.id == id }),
                            case .tool(let name, _) = entries[index].kind
                        else { continue }
                        entries[index].kind = .tool(name: name, state: result.isError ? .failed : .succeeded)
                        entries[index].text = result.content
                    }
                }
            } catch is CancellationError {
                entries.append(Entry(kind: .error, text: "Stopped."))
            } catch {
                entries.append(Entry(kind: .error, text: String(describing: error)))
            }
        }
    }

    func stop() {
        turn?.cancel()
    }

    func clear() {
        stop()
        entries.removeAll()
        Task { await agent.reset() }
    }
}
