import Foundation
import Combine

enum Metric: String, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", memory = "内存", disk = "磁盘", network = "网络", sensors = "传感器"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .cpu: "cpu"; case .gpu: "square.stack.3d.up"; case .memory: "memorychip"; case .disk: "internaldrive"; case .network: "network"; case .sensors: "thermometer.medium" }
    }
    var unit: String {
        switch self { case .cpu, .gpu: "%"; case .memory: "GB"; case .disk, .network: "MB/s"; case .sensors: "" }
    }
}
enum CPUScale: String, CaseIterable, Identifiable {
    case total = "核心总量", average = "整机比例"
    var id: String { rawValue }
}
enum Theme: String, CaseIterable, Identifiable {
    case system = "跟随系统", light = "浅色", dark = "深色"
    var id: String { rawValue }
}
enum HistoryRange: Int, CaseIterable, Identifiable {
    case short = 5, long = 30, hour = 60, sixHours = 360, day = 1440
    var id: Int { rawValue }
    var label: String { rawValue < 60 ? "\(rawValue) 分钟" : "\(rawValue / 60) 小时" }
}
struct Sample: Identifiable, Equatable { let id: Double; let minute: Double; let value: Double }
// 仅压缩绘图数据；每桶保留峰谷及首尾，统计继续使用原始样本。
extension Sample {
    static func reduced(_ samples: [Sample], limit: Int) -> [Sample] {
        precondition(limit >= 4)
        guard samples.count > limit else { return samples }
        let buckets = (limit - 2) / 2
        var result = [samples[0]]
        result.reserveCapacity(limit)
        for bucket in 0..<buckets {
            let start = 1 + bucket * (samples.count - 2) / buckets
            let end = 1 + (bucket + 1) * (samples.count - 2) / buckets
            var minimum = start, maximum = start
            for index in start..<end {
                if samples[index].value < samples[minimum].value { minimum = index }
                if samples[index].value > samples[maximum].value { maximum = index }
            }
            result.append(samples[min(minimum, maximum)])
            if minimum != maximum { result.append(samples[max(minimum, maximum)]) }
        }
        result.append(samples[samples.count - 1])
        return result
    }
}
struct Fact: Identifiable { let label: String; let value: String; var id: String { label } }
struct TimedValue { let date: Date; let value: Double; var series: [String: Double] = [:] }
struct LinePoint: Identifiable {
    let name: String
    let segment: String
    let minute: Double
    let value: Double
    let id: String
}
enum MemoryTrendScale {
    static func domain(_ values: [Double]) -> ClosedRange<Double> {
        let valid = values.filter { $0.isFinite && $0 >= 0 }
        guard let minimum = valid.min(), let maximum = valid.max() else { return 0...0.01 }
        let padding = max(0.01, (maximum - minimum) * 0.15)
        let lower = max(0, floor((minimum - padding) * 100) / 100)
        let upper = max(lower + 0.01, ceil((maximum + padding) * 100) / 100)
        return lower...upper
    }
}
struct MetricReading {
    let date: Date
    let value: Double?
    let status: String
    let facts: [Fact]
    let rows: [Fact]
    var cores: [Double?] = []
    var cpuParts: [Double] = []
    var series: [String: Double] = [:]
    var anePower: Double? = nil
}
struct Snapshot {
    let metric: Metric
    var current: MetricReading?
    var history: [TimedValue] = []
    var now = Date()
    var cpuScale: CPUScale = .total
    var precision: Int = 1
    var cpuFactor: Double { metric == .cpu && cpuScale == .average ? 1 / Double(max(current?.cores.count ?? 0, 1)) : 1 }
    var missingReason: String? { current?.value == nil ? (current?.status ?? "等待真实样本") : nil }
    var value: Double? { current?.value.map { $0 * cpuFactor } }
    var formatted: (String, String) {
        guard let value else { return ("—", metric.unit) }
        return ValueFormat.display(value, metric: metric, precision: precision)
    }
    var number: String { formatted.0 }
    var unit: String { formatted.1 }
    var reading: String { value == nil ? "—" : "\(number) \(unit)" }
    var status: String {
        if metric == .cpu, value != nil, cpuScale == .average { return "整机平均使用率" }
        return current?.status ?? "等待真实样本"
    }
    var facts: [Fact] {
        if metric == .cpu, let parts = current?.cpuParts, parts.count == 3 {
            return zip(["用户", "系统", "空闲"], parts).map { Fact(label: $0.0, value: "\(ValueFormat.number($0.1 * cpuFactor, precision: precision)) %") }
        }
        return current?.facts ?? []
    }
    var rows: [Fact] {
        var result = current?.rows ?? []
        let values = samples(.long).map(\.value)
        if !values.isEmpty {
            let average = values.reduce(0, +) / Double(values.count)
            let peak = values.max() ?? 0
            result.append(Fact(label: "近 30 分钟均值", value: ValueFormat.reading(average, metric: metric, precision: precision)))
            result.append(Fact(label: "近 30 分钟峰值", value: ValueFormat.reading(peak, metric: metric, precision: precision)))
        }
        return result
    }
    func maximum(_ range: HistoryRange) -> Double {
        if metric == .cpu { return Double(max(current?.cores.count ?? 0, 1)) * 100 * cpuFactor }
        if metric == .gpu { return 100 }
        guard value != nil else { return 0.001 }
        var peak = value ?? 0
        for item in history where isVisible(item, in: range) {
            peak = max(peak, item.value * cpuFactor)
            for value in item.series.values { peak = max(peak, value * cpuFactor) }
        }
        return max(0.001, peak * 1.2)
    }
    var note: String {
        switch metric {
        case .cpu: (cpuScale == .total ? "CPU 总量为各逻辑核心使用率之和，单核满载为 100%；用户包含 nice。" : "整机比例为各逻辑核心使用率的平均值，上限为 100%；用户包含 nice。") + "核心簇来自系统拓扑，核心类型根据拓扑和核心数量推断。首次采样需要等待下一次读数。"
        case .gpu: "Apple GPU 驱动报告的设备、渲染器和分块器利用率不可相加；驱动分配及使用系统内存属于实验性统计，并非独立显存或 GPU 独占内存。Metal 建议工作集是建议上限，不是实际占用。GPU Neural Accelerator 与独立 Apple Neural Engine 是不同硬件；当前应用未能读取两者的独立利用率。ANE 功耗为 IOReport 能量模型按驱动发布时间计算的区间平均值，接口为私有实现，停更或不可用时不显示；功耗不等于利用率。GPU 核心数按驱动核心掩码置位数推算，num_cores 不能直接视为启用核心数；字段和统计窗口没有稳定公开契约。"
        case .memory: "内存按 1 GB = 1,073,741,824 字节换算，与系统信息一致。主指标为活跃、不可换出和压缩页之和；活跃页可能包含文件缓存，非活跃页未计入；分项曲线另展示非活跃和空闲页，不能将所有曲线相加作为主指标。该值不是应用内存或内存压力，与系统其他工具的已用内存口径不同。统一内存由系统和 GPU 共享。"
        case .disk: "速率是系统识别的块存储设备读写量之和；容量为用户主目录所在卷。系统缓存、外接设备和 APFS 共享空间会影响读数。"
        case .sensors: "传感器来自 AppleSMC 私有接口，名称为系统提供的键名；可用项目随设备和系统版本变化。"
        case .network: "速率为处于运行状态的 en 接口接收或发送字节之和，包含本地网络流量；不统计 VPN、虚拟及其他名称接口，不能视为互联网流量。接口变化时重新建立速率基线。"
        }
    }
    private func isVisible(_ item: TimedValue, in range: HistoryRange) -> Bool {
        let age = now.timeIntervalSince(item.date)
        return age >= 0 && age <= Double(range.rawValue * 60)
    }
    func seriesSamples(_ range: HistoryRange, limit: Int? = nil) -> [LinePoint] {
        guard value != nil else { return [] }
        var segments: [String: Int] = [:], active = Set<String>()
        var series: [String: [Sample]] = [:]
        var names: [String: String] = [:]
        for item in history where isVisible(item, in: range) {
            let minute = item.date.timeIntervalSince(now) / 60
            let currentNames = Set(item.series.keys)
            for name in active.subtracting(currentNames) { segments[name, default: 0] += 1 }
            for (name, value) in item.series {
                let segment = "\(name)-\(segments[name, default: 0])"
                names[segment] = name
                series[segment, default: []].append(Sample(id: item.date.timeIntervalSinceReferenceDate,
                                                          minute: minute, value: value * cpuFactor))
            }
            active = currentNames
        }
        // 分段后再压缩，避免将缺失前后的曲线接起来；只为最终绘图点构造标识符。
        return series.keys.sorted().flatMap { segment -> [LinePoint] in
            let samples = series[segment]!
            return (limit.map { Sample.reduced(samples, limit: $0) } ?? samples).map {
                LinePoint(name: names[segment]!, segment: segment, minute: $0.minute,
                          value: $0.value, id: "\(segment)-\($0.id)")
            }
        }.sorted { $0.minute < $1.minute }
    }
    func plotStart(_ range: HistoryRange) -> Double {
        guard value != nil, let first = history.first(where: { isVisible($0, in: range) }) else {
            return -Double(range.rawValue)
        }
        return min(-1.0 / 6, first.date.timeIntervalSince(now) / 60)
    }
    func samples(_ range: HistoryRange, limit: Int? = nil) -> [Sample] {
        guard value != nil else { return [] }
        let samples = history.compactMap { item -> Sample? in
            guard isVisible(item, in: range) else { return nil }
            return Sample(id: item.date.timeIntervalSinceReferenceDate,
                          minute: item.date.timeIntervalSince(now) / 60, value: item.value * cpuFactor)
        }
        return limit.map { Sample.reduced(samples, limit: $0) } ?? samples
    }
}

