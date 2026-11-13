import Foundation
import Combine

enum Metric: String, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", memory = "内存", disk = "磁盘", network = "网络"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .cpu: "cpu"; case .gpu: "square.stack.3d.up"; case .memory: "memorychip"; case .disk: "internaldrive"; case .network: "network" }
    }
    var unit: String {
        switch self { case .cpu, .gpu: "%"; case .memory: "GB"; case .disk, .network: "MB/s" }
    }
}
enum Theme: String, CaseIterable, Identifiable {
    case system = "跟随系统", light = "浅色", dark = "深色"
    var id: String { rawValue }
}
enum HistoryRange: Int, CaseIterable, Identifiable {
    case short = 5, long = 30
    var id: Int { rawValue }
    var label: String { "\(rawValue) 分钟" }
}
struct Sample: Identifiable, Equatable { let id: Double; let minute: Double; let value: Double }
struct Fact: Identifiable { let label: String; let value: String; var id: String { label } }
struct TimedValue { let date: Date; let value: Double }
struct MetricReading {
    let date: Date
    let value: Double?
    let status: String
    let facts: [Fact]
    let rows: [Fact]
}
struct Snapshot {
    let metric: Metric
    var current: MetricReading?
    var history: [TimedValue] = []
    var now = Date()
    var sourceLabel: String { metric == .gpu ? "实验性实时 · IORegistry" : "本机实时采样" }
    var missingReason: String? { current?.value == nil ? (current?.status ?? "等待真实样本") : nil }
    var value: Double? { current?.value }
    var number: String { value.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "—" }
    var reading: String { value == nil ? "—" : "\(number) \(metric.unit)" }
    var status: String { current?.status ?? "等待真实样本" }
    var facts: [Fact] { current?.facts ?? [] }
    var rows: [Fact] {
        var result = current?.rows ?? []
        let values = samples(.long).map(\.value)
        if !values.isEmpty {
            let average = values.reduce(0, +) / Double(values.count)
            let peak = values.max() ?? 0
            result.append(Fact(label: "启动后样本均值（最多 30 分钟）", value: "\(average.formatted(.number.precision(.fractionLength(0...2)))) \(metric.unit)"))
            result.append(Fact(label: "启动后样本峰值（最多 30 分钟）", value: "\(peak.formatted(.number.precision(.fractionLength(0...2)))) \(metric.unit)"))
        }
        return result
    }
    var maximum: Double {
        if metric == .cpu || metric == .gpu { return 100 }
        return max(1, (samples(.long).map(\.value).max() ?? value ?? 0) * 1.2)
    }
    var note: String {
        switch metric {
        case .cpu: "整机 CPU 使用率按两次系统累计时间差计算，用户包含 nice；首次采样需要等待下一次读数。"
        case .gpu: "Apple GPU 驱动报告的设备利用率，不是进程 GPU 时间；渲染器和分块器不可相加。驱动字段和统计窗口没有稳定公开契约。"
        case .memory: "已用为活跃、不可换出和压缩页之和，不包含可回收的非活跃页；与活动监视器的内存压力或已用内存不一定一致。统一内存由系统和 GPU 共享。"
        case .disk: "速率是系统识别的块存储设备读写量之和；容量为用户主目录所在卷。系统缓存、外接设备和 APFS 共享空间会影响读数。"
        case .network: "速率为处于运行状态的 en 接口接收或发送字节之和，包含本地网络流量；不统计 VPN、虚拟及其他名称接口，不能视为互联网流量。接口变化时重新建立速率基线。"
        }
    }
    func plotStart(_ range: HistoryRange) -> Double {
        guard let first = samples(range).first else { return -Double(range.rawValue) }
        return min(-1.0 / 6, first.minute)
    }
    func samples(_ range: HistoryRange) -> [Sample] {
        guard value != nil else { return [] }
        return history.compactMap { item in
            let minute = item.date.timeIntervalSince(now) / 60
            guard minute >= -Double(range.rawValue), minute <= 0 else { return nil }
            return Sample(id: item.date.timeIntervalSinceReferenceDate, minute: minute, value: item.value)
        }
    }
}

@MainActor final class MonitorModel: ObservableObject {
    @Published var metric: Metric = .cpu
    @Published var theme: Theme = .system
    @Published var range: HistoryRange = .short
    @Published var reduceTransparency = false
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
    private let collector = MonitorCollector()

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func refresh() {
        now = Date()
        if inFlight, requestDate.map({ now.timeIntervalSince($0) > 6 }) == true {
            for metric in Metric.allCases where metric != .gpu { setUnavailable(metric) }
        }
        if gpuInFlight, gpuRequestDate.map({ now.timeIntervalSince($0) > 6 }) == true { setUnavailable(.gpu) }
        let collector = collector
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
                let reading = MonitorCollector.readGPU()
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
        readings[metric] = reading
        if let value = reading.value {
            histories[metric, default: []].removeAll { now.timeIntervalSince($0.date) > 1800 }
            histories[metric, default: []].append(TimedValue(date: reading.date, value: value))
        } else { histories[metric] = [] }
    }
    func snapshot(_ metric: Metric) -> Snapshot {
        Snapshot(metric: metric, current: readings[metric], history: histories[metric] ?? [], now: now)
    }
}
