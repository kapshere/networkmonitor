import AgentCore
import NetworkTools

enum AgentFactory {
    static let systemPrompt = """
        You are a personal assistant living in the macOS menu bar. You help the user understand \
        and manage their Mac's network. Use tools to get facts instead of guessing, and keep answers short.
        """

    static func makeAgent() -> Agent {
        let tools = ToolRegistry([
            NetworkInterfaceStatsTool(),
        ])
        // Swap for a real LanguageModel client once one exists; nothing else changes.
        let model = StubModel(routes: [
            .init(
                keywords: ["network", "interface", "traffic", "bandwidth", "throughput", "wifi", "wi-fi", "ethernet", "ip"],
                toolName: NetworkInterfaceStatsTool.name),
        ])
        return Agent(model: model, tools: tools, configuration: .init(systemPrompt: systemPrompt))
    }
}
