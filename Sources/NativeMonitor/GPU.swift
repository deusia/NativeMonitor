import Foundation
import IOKit
import Metal

struct GPUCapabilities {
    let name: String?
    let supportsNeuralAccelerator: Bool?
    let supportsRayTracing: Bool?
    let coreCount: Int?

    static func coreCount(from configuration: [String: Any]) -> Int? {
        func unsignedInteger(_ value: Any, maximum: Double) -> UInt64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= maximum, value.rounded(.towardZero) == value else { return nil }
            return number.uint64Value
        }
        guard let capacity = configuration["num_cores"].flatMap({ unsignedInteger($0, maximum: 4096) }), capacity > 0,
              let groups = configuration["num_mgpus"].flatMap({ unsignedInteger($0, maximum: 4096) }), groups > 0,
              let masks = configuration["core_mask_list"] as? [Any], masks.count == Int(groups) else { return nil }
        let values = masks.compactMap { unsignedInteger($0, maximum: 9_007_199_254_740_991) }
        guard values.count == masks.count else { return nil }
        // num_cores 与本机系统报告不一致；仅在掩码完整时推算启用核心数。
        let active = values.reduce(0) { $0 + $1.nonzeroBitCount }
        guard active > 0, active <= capacity else { return nil }
        return active
    }
    static func detect() -> GPUCapabilities {
        let device = MTLCreateSystemDefaultDevice()
        var neural: Bool?
        if #available(macOS 15.0, *), let device { neural = device.supportsFamily(.apple10) }
        var iterator: io_iterator_t = 0
        var counts: [Int?] = []
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let driver = IORegistryEntryCreateCFProperty(service, "IOClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                      driver.hasPrefix("AGX") else { continue }
                let config = IORegistryEntryCreateCFProperty(service, "GPUConfigurationVariable" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                counts.append(config.flatMap { coreCount(from: $0) })
            }
        }
        return GPUCapabilities(name: device?.name, supportsNeuralAccelerator: neural,
                               supportsRayTracing: device?.supportsRaytracing, coreCount: counts.count == 1 ? counts[0] : nil)
    }
}

struct GPUReading {
    let date: Date
    let driver: String
    let utilization: Double
    let renderer: Double?
    let tiler: Double?
    var allocatedMemory: UInt64? = nil
    var usedMemory: UInt64? = nil
    var deviceName: String? = nil
    var recommendedWorkingSet: UInt64? = nil

    static func parse(_ statistics: [String: Any], driver: String, date: Date = Date()) throws(GPUReadError) -> GPUReading {
        func percent(_ key: String) -> Double? {
            guard let number = statistics[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite && (0...100).contains(value) ? value : nil
        }
        func bytes(_ key: String) -> UInt64? {
            guard let number = statistics[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value < Double(UInt64.max), value.rounded(.towardZero) == value else { return nil }
            return number.uint64Value
        }
        guard let value = percent("Device Utilization %") else { throw GPUReadError.invalidCounter }
        return GPUReading(date: date, driver: driver, utilization: value,
                          renderer: percent("Renderer Utilization %"), tiler: percent("Tiler Utilization %"),
                          allocatedMemory: bytes("Alloc system memory"), usedMemory: bytes("In use system memory"))
    }
}
enum GPUReadError: Error, LocalizedError {
    case unavailable, ambiguous, invalidCounter
    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前驱动未提供 GPU 计数器；稍后自动重试。"
        case .ambiguous: return "检测到多个 GPU 数据源，暂不合并利用率。"
        case .invalidCounter: return "GPU 计数器缺失或超出范围；稍后自动重试。"
        }
    }
}
enum GPUReader {
    static let capabilities = GPUCapabilities.detect()
    static func read() -> Result<GPUReading, GPUReadError> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return .failure(.unavailable)
        }
        defer { IOObjectRelease(iterator) }
        var candidates: [(String, [String: Any])] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let driver = IORegistryEntryCreateCFProperty(service, "IOClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  driver.hasPrefix("AGX"),
                  let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            candidates.append((driver, statistics))
        }
        guard let candidate = candidates.first else { return .failure(.unavailable) }
        guard candidates.count == 1 else { return .failure(.ambiguous) }
        // shortcut: 驱动字段没有稳定公开契约；支持其他硬件前必须重新核实来源与口径。
        do {
            var reading = try GPUReading.parse(candidate.1, driver: candidate.0)
            if let device = MTLCreateSystemDefaultDevice() {
                reading.deviceName = device.name
                reading.recommendedWorkingSet = device.recommendedMaxWorkingSetSize
            }
            return .success(reading)
        }
        catch { return .failure(error) }
    }
}
