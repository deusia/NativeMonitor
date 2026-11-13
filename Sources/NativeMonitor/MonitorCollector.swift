import Foundation

// 状态只由单个进行中的系统采样任务访问；GPU 采样不访问该状态。
final class MonitorCollector: @unchecked Sendable {
    private var previousCPU: [CPUCounters]?
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
    private static func memoryBytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return Self.text(ValueFormat.memoryGigabytes(value), suffix: "GB")
    }
    func read() -> [Metric: MetricReading] {
        let date = Date(), uptime = ProcessInfo.processInfo.systemUptime
        var result: [Metric: MetricReading] = [:]
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        let cpu = SystemReader.cpuCores()
        let corePercentages: [(Double, Double, Double)?]
        if let cpu, let previousCPU, cpu.count == previousCPU.count {
            corePercentages = zip(cpu, previousCPU).map { $0.percentages(since: $1) }
        } else { corePercentages = Array(repeating: nil, count: cpu?.count ?? 0) }
        previousCPU = cpu
        let validCores = corePercentages.compactMap { $0 }
        let total = !corePercentages.isEmpty && validCores.count == corePercentages.count ? validCores.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) } : nil
        result[.cpu] = MetricReading(date: date, value: total.map { $0.0 + $0.1 }, status: total == nil ? "等待 CPU 采样" : "核心使用率之和", facts: [
            Fact(label: "用户", value: Self.text(total?.0, suffix: "%")), Fact(label: "系统", value: Self.text(total?.1, suffix: "%")), Fact(label: "空闲", value: Self.text(total?.2, suffix: "%"))
        ], rows: [Fact(label: "逻辑核心", value: "\(cpu?.count ?? 0)"), Fact(label: "运行时间", value: Self.text(uptime / 3600, suffix: "小时")), Fact(label: "系统负载（1 / 5 / 15 分钟）", value: loadCount == 3 ? loads.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / ") : "—")], cores: corePercentages.map { $0.map { $0.0 + $0.1 } }, cpuParts: total.map { [$0.0, $0.1, $0.2] } ?? [], series: total.map { ["用户": $0.0, "系统": $0.1] } ?? [:])
        if let memory = SystemReader.memory() {
            result[.memory] = MetricReading(date: date, value: ValueFormat.memoryGigabytes(memory.used), status: "活跃 + 不可换出 + 压缩", facts: [
                Fact(label: "物理内存", value: Self.memoryBytes(memory.total)), Fact(label: "压缩", value: Self.memoryBytes(memory.compressed)), Fact(label: "交换已用", value: Self.memoryBytes(memory.swapUsed))
            ], rows: [Fact(label: "活跃", value: Self.memoryBytes(memory.active)), Fact(label: "不可换出", value: Self.memoryBytes(memory.wired)), Fact(label: "非活跃页", value: Self.memoryBytes(memory.inactive)), Fact(label: "空闲页", value: Self.memoryBytes(memory.free)), Fact(label: "已用比例", value: Self.text(Double(memory.used) / Double(memory.total) * 100, suffix: "%"))], series: ["活跃": ValueFormat.memoryGigabytes(memory.active), "非活跃": ValueFormat.memoryGigabytes(memory.inactive), "不可换出": ValueFormat.memoryGigabytes(memory.wired), "压缩": ValueFormat.memoryGigabytes(memory.compressed), "空闲": ValueFormat.memoryGigabytes(memory.free)])
        } else { result[.memory] = Self.unavailable(date, "内存数据不可用") }
        let disk = SystemReader.disk()
        let diskRates = disk.flatMap { current in previousDisk.flatMap { current.rates(since: $0.1, seconds: uptime - $0.0) } }
        previousDisk = disk.map { (uptime, $0) }
        let volume = SystemReader.volume()
        result[.disk] = MetricReading(date: date, value: diskRates.map { $0.0 / 1e6 }, status: disk == nil ? "磁盘计数器不可用" : diskRates == nil ? "等待磁盘采样" : "设备读取速率", facts: [
            Fact(label: "读取", value: diskRates.map { ValueFormat.rate($0.0, precision: 1) } ?? "—"), Fact(label: "写入", value: diskRates.map { ValueFormat.rate($0.1, precision: 1) } ?? "—"), Fact(label: "可用容量", value: Self.bytes(volume?.available))
        ], rows: [Fact(label: "主目录卷总容量", value: Self.bytes(volume?.total)), Fact(label: "主目录卷可用", value: Self.bytes(volume?.available)), Fact(label: "设备累计读取", value: Self.bytes(disk?.first)), Fact(label: "设备累计写入", value: Self.bytes(disk?.second))], series: diskRates.map { ["读取": $0.0 / 1e6, "写入": $0.1 / 1e6] } ?? [:])
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
            Fact(label: "接收", value: networkRates.map { ValueFormat.rate($0.0, precision: 1) } ?? "—"), Fact(label: "发送", value: networkRates.map { ValueFormat.rate($0.1, precision: 1) } ?? "—"), Fact(label: "接口数", value: interfaces.map { "\($0.count)" } ?? "—")
        ], rows: [Fact(label: "运行中接口", value: interfaces.map { $0.isEmpty ? "无" : $0.map(\.name).joined(separator: ", ") } ?? "—"), Fact(label: "接口累计接收", value: Self.bytes(received)), Fact(label: "接口累计发送", value: Self.bytes(sent))], series: networkRates.map { ["接收": $0.0 / 1e6, "发送": $0.1 / 1e6] } ?? [:])
        return result
    }
    static func readGPU() -> MetricReading {
        let date = Date()
        switch GPUReader.read() {
        case .success(let gpu):
            var series = ["设备": gpu.utilization]
            if let value = gpu.renderer { series["渲染器"] = value }
            if let value = gpu.tiler { series["分块器"] = value }
            return MetricReading(date: date, value: gpu.utilization, status: "设备利用率", facts: [
                Fact(label: "GPU 核心数", value: GPUReader.capabilities.coreCount.map { "\($0) 核" } ?? "—"), Fact(label: "渲染器", value: Self.text(gpu.renderer, suffix: "%")), Fact(label: "分块器", value: Self.text(gpu.tiler, suffix: "%")), Fact(label: "驱动已用系统内存", value: Self.bytes(gpu.usedMemory))
            ], rows: [Fact(label: "设备", value: gpu.deviceName ?? "—"), Fact(label: "驱动", value: gpu.driver),
                      Fact(label: "驱动分配系统内存", value: Self.bytes(gpu.allocatedMemory)),
                      Fact(label: "Metal 建议工作集", value: Self.bytes(gpu.recommendedWorkingSet)),
                      Fact(label: "数据源", value: "IORegistry · PerformanceStatistics"), Fact(label: "最后更新", value: date.formatted(date: .omitted, time: .standard))], series: series)
        case .failure(let error): return Self.unavailable(date, error.localizedDescription)
        }
    }
    private static func unavailable(_ date: Date, _ reason: String) -> MetricReading {
        MetricReading(date: date, value: nil, status: reason, facts: [], rows: [])
    }
}
