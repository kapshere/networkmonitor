import AgentCore
import XCTest
@testable import NetworkTools

/// Returns successive snapshots from a list, repeating the last one.
private final class FakeProvider: InterfaceStatsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[InterfaceSnapshot]]

    init(_ snapshots: [[InterfaceSnapshot]]) { self.snapshots = snapshots }

    func snapshot() throws -> [InterfaceSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }
}

private let instantWait: NetworkInterfaceStatsTool.Waiter = { $0 }

private func decode(_ output: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
}

private func names(_ report: JSONValue) -> [String] {
    guard case .array(let interfaces)? = report["interfaces"] else { return [] }
    return interfaces.compactMap { $0["name"]?.stringValue }
}

final class NetworkInterfaceStatsToolTests: XCTestCase {
    private let en0 = InterfaceSnapshot(name: "en0", addresses: ["192.168.1.2"], bytesIn: 1_000, bytesOut: 500, packetsIn: 10, packetsOut: 5)
    private let lo0 = InterfaceSnapshot(name: "lo0", isLoopback: true, mtu: 16384)
    private let en5 = InterfaceSnapshot(name: "en5", isUp: false, isRunning: false)

    func testDefaultsToActiveInterfacesOnly() async throws {
        let tool = NetworkInterfaceStatsTool(provider: FakeProvider([[en0, en5, lo0]]), wait: instantWait)
        let report = try decode(try await tool.run([:]))
        XCTAssertEqual(names(report), ["en0", "lo0"])
        XCTAssertNil(report["sampled_ms"])
        guard case .array(let interfaces)? = report["interfaces"] else { return XCTFail("missing interfaces") }
        XCTAssertEqual(interfaces.first?["totals"]?["bytes_in"], 1000)
    }

    func testIncludeInactiveAndInterfaceFilter() async throws {
        let tool = NetworkInterfaceStatsTool(provider: FakeProvider([[en0, en5, lo0]]), wait: instantWait)
        XCTAssertEqual(names(try decode(try await tool.run(["include_inactive": true]))), ["en0", "en5", "lo0"])
        XCTAssertEqual(names(try decode(try await tool.run(["interface": "en5"]))), ["en5"])
    }

    func testUnknownInterfaceListsAvailableOnes() async throws {
        let tool = NetworkInterfaceStatsTool(provider: FakeProvider([[en0]]), wait: instantWait)
        do {
            _ = try await tool.run(["interface": "utun9"])
            XCTFail("expected error")
        } catch let error as ToolError {
            XCTAssertEqual(error, .invalidInput("no interface named utun9. Available: en0"))
        }
    }

    func testRejectsBadInput() async {
        let tool = NetworkInterfaceStatsTool(provider: FakeProvider([[en0]]), wait: instantWait)
        for input: JSONValue in [[1], ["sample_ms": 10_000], ["sample_ms": 1.5], ["include_inactive": "yes"], ["bogus": 1]] {
            do {
                _ = try await tool.run(input)
                XCTFail("accepted \(input)")
            } catch {
                XCTAssertTrue(error is ToolError, "\(error)")
            }
        }
    }

    func testSamplingComputesRates() async throws {
        var later = en0
        later.bytesIn += 2_000
        later.bytesOut += 1_000
        later.packetsIn += 20
        later.packetsOut += 10
        let tool = NetworkInterfaceStatsTool(provider: FakeProvider([[en0], [later]]), wait: instantWait)

        let report = try decode(try await tool.run(["sample_ms": 2000]))

        XCTAssertEqual(report["sampled_ms"], 2000)
        guard case .array(let interfaces)? = report["interfaces"], let rate = interfaces.first?["rate"] else {
            return XCTFail("missing rate in \(report)")
        }
        XCTAssertEqual(rate["bytes_in_per_sec"], 1000)
        XCTAssertEqual(rate["bytes_out_per_sec"], 500)
        XCTAssertEqual(rate["packets_in_per_sec"], 10)
        XCTAssertEqual(rate["packets_out_per_sec"], 5)
    }

    func testCounterResetYieldsNoRate() {
        var reset = en0
        reset.bytesIn = 0
        XCTAssertNil(Rate(from: en0, to: reset, seconds: 1))
    }

    #if canImport(Darwin)
    func testSystemProviderSeesLoopback() throws {
        let snapshots = try SystemInterfaceStatsProvider().snapshot()
        let loopback = try XCTUnwrap(snapshots.first { $0.name == "lo0" })
        XCTAssertTrue(loopback.isLoopback)
        XCTAssertTrue(loopback.addresses.contains("127.0.0.1"))
        XCTAssertGreaterThan(loopback.mtu, 0)
    }
    #endif
}
