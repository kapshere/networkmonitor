#if canImport(Darwin)
import Darwin

public enum InterfaceStatsError: Error, CustomStringConvertible {
    case systemCall(String, Int32)

    public var description: String {
        switch self {
        case .systemCall(let name, let code): return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Reads interface state from the kernel without any privileges:
/// `getifaddrs` for names, flags and addresses, and the `NET_RT_IFLIST2`
/// routing sysctl for 64-bit traffic counters.
public struct SystemInterfaceStatsProvider: InterfaceStatsProvider {
    public init() {}

    public func snapshot() throws -> [InterfaceSnapshot] {
        let counters = try Self.linkCounters()

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw InterfaceStatsError.systemCall("getifaddrs", errno) }
        defer { freeifaddrs(head) }

        var byName: [String: InterfaceSnapshot] = [:]
        var cursor = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let name = String(cString: entry.pointee.ifa_name)
            var snapshot = byName[name] ?? Self.makeSnapshot(
                name: name, flags: Int32(bitPattern: entry.pointee.ifa_flags), counters: counters)
            if let address = entry.pointee.ifa_addr, let host = Self.numericHost(address) {
                snapshot.addresses.append(host)
            }
            byName[name] = snapshot
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    private struct LinkCounters {
        var mtu: UInt32
        var baudRate: UInt64
        var bytesIn, bytesOut, packetsIn, packetsOut, errorsIn, errorsOut: UInt64
    }

    private static func makeSnapshot(name: String, flags: Int32, counters: [UInt32: LinkCounters]) -> InterfaceSnapshot {
        var snapshot = InterfaceSnapshot(
            name: name,
            isUp: flags & IFF_UP != 0,
            isRunning: flags & IFF_RUNNING != 0,
            isLoopback: flags & IFF_LOOPBACK != 0,
            mtu: 0)
        if let link = counters[if_nametoindex(name)] {
            snapshot.mtu = link.mtu
            snapshot.linkSpeedBitsPerSecond = link.baudRate
            snapshot.bytesIn = link.bytesIn
            snapshot.bytesOut = link.bytesOut
            snapshot.packetsIn = link.packetsIn
            snapshot.packetsOut = link.packetsOut
            snapshot.errorsIn = link.errorsIn
            snapshot.errorsOut = link.errorsOut
        }
        return snapshot
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard status == 0 else { return nil }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 64-bit counters keyed by interface index.
    private static func linkCounters() throws -> [UInt32: LinkCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var buffer: [UInt8] = []
        var length = 0

        // Interfaces can appear between the size probe and the read; retry on ENOMEM.
        for attempt in 1...3 {
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else {
                throw InterfaceStatsError.systemCall("sysctl(NET_RT_IFLIST2)", errno)
            }
            length += length / 8
            buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 { break }
            if errno != ENOMEM || attempt == 3 {
                throw InterfaceStatsError.systemCall("sysctl(NET_RT_IFLIST2)", errno)
            }
        }

        var result: [UInt32: LinkCounters] = [:]
        buffer.withUnsafeBytes { raw in
            let headerSize = MemoryLayout<if_msghdr>.size
            var offset = 0
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let data = info.ifm_data
                    result[UInt32(info.ifm_index)] = LinkCounters(
                        mtu: data.ifi_mtu,
                        baudRate: data.ifi_baudrate,
                        bytesIn: data.ifi_ibytes,
                        bytesOut: data.ifi_obytes,
                        packetsIn: data.ifi_ipackets,
                        packetsOut: data.ifi_opackets,
                        errorsIn: data.ifi_ierrors,
                        errorsOut: data.ifi_oerrors)
                }
                offset += messageLength
            }
        }
        return result
    }
}
#else
import AgentCore

public struct SystemInterfaceStatsProvider: InterfaceStatsProvider {
    public init() {}
    public func snapshot() throws -> [InterfaceSnapshot] {
        throw ToolError.unavailable("interface stats are only implemented on macOS")
    }
}
#endif
