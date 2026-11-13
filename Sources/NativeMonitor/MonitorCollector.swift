import Foundation

final class MonitorCollector {
    private var previousCPU: CPUCounters?
    private var previousDisk: (TimeInterval, Counters)?
    private var previousNetwork: (TimeInterval, [InterfaceCounters])?
    private func text(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(suffix)"
    }
    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return text(Double(value) / 1_000_000_000, suffix: "GB")
    }
    func read() -> [Metric: MetricReading] {
        let date = Date(), uptime = ProcessInfo.processInfo.systemUptime
        var result: [Metric: MetricReading] = [:]
        let cpu = SystemReader.cpu()
        let percentages = cpu.flatMap { current in previousCPU.flatMap { current.percentages(since: $0) } }
        previousCPU = cpu
        result[.cpu] = MetricReading(date: date, value: percentages.map { $0.0 + $0.1 }, status: percentages == nil ? "等待 CPU 采样" : "整机使用率", facts: [
            Fact(label: "用户", value: text(percentages?.0, suffix: "%")), Fact(label: "系统", value: text(percentages?.1, suffix: "%")), Fact(label: "空闲", value: text(percentages?.2, suffix: "%"))
        ], rows: [Fact(label: "逻辑核心", value: "\(ProcessInfo.processInfo.activeProcessorCount) / \(ProcessInfo.processInfo.processorCount)"), Fact(label: "运行时间", value: text(uptime / 3600, suffix: "小时"))])
        if let memory = SystemReader.memory() {
            result[.memory] = MetricReading(date: date, value: Double(memory.used) / 1e9, status: "活跃 + 不可换出 + 压缩", facts: [
                Fact(label: "物理内存", value: bytes(memory.total)), Fact(label: "压缩", value: bytes(memory.compressed)), Fact(label: "交换已用", value: bytes(memory.swapUsed))
            ], rows: [Fact(label: "活跃", value: bytes(memory.active)), Fact(label: "不可换出", value: bytes(memory.wired)), Fact(label: "空闲页", value: bytes(memory.free)), Fact(label: "已用比例", value: text(Double(memory.used) / Double(memory.total) * 100, suffix: "%"))])
        } else { result[.memory] = unavailable(date, "内存数据不可用") }
        let disk = SystemReader.disk()
        let diskRates = disk.flatMap { current in previousDisk.flatMap { current.rates(since: $0.1, seconds: uptime - $0.0) } }
        previousDisk = disk.map { (uptime, $0) }
        let volume = SystemReader.volume()
        result[.disk] = MetricReading(date: date, value: diskRates.map { $0.0 / 1e6 }, status: disk == nil ? "磁盘计数器不可用" : diskRates == nil ? "等待磁盘采样" : "设备读取速率", facts: [
            Fact(label: "读取", value: text(diskRates.map { $0.0 / 1e6 }, suffix: "MB/s")), Fact(label: "写入", value: text(diskRates.map { $0.1 / 1e6 }, suffix: "MB/s")), Fact(label: "可用容量", value: bytes(volume?.available))
        ], rows: [Fact(label: "主目录卷总容量", value: bytes(volume?.total)), Fact(label: "主目录卷可用", value: bytes(volume?.available)), Fact(label: "设备累计读取", value: bytes(disk?.first)), Fact(label: "设备累计写入", value: bytes(disk?.second))])
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
            Fact(label: "接收", value: text(networkRates.map { $0.0 / 1e6 }, suffix: "MB/s")), Fact(label: "发送", value: text(networkRates.map { $0.1 / 1e6 }, suffix: "MB/s")), Fact(label: "接口数", value: interfaces.map { "\($0.count)" } ?? "—")
        ], rows: [Fact(label: "运行中接口", value: interfaces.map { $0.isEmpty ? "无" : $0.map(\.name).joined(separator: ", ") } ?? "—"), Fact(label: "接口累计接收", value: bytes(received)), Fact(label: "接口累计发送", value: bytes(sent))])
        switch GPUReader.read() {
        case .success(let gpu):
            result[.gpu] = MetricReading(date: date, value: gpu.utilization, status: "设备利用率", facts: [
                Fact(label: "渲染器", value: text(gpu.renderer, suffix: "%")), Fact(label: "分块器", value: text(gpu.tiler, suffix: "%")), Fact(label: "采样", value: "每 2 秒")
            ], rows: [Fact(label: "数据源", value: "IORegistry · PerformanceStatistics"), Fact(label: "驱动", value: gpu.driver), Fact(label: "最后更新", value: date.formatted(date: .omitted, time: .standard))])
        case .failure(let error): result[.gpu] = unavailable(date, error.localizedDescription)
        }
        return result
    }
    private func unavailable(_ date: Date, _ reason: String) -> MetricReading {
        MetricReading(date: date, value: nil, status: reason, facts: [], rows: [])
    }
}
