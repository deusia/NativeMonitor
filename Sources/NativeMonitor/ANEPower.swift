import Foundation
import Darwin

// 以驱动发布时间计算区间平均功率，未发布或停更不代表零功耗。
struct ANEPowerWindow {
    private var previous: (energy: Int64, time: Double, scale: Double)?
    private var lastPower: Double?

    mutating func update(energy: Int64, time: Double, now: Double, joulesPerUnit: Double) -> Double? {
        guard energy >= 0, time.isFinite, now.isFinite, joulesPerUnit > 0,
              time > 0, time <= now + 1, now - time <= 10 else {
            previous = nil; lastPower = nil; return nil
        }
        guard let old = previous else { previous = (energy, time, joulesPerUnit); return nil }
        guard time >= old.time, energy >= old.energy, joulesPerUnit == old.scale else {
            previous = (energy, time, joulesPerUnit); lastPower = nil; return nil
        }
        if time == old.time {
            if energy != old.energy { previous = nil; lastPower = nil }
            return lastPower
        }
        let elapsed = time - old.time
        // 同一批次的尾随发布合并到下一次，避免极短间隔放大误差。
        if elapsed < 0.05 { return lastPower }
        previous = (energy, time, joulesPerUnit)
        guard elapsed <= 10 else { lastPower = nil; return nil }
        let power = Double(energy - old.energy) * joulesPerUnit / elapsed
        guard power.isFinite, power >= 0, power <= 100 else { lastPower = nil; return nil }
        lastPower = power
        return power
    }
}

// IOReport 及 RawElements 为私有接口；布局或时间戳无效时返回不可用。
final class ANEPowerReader {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> UnsafeRawPointer?
    private typealias Samples = @convention(c) (UnsafeRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StringValue = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let library: UnsafeMutableRawPointer
    private let subscription: UnsafeRawPointer
    private let channels: CFMutableDictionary
    private let samples: Samples
    private let name: StringValue
    private let unit: StringValue
    private let integer: IntegerValue
    private var window = ANEPowerWindow()

    init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as: T.Type) -> T? {
            guard let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let copy = symbol("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let subscribe = symbol("IOReportCreateSubscription", as: Subscribe.self),
              let samples = symbol("IOReportCreateSamples", as: Samples.self),
              let name = symbol("IOReportChannelGetChannelName", as: StringValue.self),
              let unit = symbol("IOReportChannelGetUnitLabel", as: StringValue.self),
              let integer = symbol("IOReportSimpleGetIntegerValue", as: IntegerValue.self),
              let original = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() as NSDictionary?,
              let all = original["IOReportChannels"] as? [NSDictionary] else { dlclose(library); return nil }
        let ane = all.filter { item in
            guard let channel = name(item as CFDictionary)?.takeUnretainedValue() as String? else { return false }
            return channel.hasPrefix("ANE")
        }
        // shortcut: 只识别单个 ANE0，验证多芯片通道后再扩展。
        guard ane.count == 1, name(ane[0] as CFDictionary)?.takeUnretainedValue() as String? == "ANE0" else { dlclose(library); return nil }
        let selected = NSMutableDictionary(dictionary: original)
        selected["IOReportChannels"] = ane
        let channels = selected as CFMutableDictionary
        var response: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, channels, &response, 0, nil) else { response?.release(); dlclose(library); return nil }
        response?.release()
        self.library = library; self.subscription = subscription; self.channels = channels
        self.samples = samples; self.name = name; self.unit = unit; self.integer = integer
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(subscription).release()
        dlclose(library)
    }

    func read() -> Double? {
        func invalid() -> Double? { window = ANEPowerWindow(); return nil }
        guard let sample = samples(subscription, channels, nil)?.takeRetainedValue() as NSDictionary?,
              let items = sample["IOReportChannels"] as? [NSDictionary], items.count == 1 else { return invalid() }
        let item = items[0] as CFDictionary
        guard name(item)?.takeUnretainedValue() as String? == "ANE0",
              let label = unit(item)?.takeUnretainedValue() as String?,
              let data = items[0]["RawElements"] as? Data, data.count == 64 else { return invalid() }
        let scale: Double
        switch label.trimmingCharacters(in: .whitespaces) {
        case "mJ": scale = 1e-3
        case "uJ", "µJ": scale = 1e-6
        case "nJ": scale = 1e-9
        case "pJ": scale = 1e-12
        default: return invalid()
        }
        let energy = integer(item, 0)
        let timestamp = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }
        let stored = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: Int64.self) }
        guard stored == energy else { return invalid() }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return invalid() }
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        return window.update(energy: energy, time: Double(timestamp) * secondsPerTick,
                             now: Double(mach_absolute_time()) * secondsPerTick, joulesPerUnit: scale)
    }
}