@MainActor final class MonitorModel: ObservableObject {
    @Published var metric: Metric = .cpu
    private let defaults: UserDefaults
    @Published var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var range: HistoryRange { didSet { defaults.set(range.rawValue, forKey: "historyRange") } }
    @Published var reduceTransparency: Bool { didSet { defaults.set(reduceTransparency, forKey: "reduceTransparency") } }
    @Published var cpuScale: CPUScale { didSet { defaults.set(cpuScale.rawValue, forKey: "cpuScale") } }
    @Published var precision: Int { didSet { defaults.set(precision, forKey: "precision") } }
    @Published var interval: Int { didSet {
        defaults.set(interval, forKey: "samplingInterval")
        if timer != nil { stop(); schedule() }
    } }
    @Published var overviewPresented = false
    @Published var detailsPresented = false
    let backdropDiagnostics = BackdropDiagnostics()
    @Published private(set) var readings: [Metric: MetricReading] = [:]
    @Published private(set) var histories: [Metric: [TimedValue]] = [:]
    @Published private(set) var now = Date()
    private var timer: Timer?
    private var inFlight = false
    private var requestDate: Date?
    private var gpuInFlight = false
    private var gpuRequestDate: Date?
    @Published private(set) var sensors: [SensorReading] = []
    @Published private(set) var sensorStatus = "等待传感器采样"
    private var sensorInFlight = false
    private var sensorRequestDate: Date?
    private let sensorQueue = DispatchQueue(label: "NativeMonitor.sensors", qos: .utility)
    private let collector = MonitorCollector()
    private(set) var coreLabels: [String]?
    private(set) var coreClusters: [CPUCluster]?
    private var coreLabelsCount = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        range = HistoryRange(rawValue: defaults.integer(forKey: "historyRange")) ?? .short
        reduceTransparency = defaults.bool(forKey: "reduceTransparency")
        cpuScale = CPUScale(rawValue: defaults.string(forKey: "cpuScale") ?? "") ?? .total
        let storedPrecision = defaults.object(forKey: "precision") as? Int
        precision = [0, 1, 2].contains(storedPrecision ?? -1) ? storedPrecision! : 1
        let storedInterval = defaults.integer(forKey: "samplingInterval")
        interval = [1, 2, 5].contains(storedInterval) ? storedInterval : 2
    }
    func start() {
        guard timer == nil else { return }
        refresh()
        schedule()
    }
    private func schedule() {
        let timer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func refresh() {
        now = Date()
        if inFlight, requestDate.map({ now.timeIntervalSince($0) > Double(max(6, interval * 3)) }) == true {
            for metric in Metric.allCases where metric != .gpu && metric != .sensors { setUnavailable(metric) }
        }
        if gpuInFlight, gpuRequestDate.map({ now.timeIntervalSince($0) > Double(max(6, interval * 3)) }) == true { setUnavailable(.gpu) }
        if sensorInFlight, sensorRequestDate.map({ now.timeIntervalSince($0) > Double(max(6, interval * 3)) }) == true {
            sensors = []; sensorStatus = "传感器采样超时"
        }
        let collector = collector
        if !sensorInFlight {
            sensorInFlight = true
            sensorRequestDate = now
            sensorQueue.async { [weak self] in
                let readings = collector.readSensors()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sensorInFlight = false
                    self.sensors = readings ?? []
                    self.sensorStatus = readings == nil ? "传感器数据不可用" : readings!.isEmpty ? "未发现可读取的温度或风扇传感器" : ""
                }
            }
        }
        if !inFlight {
            inFlight = true
            requestDate = now
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let results = collector.read()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight = false
                    for (metric, reading) in results { self.record(reading, for: metric) }
                }
            }
        }
        if !gpuInFlight {
            gpuInFlight = true
            gpuRequestDate = now
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let reading = collector.readGPU()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.gpuInFlight = false
                    self.record(reading, for: .gpu)
                }
            }
        }
    }
    private func setUnavailable(_ metric: Metric) {
        readings[metric] = MetricReading(date: now, value: nil, status: "采样超时，请重新打开程序", facts: [], rows: [])
        histories[metric] = []
    }
    private func record(_ reading: MetricReading, for metric: Metric) {
        now = Date()
        if metric == .cpu {
            if let previous = readings[metric], previous.cores.count != reading.cores.count { histories[metric] = [] }
            if !reading.cores.isEmpty && coreLabelsCount != reading.cores.count {
                coreLabelsCount = reading.cores.count
                let topology = SystemReader.coreTopology(count: reading.cores.count)
                coreLabels = topology.labels
                coreClusters = topology.clusters
            }
        }
        readings[metric] = reading
        if let value = reading.value {
            histories[metric, default: []].removeAll { now.timeIntervalSince($0.date) > Double(HistoryRange.day.rawValue * 60) }
            histories[metric, default: []].append(TimedValue(date: reading.date, value: value, series: reading.series))
        } else { histories[metric] = [] }
    }
    func snapshot(_ metric: Metric) -> Snapshot {
        Snapshot(metric: metric, current: readings[metric], history: histories[metric] ?? [], now: now, cpuScale: cpuScale, precision: precision)
    }
}
