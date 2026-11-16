import Foundation
import Combine
import OSLog

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
extension Array where Element == TimedValue {
    // 历史按时间递增；二分定位窗口，避免查看 5 分钟数据时扫描全天样本。
    func lowerBound(_ date: Date, strictlyAfter: Bool = false) -> Int {
        var lower = 0, upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self[middle].date < date || (strictlyAfter && self[middle].date == date) {
                lower = middle + 1
            } else { upper = middle }
        }
        return lower
    }
}

// 超时仅报告一次；阻塞调用结束前不派发新请求，停止后丢弃未完成结果。
struct SamplingRequest {
    private(set) var inFlight = false
    private var startedAt: TimeInterval?
    mutating func begin(at uptime: TimeInterval) -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        startedAt = uptime
        return true
    }
    mutating func timedOut(at uptime: TimeInterval, after timeout: TimeInterval) -> Bool {
        guard let startedAt, uptime - startedAt > timeout else { return false }
        self.startedAt = nil
        return true
    }
    mutating func finish() -> Bool {
        let accepted = startedAt != nil
        inFlight = false
        startedAt = nil
        return accepted
    }
    mutating func invalidate() { startedAt = nil }
}
struct LinePoint: Identifiable {
    let name: String
    let segment: String
    let minute: Double
    let value: Double
    let id: String
    // 只在绘图坐标中将下载映射到零线下方，原始速率仍保持非负。
    func plotValue(for metric: Metric) -> Double { metric == .network && name == "接收" ? -value : value }
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
    // 由 MonitorModel 保证时间递增，范围查询依赖此顺序。
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
        if value != nil {
            var sum = 0.0, peak = 0.0, count = 0
            for item in historyWindow(.long) {
                let value = item.value * cpuFactor
                sum += value
                peak = max(peak, value)
                count += 1
            }
            if count > 0 {
                result.append(Fact(label: "近 30 分钟均值", value: ValueFormat.reading(sum / Double(count), metric: metric, precision: precision)))
                result.append(Fact(label: "近 30 分钟峰值", value: ValueFormat.reading(peak, metric: metric, precision: precision)))
            }
        }
        return result
    }
    func maximum(_ range: HistoryRange) -> Double {
        if metric == .cpu { return Double(max(current?.cores.count ?? 0, 1)) * 100 * cpuFactor }
        if metric == .gpu { return 100 }
        guard value != nil else { return 0.001 }
        var peak = value ?? 0
        for item in historyWindow(range) {
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
    private func historyWindow(_ range: HistoryRange) -> ArraySlice<TimedValue> {
        let start = history.lowerBound(now.addingTimeInterval(-Double(range.rawValue * 60)))
        let end = history.lowerBound(now, strictlyAfter: true)
        return history[start..<end]
    }
    // 采样时间是曲线的版本；其他指标更新和侧栏动画无需重新准备这条曲线。
    func hasSameChart(as other: Snapshot) -> Bool {
        metric == other.metric && current?.date == other.current?.date &&
        current?.value == other.current?.value && missingReason == other.missingReason &&
        cpuScale == other.cpuScale && cpuFactor == other.cpuFactor && precision == other.precision && history.count == other.history.count
    }
    func seriesSamples(_ range: HistoryRange, limit: Int? = nil) -> [LinePoint] {
        guard value != nil else { return [] }
        var active: [String: Int] = [:]
        var segments: [(name: String, ordinal: Int, samples: [Sample])] = []
        var counts: [String: Int] = [:]
        for item in historyWindow(range) {
            for name in Array(active.keys) where item.series[name] == nil { active.removeValue(forKey: name) }
            for (name, value) in item.series {
                let index: Int
                if let existing = active[name] { index = existing }
                else {
                    index = segments.count
                    let ordinal = counts[name, default: 0]
                    segments.append((name, ordinal, []))
                    counts[name] = ordinal + 1
                    active[name] = index
                }
                segments[index].samples.append(Sample(id: item.date.timeIntervalSinceReferenceDate,
                                                     minute: item.date.timeIntervalSince(now) / 60, value: value * cpuFactor))
            }
        }
        // 分段后再压缩，只为最终绘图点构造字符串标识符。
        return segments.flatMap { series -> [LinePoint] in
            let segment = "\(series.name)-\(series.ordinal)"
            return (limit.map { Sample.reduced(series.samples, limit: $0) } ?? series.samples).map {
                LinePoint(name: series.name, segment: segment, minute: $0.minute,
                          value: $0.value, id: "\(segment)-\($0.id)")
            }
        }.sorted { $0.minute < $1.minute }
    }
    func plotStart(_ range: HistoryRange) -> Double {
        guard value != nil, let first = historyWindow(range).first else {
            return -Double(range.rawValue)
        }
        return min(-1.0 / 6, first.date.timeIntervalSince(now) / 60)
    }
    func samples(_ range: HistoryRange, limit: Int? = nil) -> [Sample] {
        guard value != nil else { return [] }
        let samples = historyWindow(range).map { item in
            return Sample(id: item.date.timeIntervalSinceReferenceDate,
                          minute: item.date.timeIntervalSince(now) / 60, value: item.value * cpuFactor)
        }
        return limit.map { Sample.reduced(samples, limit: $0) } ?? samples
    }
}

enum AppearanceRegion: String, CaseIterable, Identifiable {
    case overview = "概览背景", details = "详情背景", cards = "内容卡片", controls = "按钮与控件"
    var id: String { rawValue }
}

/// 只调整背景，保留文字和图表的可读性。
struct SurfaceAppearance: Equatable {
    var clarity: Double
    var transparency: Double
    var blur: Double

    init(clarity: Double = 0.5, transparency: Double = 0, blur: Double = 2) {
        self.clarity = clarity.isFinite ? min(1, max(0, clarity)) : 0.5
        self.transparency = transparency.isFinite ? min(1, max(0, transparency)) : 0
        self.blur = blur.isFinite ? min(30, max(0, blur)) : 2
    }
}

struct AppearanceSettings: Equatable {
    private var surfaces: [AppearanceRegion: SurfaceAppearance] = [:]
    subscript(region: AppearanceRegion) -> SurfaceAppearance {
        get { surfaces[region] ?? SurfaceAppearance() }
        set { surfaces[region] = SurfaceAppearance(clarity: newValue.clarity, transparency: newValue.transparency, blur: newValue.blur) }
    }
    init(defaults: UserDefaults? = nil) {
        guard let defaults else { return }
        for region in AppearanceRegion.allCases {
            let key = "appearance.\(region)"
            self[region] = SurfaceAppearance(
                clarity: (defaults.object(forKey: key + ".clarity") as? Double) ?? 0.5,
                transparency: (defaults.object(forKey: key + ".transparency") as? Double) ?? 0,
                blur: (defaults.object(forKey: key + ".blur") as? Double) ?? 2)
        }
    }
    func save(to defaults: UserDefaults) {
        for region in AppearanceRegion.allCases {
            let key = "appearance.\(region)", surface = self[region]
            defaults.set(surface.clarity, forKey: key + ".clarity")
            defaults.set(surface.transparency, forKey: key + ".transparency")
            defaults.set(surface.blur, forKey: key + ".blur")
        }
    }
}

@MainActor final class MonitorModel: ObservableObject {
    @Published var metric: Metric = .cpu
    private let defaults: UserDefaults
    @Published var appearance: AppearanceSettings { didSet { appearance.save(to: defaults) } }
    @Published var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var range: HistoryRange { didSet { defaults.set(range.rawValue, forKey: "historyRange") } }
    @Published var pinWindows: Bool { didSet { defaults.set(pinWindows, forKey: "pinWindows") } }
    @Published var reduceTransparency: Bool { didSet { defaults.set(reduceTransparency, forKey: "reduceTransparency") } }
    @Published var cpuScale: CPUScale { didSet { defaults.set(cpuScale.rawValue, forKey: "cpuScale") } }
    @Published var precision: Int { didSet { defaults.set(precision, forKey: "precision") } }
    @Published var interval: Int { didSet {
        defaults.set(interval, forKey: "samplingInterval")
        if timer != nil { timer?.invalidate(); schedule() }
    } }
    @Published var overviewPresented = false
    @Published var detailsPresented = false
    let backdropDiagnostics = BackdropDiagnostics()
    @Published private(set) var readings: [Metric: MetricReading] = [:]
    private(set) var histories: [Metric: [TimedValue]] = [:]
    private(set) var now = Date()
    private var timer: Timer?
    private var systemRequest = SamplingRequest()
    private var gpuRequest = SamplingRequest()
    @Published private(set) var sensors: [SensorReading] = []
    @Published private(set) var sensorStatus = "等待传感器采样"
    private var sensorRequest = SamplingRequest()
    private let sensorQueue = DispatchQueue(label: "NativeMonitor.sensors", qos: .utility)
    private let collector = MonitorCollector()
    private let logger = Logger(subsystem: "local.ashen.NativeMonitor", category: "Sampling")
    private(set) var coreLabels: [String]?
    private(set) var coreClusters: [CPUCluster]?
    private var coreLabelsCount = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceSettings(defaults: defaults)
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        range = HistoryRange(rawValue: defaults.integer(forKey: "historyRange")) ?? .short
        pinWindows = defaults.bool(forKey: "pinWindows")
        reduceTransparency = defaults.bool(forKey: "reduceTransparency")
        cpuScale = CPUScale(rawValue: defaults.string(forKey: "cpuScale") ?? "") ?? .total
        let storedPrecision = defaults.object(forKey: "precision") as? Int
        precision = [0, 1, 2].contains(storedPrecision ?? -1) ? storedPrecision! : 1
        let storedInterval = defaults.integer(forKey: "samplingInterval")
        interval = [1, 2, 5].contains(storedInterval) ? storedInterval : 2
    }
    deinit { timer?.invalidate() }
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
    func stop() {
        timer?.invalidate()
        timer = nil
        systemRequest.invalidate()
        gpuRequest.invalidate()
        sensorRequest.invalidate()
    }
    private func refresh() {
        let date = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let timeout = Double(max(6, interval * 3))
        var unavailable: [Metric: MetricReading] = [:]
        if systemRequest.timedOut(at: uptime, after: timeout) {
            logger.warning("系统采样超时，等待当前调用结束")
            for metric in [Metric.cpu, .memory, .disk, .network] {
                unavailable[metric] = MetricReading(date: date, value: nil, status: "采样超时，等待恢复", facts: [], rows: [])
            }
        }
        if gpuRequest.timedOut(at: uptime, after: timeout) {
            logger.warning("GPU 采样超时，等待当前调用结束")
            unavailable[.gpu] = MetricReading(date: date, value: nil, status: "采样超时，等待恢复", facts: [], rows: [])
        }
        if !unavailable.isEmpty { record(unavailable, at: date) }
        if sensorRequest.timedOut(at: uptime, after: timeout) {
            logger.warning("传感器采样超时，等待当前调用结束")
            sensors = []
            sensorStatus = "传感器采样超时，等待恢复"
        }
        let collector = collector
        if sensorRequest.begin(at: uptime) {
            sensorQueue.async { [weak self] in
                let readings = collector.readSensors()
                DispatchQueue.main.async {
                    guard let self, self.sensorRequest.finish() else { return }
                    let sensors = readings ?? []
                    let status = readings == nil ? "传感器数据不可用" : sensors.isEmpty ? "未发现可读取的温度或风扇传感器" : ""
                    if self.sensors != sensors { self.sensors = sensors }
                    if self.sensorStatus != status { self.sensorStatus = status }
                }
            }
        }
        if systemRequest.begin(at: uptime) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let results = collector.read()
                DispatchQueue.main.async {
                    guard let self, self.systemRequest.finish() else { return }
                    self.record(results)
                }
            }
        }
        if gpuRequest.begin(at: uptime) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let reading = collector.readGPU()
                DispatchQueue.main.async {
                    guard let self, self.gpuRequest.finish() else { return }
                    self.record([.gpu: reading])
                }
            }
        }
    }
    // 一批读数完成后只发布一次，界面不会看到读数与历史尚未同步的中间状态。
    func record(_ results: [Metric: MetricReading], at date: Date = Date()) {
        guard !results.isEmpty else { return }
        now = date
        let validated = results.mapValues { reading -> MetricReading in
            let age = date.timeIntervalSince(reading.date)
            guard age >= 0, age <= Double(max(6, interval * 3)),
                  reading.value.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  reading.series.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                return MetricReading(date: date, value: nil, status: "采样已过期或数据无效，等待下次采样", facts: [], rows: [])
            }
            return reading
        }
        for (metric, reading) in validated {
            if reading.status == "采样已过期或数据无效，等待下次采样", readings[metric]?.status != reading.status {
                logger.warning("丢弃过期或无效采样：\(metric.rawValue, privacy: .public)")
            }
            appendHistory(reading, for: metric)
        }
        readings.merge(validated) { _, new in new }
    }
    private func appendHistory(_ reading: MetricReading, for metric: Metric) {
        if metric == .cpu {
            if let previous = readings[metric], previous.cores.count != reading.cores.count { histories[metric] = [] }
            if !reading.cores.isEmpty && coreLabelsCount != reading.cores.count {
                coreLabelsCount = reading.cores.count
                let topology = SystemReader.coreTopology(count: reading.cores.count)
                coreLabels = topology.labels
                coreClusters = topology.clusters
            }
        }
        if let value = reading.value {
            // 系统时间回拨时重新建段，确保二分查找依赖的时间顺序成立。
            if let last = histories[metric]?.last, reading.date <= last.date { histories[metric] = [] }
            if let first = histories[metric]?.first,
               first.date < now.addingTimeInterval(-Double(HistoryRange.day.rawValue * 60)) {
                let expired = histories[metric]!.lowerBound(now.addingTimeInterval(-Double(HistoryRange.day.rawValue * 60)))
                histories[metric]!.removeFirst(expired)
            }
            histories[metric, default: []].append(TimedValue(date: reading.date, value: value, series: reading.series))
        } else { histories[metric] = [] }
    }
    func snapshot(_ metric: Metric) -> Snapshot {
        Snapshot(metric: metric, current: readings[metric], history: histories[metric] ?? [], now: readings[metric]?.date ?? now, cpuScale: cpuScale, precision: precision)
    }
}
