import Foundation
import Darwin
import IOKit

struct Counters: Equatable {
    let first: UInt64
    let second: UInt64
    func rates(since previous: Counters, seconds: TimeInterval) -> (Double, Double)? {
        guard seconds > 0, seconds.isFinite, first >= previous.first, second >= previous.second else { return nil }
        return (Double(first - previous.first) / seconds, Double(second - previous.second) / seconds)
    }
}

struct CPUCounters {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
    func percentages(since old: CPUCounters) -> (Double, Double, Double)? {
        guard user >= old.user, system >= old.system, idle >= old.idle, nice >= old.nice else { return nil }
        let u = Double(user - old.user) + Double(nice - old.nice)
        let s = Double(system - old.system), i = Double(idle - old.idle)
        let total = u + s + i
        guard total > 0 else { return nil }
        return (u / total * 100, s / total * 100, i / total * 100)
    }
}

struct MemoryReading {
    let total: UInt64
    let used: UInt64
    let active: UInt64
    let wired: UInt64
    let compressed: UInt64
    let free: UInt64
    let swapUsed: UInt64?
}
struct VolumeReading { let total: UInt64; let available: UInt64 }
struct InterfaceCounters { let name: String; let counters: Counters }

struct SystemReader {
    static func cpu() -> CPUCounters? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUCounters(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1), idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }
    static func memory() -> MemoryReading? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let active = UInt64(info.active_count) * page
        let wired = UInt64(info.wire_count) * page
        let compressed = UInt64(info.compressor_page_count) * page
        let free = UInt64(info.free_count) * page
        var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : nil
        // 已用口径为活跃、不可换出和压缩页，不将文件缓存当作已用。
        return MemoryReading(total: total, used: active + wired + compressed, active: active, wired: wired, compressed: compressed, free: free, swapUsed: swapUsed)
    }
    static func volume() -> VolumeReading? {
        var stats = statfs()
        guard statfs(NSHomeDirectory(), &stats) == 0 else { return nil }
        return VolumeReading(total: UInt64(stats.f_blocks) * UInt64(stats.f_bsize), available: UInt64(stats.f_bavail) * UInt64(stats.f_bsize))
    }
    static func network() -> [InterfaceCounters]? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var result: [InterfaceCounters] = []
        var cursor = list
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let entry = item.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            // 只统计硬件网络接口，避免 VPN 和桥接流量重复计算。
            guard name.hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            result.append(InterfaceCounters(name: name, counters: Counters(first: UInt64(counters.ifi_ibytes), second: UInt64(counters.ifi_obytes))))
        }
        return result.sorted { $0.name < $1.name }
    }
    static func disk() -> Counters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0, found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let r = statistics["Bytes (Read)"] as? NSNumber, let w = statistics["Bytes (Write)"] as? NSNumber else { continue }
            read &+= r.uint64Value; written &+= w.uint64Value; found = true
        }
        return found ? Counters(first: read, second: written) : nil
    }
}
