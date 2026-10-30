/// Point-in-time state of one network interface. Counters are cumulative
/// since boot (64-bit, so they don't wrap at 4 GiB like `if_data`).
public struct InterfaceSnapshot: Sendable, Equatable {
    public var name: String
    public var isUp: Bool
    public var isRunning: Bool
    public var isLoopback: Bool
    public var mtu: UInt32
    public var linkSpeedBitsPerSecond: UInt64
    public var addresses: [String]
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var packetsIn: UInt64
    public var packetsOut: UInt64
    public var errorsIn: UInt64
    public var errorsOut: UInt64

    public init(
        name: String, isUp: Bool = true, isRunning: Bool = true, isLoopback: Bool = false,
        mtu: UInt32 = 1500, linkSpeedBitsPerSecond: UInt64 = 0, addresses: [String] = [],
        bytesIn: UInt64 = 0, bytesOut: UInt64 = 0, packetsIn: UInt64 = 0, packetsOut: UInt64 = 0,
        errorsIn: UInt64 = 0, errorsOut: UInt64 = 0
    ) {
        self.name = name
        self.isUp = isUp
        self.isRunning = isRunning
        self.isLoopback = isLoopback
        self.mtu = mtu
        self.linkSpeedBitsPerSecond = linkSpeedBitsPerSecond
        self.addresses = addresses
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
        self.errorsIn = errorsIn
        self.errorsOut = errorsOut
    }

    public var isActive: Bool { isUp && isRunning }
}

/// Source of interface snapshots. Abstracted so the tool is testable without a live system.
public protocol InterfaceStatsProvider: Sendable {
    func snapshot() throws -> [InterfaceSnapshot]
}
