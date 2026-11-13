import Foundation

// 状态只由单个进行中的系统采样任务访问；GPU 采样不访问该状态。
final class MonitorCollector: @unchecked Sendable {
    private var previousCPU: CPUCounters?
    private var previousDisk: (TimeInterval, Counters)?
    private var previousNetwork: (TimeInterval, [InterfaceCounters])?
    private static func text(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(suffix)"
    }
    private static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return Self.text(Double(value) / 1_000_000_000, suffix: "GB")
    }
    func read() -> [Metric: MetricReading] {
        let date = Date(), uptime = ProcessInfo.processInfo.systemUptime
        var result: [Metric: MetricReading] = [:]
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        let cpu = SystemReader.cpu()
        let percentages = cpu.flatMap { current in previousCPU.flatMap { current.percentages(since: $0) } }
        previousCPU = cpu
        result[.cpu] = MetricReading(date: date, value: percentages.map { $0.0 + $0.1 }, status: percentages == nil ? "等待 CPU 采样" : "整机使用率", facts: [
            Fact(label: "用户", value: Self.text(percentages?.0, suffix: "%")), Fact(label: "系统", value: Self.text(percentages?.1, suffix: "%")), Fact(label: "空闲", value: Self.text(percentages?.2, suffix: "%"))
        ], rows: [Fact(label: "逻辑核心", value: "\(ProcessInfo.processInfo.activeProcessorCount) / \(ProcessInfo.processInfo.processorCount)"), Fact(label: "运行时间", value: Self.text(uptime / 3600, suffix: "小时")), Fact(label: "系统负载（1 / 5 / 15 分钟）", value: loadCount == 3 ? loads.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / ") : "—")])
        if let memory = SystemReader.memory() {
            result[.memory] = MetricReading(date: date, value: Double(memory.used) / 1e9, status: "活跃 + 不可换出 + 压缩", facts: [
                Fact(label: "物理内存", value: Self.bytes(memory.total)), Fact(label: "压缩", value: Self.bytes(memory.compressed)), Fact(label: "交换已用", value: Self.bytes(memory.swapUsed))
            ], rows: [Fact(label: "活跃", value: Self.bytes(memory.active)), Fact(label: "不可换出", value: Self.bytes(memory.wired)), Fact(label: "非活跃页", value: Self.bytes(memory.inactive)), Fact(label: "空闲页", value: Self.bytes(memory.free)), Fact(label: "已用比例", value: Self.text(Double(memory.used) / Double(memory.total) * 100, suffix: "%"))])
        } else { result[.memory] = Self.unavailable(date, "内存数据不可用") }
        let disk = SystemReader.disk()
        let diskRates = disk.flatMap { current in previousDisk.flatMap { current.rates(since: $0.1, seconds: uptime - $0.0) } }
        previousDisk = disk.map { (uptime, $0) }
        let volume = SystemReader.volume()
        result[.disk] = MetricReading(date: date, value: diskRates.map { $0.0 / 1e6 }, status: disk == nil ? "磁盘计数器不可用" : diskRates == nil ? "等待磁盘采样" : "设备读取速率", facts: [
            Fact(label: "读取", value: Self.text(diskRates.map { $0.0 / 1e6 }, suffix: "MB/s")), Fact(label: "写入", value: Self.text(diskRates.map { $0.1 / 1e6 }, suffix: "MB/s")), Fact(label: "可用容量", value: Self.bytes(volume?.available))
        ], rows: [Fact(label: "主目录卷总容量", value: Self.bytes(volume?.total)), Fact(label: "主目录卷可用", value: Self.bytes(volume?.available)), Fact(label: "设备累计读取", value: Self.bytes(disk?.first)), Fact(label: "设备累计写入", value: Self.bytes(disk?.second))])
        let interfaces = SystemReader.network()
        var networkRates: (Double, Double)?
        if let interfaces, !interfaces.isEmpty, let old = previousNetwork,
           interfaces.map(\.name) == old.1.map(\.name), uptime > old.0 {
            let rates = zip(interfaces, old.1).map { $0.counters.rates(since: $1.counters, seconds: uptime - old.0) }
            if rates.allSatisfy({ $0 != nil }) { networkRates = rates.compactMap { $0 }.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) } }
        }
        previousNetwork = interfaces.map { (uptime, $0) }
        let networkStatus = interfaces == nil ? "网络计数器不可用" : interfaces!.isEmpty ? "无运行中的 en 接口" : networkRates == nil ? "等待网络采样" : "接口接收速率"
        let received = interfaces?.reduce(UInt64(0)) { $0 &+ $1.counters.first }
        let sent = interfaces?.reduce(UInt64(0)) { $0 &+ $1.counters.second }
        result[.network] = MetricReading(date: date, value: networkRates.map { $0.0 / 1e6 }, status: networkStatus, facts: [
            Fact(label: "接收", value: Self.text(networkRates.map { $0.0 / 1e6 }, suffix: "MB/s")), Fact(label: "发送", value: Self.text(networkRates.map { $0.1 / 1e6 }, suffix: "MB/s")), Fact(label: "接口数", value: interfaces.map { "\($0.count)" } ?? "—")
        ], rows: [Fact(label: "运行中接口", value: interfaces.map { $0.isEmpty ? "无" : $0.map(\.name).joined(separator: ", ") } ?? "—"), Fact(label: "接口累计接收", value: Self.bytes(received)), Fact(label: "接口累计发送", value: Self.bytes(sent))])
        return result
    }
    static func readGPU() -> MetricReading {
        let date = Date()
        switch GPUReader.read() {
        case .success(let gpu):
            return MetricReading(date: date, value: gpu.utilization, status: "设备利用率", facts: [
                Fact(label: "渲染器", value: Self.text(gpu.renderer, suffix: "%")), Fact(label: "分块器", value: Self.text(gpu.tiler, suffix: "%")), Fact(label: "采样", value: "每 2 秒")
            ], rows: [Fact(label: "数据源", value: "IORegistry · PerformanceStatistics"), Fact(label: "驱动", value: gpu.driver), Fact(label: "最后更新", value: date.formatted(date: .omitted, time: .standard))])
        case .failure(let error): return Self.unavailable(date, error.localizedDescription)
        }
    }
    private static func unavailable(_ date: Date, _ reason: String) -> MetricReading {
        MetricReading(date: date, value: nil, status: reason, facts: [], rows: [])
    }
}
