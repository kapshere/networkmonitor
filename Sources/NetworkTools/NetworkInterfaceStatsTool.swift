import AgentCore
import Foundation

/// Read-only tool: lists network interfaces with addresses and traffic
/// counters, optionally sampling twice to report current throughput.
public struct NetworkInterfaceStatsTool: Tool {
    public static let name = "network_interface_stats"
    public static let maxSampleMilliseconds = 5_000

    /// Sleeps for the requested duration and returns the time that actually elapsed.
    public typealias Waiter = @Sendable (Duration) async throws -> Duration

    private let provider: any InterfaceStatsProvider
    private let wait: Waiter

    public init(provider: any InterfaceStatsProvider = SystemInterfaceStatsProvider(), wait: @escaping Waiter = NetworkInterfaceStatsTool.sleep) {
        self.provider = provider
        self.wait = wait
    }

    public static let sleep: Waiter = { duration in
        let clock = ContinuousClock()
        let start = clock.now
        try await Task.sleep(for: duration)
        return start.duration(to: clock.now)
    }

    public var access: ToolAccess { .readOnly }

    public var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: """
                List the Mac's network interfaces with their IP addresses, MTU, link speed and \
                cumulative traffic counters since boot. Set sample_ms to also measure current \
                throughput over that window.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "interface": [
                        "type": "string",
                        "description": "Only report this interface, e.g. en0.",
                    ],
                    "include_inactive": [
                        "type": "boolean",
                        "description": "Include interfaces that are down or not running. Default false.",
                    ],
                    "sample_ms": [
                        "type": "integer",
                        "minimum": 0,
                        "maximum": .number(Double(Self.maxSampleMilliseconds)),
                        "description": "Sample counters twice this many milliseconds apart to compute rates. Default 0 (no sampling).",
                    ],
                ],
                "additionalProperties": false,
            ])
    }

    public func run(_ input: JSONValue) async throws -> String {
        let request = try Request(input)

        let first = try filter(provider.snapshot(), request)
        var interfaces = first.map(InterfaceReport.init)
        var sampledMilliseconds: Int?

        if request.sampleMilliseconds > 0 {
            let elapsed = try await wait(.milliseconds(request.sampleMilliseconds))
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let later = try provider.snapshot()
            let second = Dictionary(later.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
            if seconds > 0 {
                for index in interfaces.indices {
                    guard let current = second[interfaces[index].name] else { continue }
                    interfaces[index].rate = Rate(from: first[index], to: current, seconds: seconds)
                }
            }
            sampledMilliseconds = Int((seconds * 1000).rounded())
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Report(sampledMs: sampledMilliseconds, interfaces: interfaces))
        return String(decoding: data, as: UTF8.self)
    }

    private func filter(_ snapshots: [InterfaceSnapshot], _ request: Request) throws -> [InterfaceSnapshot] {
        if let name = request.interface {
            guard let match = snapshots.first(where: { $0.name == name }) else {
                let available = snapshots.map(\.name).joined(separator: ", ")
                throw ToolError.invalidInput("no interface named \(name). Available: \(available)")
            }
            return [match]
        }
        return request.includeInactive ? snapshots : snapshots.filter(\.isActive)
    }
}

private struct Request {
    var interface: String?
    var includeInactive = false
    var sampleMilliseconds = 0

    init(_ input: JSONValue) throws {
        guard case .object(let fields) = input else { throw ToolError.invalidInput("expected an object") }
        let known: Set = ["interface", "include_inactive", "sample_ms"]
        if let unknown = fields.keys.first(where: { !known.contains($0) }) {
            throw ToolError.invalidInput("unknown field \(unknown)")
        }
        if let value = fields["interface"], !value.isNull {
            guard let name = value.stringValue, !name.isEmpty else {
                throw ToolError.invalidInput("interface must be a non-empty string")
            }
            interface = name
        }
        if let value = fields["include_inactive"], !value.isNull {
            guard let flag = value.boolValue else { throw ToolError.invalidInput("include_inactive must be a boolean") }
            includeInactive = flag
        }
        if let value = fields["sample_ms"], !value.isNull {
            guard let number = value.doubleValue, number >= 0, number.rounded() == number,
                number <= Double(NetworkInterfaceStatsTool.maxSampleMilliseconds)
            else {
                throw ToolError.invalidInput(
                    "sample_ms must be an integer between 0 and \(NetworkInterfaceStatsTool.maxSampleMilliseconds)")
            }
            sampleMilliseconds = Int(number)
        }
    }
}

private struct Report: Encodable {
    var sampledMs: Int?
    var interfaces: [InterfaceReport]
}

private struct InterfaceReport: Encodable {
    struct Totals: Encodable {
        var bytesIn, bytesOut, packetsIn, packetsOut, errorsIn, errorsOut: UInt64
    }

    var name: String
    var up: Bool
    var running: Bool
    var loopback: Bool
    var mtu: UInt32
    var linkSpeedBps: UInt64
    var addresses: [String]
    var totals: Totals
    var rate: Rate?

    init(_ snapshot: InterfaceSnapshot) {
        name = snapshot.name
        up = snapshot.isUp
        running = snapshot.isRunning
        loopback = snapshot.isLoopback
        mtu = snapshot.mtu
        linkSpeedBps = snapshot.linkSpeedBitsPerSecond
        addresses = snapshot.addresses
        totals = Totals(
            bytesIn: snapshot.bytesIn, bytesOut: snapshot.bytesOut,
            packetsIn: snapshot.packetsIn, packetsOut: snapshot.packetsOut,
            errorsIn: snapshot.errorsIn, errorsOut: snapshot.errorsOut)
    }
}

struct Rate: Encodable, Equatable {
    var bytesInPerSec: Double
    var bytesOutPerSec: Double
    var packetsInPerSec: Double
    var packetsOutPerSec: Double

    /// Returns nil if any counter went backwards (interface reset between samples).
    init?(from earlier: InterfaceSnapshot, to later: InterfaceSnapshot, seconds: Double) {
        func perSecond(_ a: UInt64, _ b: UInt64) -> Double? { b >= a ? Double(b - a) / seconds : nil }
        guard let bytesIn = perSecond(earlier.bytesIn, later.bytesIn),
            let bytesOut = perSecond(earlier.bytesOut, later.bytesOut),
            let packetsIn = perSecond(earlier.packetsIn, later.packetsIn),
            let packetsOut = perSecond(earlier.packetsOut, later.packetsOut)
        else { return nil }
        bytesInPerSec = bytesIn
        bytesOutPerSec = bytesOut
        packetsInPerSec = packetsIn
        packetsOutPerSec = packetsOut
    }
}
