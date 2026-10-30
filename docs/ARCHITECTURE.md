# Architecture: personal agent for macOS

Status: draft, 2026-10-30. Nothing here is built yet.

## 1. What it is

A native Swift menu bar app that hosts a personal AI agent. You open a chat
popover, ask for something ("what's eating my bandwidth?", "block that
host", "free 20 GB"), and the agent answers by calling the Claude API with
tool use. The tools are typed Swift functions for network stats, connection
lookups, firewall rules and disk cleanup. The model never gets a shell.

Design goals, in priority order:

1. **The model can't do damage you didn't approve.** Destructive actions
   need an explicit confirmation that the model can't fake or route around.
2. **Least privilege per process.** Root and kernel-adjacent code lives in
   small, separate processes with narrow typed XPC interfaces.
3. **The tool layer is generic.** Network, firewall and disk are the first
   tool providers. Calendar, files and email plug in later the same way, with
   no changes to the agent loop.

Non-goals for v1: App Store distribution, multiple users, a cloud backend,
running unattended.

## 2. Process layout

```
┌───────────────────────────── user session ─────────────────────────────┐
│                                                                        │
│  NetworkMonitor.app  (menu bar, unprivileged, hardened runtime)        │
│  ┌──────────────┐  ┌────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Chat popover │→ │ Agent loop │→ │ Tool registry│→ │ Policy gate  │  │
│  │ (SwiftUI)    │← │            │← │ + providers  │← │ + confirm UI │  │
│  └──────────────┘  └─────┬──────┘  └──────┬───────┘  └──────────────┘  │
│                          │ HTTPS          │ XPC (typed, signed peers)  │
└──────────────────────────┼────────────────┼────────────────────────────┘
                           ▼                ├──────────────────────┐
                    api.anthropic.com       ▼                      ▼
                                 ┌────────────────────┐  ┌──────────────────────┐
                                 │ FilterExtension    │  │ PrivilegedHelper     │
                                 │ system extension   │  │ LaunchDaemon (root)  │
                                 │ NEFilterDataProv.  │  │ via SMAppService     │
                                 │ rules, flow stats  │  │ sockets of all procs,│
                                 └────────────────────┘  │ root-owned cleanup   │
                                                         └──────────────────────┘
```

| Process | Privilege | Owns | Why separate |
|---|---|---|---|
| App | user, hardened runtime, Developer ID | UI, agent loop, Claude client, tool registry, policy, audit log, conversation history | Holds the API key and talks to the model, so it gets no root. |
| FilterExtension | system extension, sandboxed, runs as root | Content filter, live rule set, per-flow byte counts with app attribution | NetworkExtension requires it. Keeps running when the app quits. |
| PrivilegedHelper | root LaunchDaemon, registered with `SMAppService.daemon` | Socket enumeration across all users, cleanup of root-owned paths | Only for work that actually needs root. Every method is typed and allow-listed. |

Distribution is Developer ID plus notarization. The main app isn't
sandboxed, because sandboxing blocks `proc_pidinfo` on other processes and
whole-disk scans, and the privileged parts are already isolated.

## 3. Agent loop

The loop lives in `AgentCore` and is a plain async state machine, testable
without UI:

```
user message
  → append to transcript
  → POST /v1/messages (stream: true, tools: registry.definitions)
  → stream text deltas to the popover
  → stop_reason == "tool_use"?
       yes → for each tool_use block:
               policy.evaluate(call) → allow | confirm | deny
               execute (read-only calls in parallel, mutating calls serially)
               append tool_result (is_error on failure, size-capped)
             loop
       no  → done
```

Details:

- **Client.** There's no official Swift SDK, so a thin `URLSession` client
  handles SSE streaming, retries with backoff on 429 and 529, and request
  cancellation. The API key is stored in the Keychain and never written to
  disk or logs.
- **Model.** Configurable. Default to `claude-sonnet-5-5` for latency and
  cost, with `claude-opus-5-5` as the "think harder" choice.
- **Prompt caching.** The system prompt and tool definitions are stable, so
  they get a `cache_control` breakpoint. That makes repeat turns cheap.
- **Bounds.** Each turn has a max tool round-trip count (default 12), a
  token budget, and a cancel button in the UI. Hitting a bound ends the turn
  with a visible message. It never fails silently.
- **Context management.** Old, bulky tool results are summarized or trimmed
  first, and the user's own messages are kept. Each tool result is capped
  (around 8 KB by default), and the tool says where it truncated so the
  model can narrow its query.
- **History.** Conversations are stored locally in SQLite (SwiftData is
  fine). They're never sent anywhere except as context to the API.

## 4. Tool layer

### 4.1 Contract

```swift
enum ToolRisk: Sendable { case read, mutating, destructive }

protocol Tool: Sendable {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    static var name: String { get }           // "network.connections.list"
    static var description: String { get }    // written for the model
    static var inputSchema: JSONSchema { get } // JSON Schema sent to the API
    static var risk: ToolRisk { get }

    /// For .destructive tools: compute exactly what would happen, with no side effects.
    func plan(_ input: Input, ctx: ToolContext) async throws -> ActionPlan?
    func run(_ input: Input, ctx: ToolContext) async throws -> Output
}

protocol ToolProvider {
    var tools: [any Tool] { get }   // registered into ToolRegistry at launch
}
```

- `ToolRegistry` type-erases tools to `AnyTool`. It turns each into an API
  tool definition, decodes `tool_use.input` into the typed `Input`, and
  encodes `Output` to JSON for the `tool_result`. If decoding fails, the
  model gets back an `is_error` result with the decoder's message so it can
  correct itself.
- Schemas are hand-written next to each `Input` type, and a unit test checks
  that the schema matches the type. Macro-based schema generation can come
  later if hand-writing them gets tedious.
- `ToolContext` carries cancellation, the XPC clients, and the audit logger.
  Tools never build their own connections.
- Names are namespaced (`disk.*`, `firewall.*`, later `calendar.*`), so you
  can enable or disable whole providers per conversation and in settings.

### 4.2 Policy gate and confirmation

The policy is separate from the tools. A tool declares its risk, and the
`PolicyGate` decides what happens:

| Risk | Default | Examples |
|---|---|---|
| `read` | runs automatically | interface stats, connection list, disk usage |
| `mutating` | confirm, with "allow for this session" | add a block rule, toggle the filter |
| `destructive` | always confirm, per call | delete files, empty caches, remove all rules |

Destructive calls take two phases, so the thing you approve is exactly the
thing that runs:

1. The gate calls `plan(input)`. That produces an `ActionPlan`, for example
   "delete these 412 paths, 18.3 GB", with the exact resolved list, hashed.
2. The popover shows the plan in native UI. The model can't answer the
   prompt, and the text isn't shown in the model's own words.
3. When you approve, `run` executes **that plan by its hash**, not the
   original input re-resolved. If the filesystem changed in between, the
   paths that drifted are skipped and reported.
4. If you reject, the model gets a `tool_result` saying "user declined", and
   the call never runs.

Every call is appended to a local audit log with its input, plan, decision
and outcome. You can view the log from settings.

### 4.3 Prompt-injection stance

Tool output (hostnames, process names, file names, and later email bodies
and calendar notes) is untrusted data that ends up in the model's context.
So:

- The confirmation gate is the hard boundary. Even a hijacked model can only
  *propose* destructive actions.
- Tool results are wrapped and labelled as data in the system prompt's
  conventions.
- The popover renders model output as plain styled text. Links aren't
  auto-followed, and nothing in the output is executable.
- Providers that ingest external content (email, files) can be marked
  `taintsContext`. Once one has run in a conversation, every `mutating` call
  is downgraded to per-call confirmation for the rest of it.

## 5. First tool providers

### Network (`network.*`, read)

| Tool | Source |
|---|---|
| `network.interfaces.stats` | `getifaddrs` plus `sysctl(NET_RT_IFLIST2)` for 64-bit byte counters, sampled into rates |
| `network.connections.list` | `proc_pidinfo` / `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. Own-user processes are read in the app; all processes go through the helper. |
| `network.connections.lookup` | Resolves host, port, PID or app bundle to its connections, plus reverse DNS |
| `network.usage.byApp` | Per-flow byte counts from the filter extension, attributed by the flow's audit token and code-signing identity |

Private frameworks like NetworkStatistics are out. They break across OS
updates.

### Firewall (`firewall.*`)

- Implemented as an `NEFilterDataProvider` in the system extension. The app
  installs it with `OSSystemExtensionRequest` and enables it with
  `NEFilterManager`.
- **The extension owns the rule set** and persists it in its own container.
  That way rules keep working while the app isn't running.
- Rules are typed: match on signing identifier / team ID, remote host or CIDR,
  port, protocol, direction. The action is `allow` or `drop`. The default
  policy is allow-all with explicit drops. That's a monitor with a block
  list, not a deny-by-default firewall.
- Tools: `firewall.rules.list` (read), `firewall.rules.add` and
  `firewall.rules.update` (mutating), `firewall.rules.remove` and
  `firewall.rules.clear` (destructive), and `firewall.filter.setEnabled`
  (mutating).
- Matching in `handleNewFlow` has to be fast and allocation-light. The rule
  set is compiled to an in-memory index when it changes, never on each flow.

### Disk (`disk.*`)

- `disk.usage.summary` (volume totals, purgeable space) and
  `disk.usage.scan(path, depth)` (largest directories, done incrementally and
  cancellable), both read.
- `disk.cleanup.candidates` (read) uses known categories: user caches, Xcode
  DerivedData and simulators, old logs, Trash, package-manager caches. Each
  category has its own explicit path rules, not model-chosen globs.
- `disk.cleanup.execute` is destructive and goes through the two-phase plan.
  Files are moved to the Trash by default, and permanent delete is a separate
  opt-in. Only paths from the plan, inside allow-listed roots, are accepted.
  Root-owned paths go to the helper.
- Scanning protected locations needs Full Disk Access (TCC). The app detects
  when it's missing and tells you how to grant it, instead of failing
  quietly.

## 6. XPC contracts

- A shared `XPCContracts` package defines one protocol per service plus
  Codable request and response types. Both sides compile against it.
- Transport is `NSXPCConnection`. Payloads are `Codable` encoded to `Data`,
  so the interface stays Swift types without `@objc` gymnastics leaking
  everywhere. Calls are wrapped as `async throws`.
- **Peer validation on both ends**: `setCodeSigningRequirement` pins team ID
  and bundle identifier. The helper and the extension refuse any unsigned or
  foreign client.
- The services expose verbs, not mechanisms: `listSockets()`,
  `trash(planID:paths:)`, `apply(ruleSet:)`. There's no `run(command:)` and no
  arbitrary path writes. The helper checks every path against its own
  allow-list even though the app already did.
- Each interface is versioned (`protocolVersion` handshake), so a stale
  helper after an app update gets detected and re-registered.

## 7. Adding future providers

A new capability is one `ToolProvider` module:

- `calendar.*`: EventKit (needs a TCC prompt). Reads are `read`, creating
  events is `mutating`, deleting is `destructive`.
- `files.*`: search, read and move within user-chosen roots. Moves and
  deletes reuse the disk provider's plan mechanism.
- `email.*`: likely through IMAP/Gmail API, or Mail via AppleScript bridged
  in-process. Sending is `destructive`, because it can't be undone, and it's
  marked `taintsContext`.
- An optional MCP client provider could expose external MCP servers' tools
  through the same registry and policy gate, without trusting their risk
  labels. Unknown tools default to `mutating`.

None of these need changes to `AgentCore`, the policy gate, or the popover.

## 8. Code layout

```
NetworkMonitor.xcodeproj
Packages/
  AgentCore/        loop, Claude client, transcript, streaming (no AppKit)
  ToolKit/          Tool protocol, registry, JSON Schema, PolicyGate, ActionPlan, audit
  XPCContracts/     shared protocols and DTOs
  Providers/
    NetworkTools/
    FirewallTools/
    DiskTools/
Targets/
  App/              MenuBarExtra(.window) popover, settings, confirmation sheets
  FilterExtension/  NEFilterDataProvider, rule store
  PrivilegedHelper/ launchd daemon
```

`AgentCore` and `ToolKit` have no Apple-UI dependencies, so they get unit
tests against a mocked HTTP transport and fake tools. The providers are
tested against fixtures, and the XPC services are tested through their
contract protocols with in-process fakes.

## 9. Open questions

1. Minimum macOS. Targeting 14+ keeps `MenuBarExtra`, `SMAppService` and
   modern Swift concurrency simple.
2. Do we want per-app bandwidth in v1? It requires the filter extension to be
   installed and approved, which is the heaviest onboarding step.
3. Should "allow for this session" exist for `mutating` firewall changes, or
   should every rule change be confirmed?
4. Is local-only history enough, or should conversations sync via iCloud
   later?
