# Network Monitor

A personal AI agent that lives in the macOS menu bar. Click the icon, ask about your network in a chat popover, and the agent answers by calling tools on your Mac.

This is the scaffold: the agent loop, tool protocol and UI are real; the model is an offline stub.

## Layout

| Target | What it is |
| --- | --- |
| `AgentCore` | Provider-agnostic agent: `Message`/`ContentBlock` types, `Tool` protocol, `ToolRegistry`, the `Agent` actor (model ⇄ tool loop with a call limit, cancellation and history rollback), and `StubModel`. No UI, no OS calls. |
| `NetworkTools` | Read-only system tools. `network_interface_stats` lists interfaces with addresses, MTU, link speed and 64-bit traffic counters (`getifaddrs` + `NET_RT_IFLIST2` sysctl), and can sample twice to report throughput. No privileges needed. |
| `NetworkMonitorApp` | SwiftUI `MenuBarExtra` (window style) with the chat popover. Runs as an accessory app (no Dock icon). |

## Run

Requires macOS 14+ and Xcode 15+ / Swift 5.9+.

```sh
swift run NetworkMonitor   # look for the network icon in the menu bar
swift test
```

Or `open Package.swift` in Xcode and run the `NetworkMonitor` scheme.

Try: "show my network interfaces" or "how much traffic is going through wifi".

## Adding a tool

Conform to `Tool`, declare a JSON Schema in `spec.inputSchema`, validate input in `run`, return text (JSON preferred), and register it in `AgentFactory`. Set `access` honestly: anything other than `.readOnly` will need user confirmation once that gate exists.

## Not done yet

- Real model client (implement `LanguageModel` against the Anthropic Messages API; API key in Keychain).
- Confirmation gate for `.mutating` / `.privileged` tools.
- Privileged helper (SMAppService) for firewall/cleanup tools.
- Conversation persistence, streaming text.
- Signed `.app` bundle (currently an SPM executable).
