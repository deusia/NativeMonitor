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
    var maximum: Double { switch self { case .cpu, .gpu, .disk: 100; case .memory: 24; case .network: 10 } }
    var normalValue: Double? { switch self { case .cpu: 24; case .gpu: nil; case .memory: 12.4; case .disk: 18; case .network: 2.3 } }
}
enum Scenario: String, CaseIterable, Identifiable {
    case normal = "正常", offline = "网络未连接", idle = "已连接 · 零流量", empty = "全部暂无样本"
    var id: String { rawValue }
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
struct Snapshot {
    let metric: Metric
    let scenario: Scenario
    var gpuReading: GPUReading? = nil
    var gpuHistory: [GPUReading] = []
    var gpuEnabled = false
    var gpuError: String? = nil
    var now = Date()
    var sourceLabel: String { metric == .gpu && gpuEnabled ? "实验性实时 · IORegistry" : "模拟数据" }
    var missingReason: String? {
        if scenario == .empty { return "暂无样本" }
        if metric == .gpu { return gpuEnabled ? (gpuReading == nil ? (gpuError ?? "等待真实样本") : nil) : "来源未验证" }
        if metric == .network && scenario == .offline { return "未连接" }
        return nil
    }
    var value: Double? {
        guard missingReason == nil else { return nil }
        if metric == .gpu { return gpuReading?.utilization }
        return metric == .network && scenario == .idle ? 0 : metric.normalValue
    }
    var number: String { value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—" }
    var reading: String { value == nil ? "—" : "\(number) \(metric.unit)" }
    var status: String {
        if let reason = missingReason { return reason }
        switch metric { case .cpu: return "空闲 76%"; case .gpu: return "设备利用率 · 实测"; case .memory: return "压力正常"; case .disk: return "读取速率"; case .network: return scenario == .idle ? "已连接 · 零流量" : "Wi-Fi 已连接" }
    }
    var facts: [Fact] {
        if metric == .gpu, gpuEnabled {
            let reading = scenario == .empty ? nil : gpuReading
            return [Fact(label: "渲染器", value: reading?.renderer.map { "\($0.formatted())%" } ?? "—"),
                    Fact(label: "分块器", value: reading?.tiler.map { "\($0.formatted())%" } ?? "—"),
                    Fact(label: "采样", value: reading == nil ? "暂无有效样本" : "每 2 秒读取")]
        }
        let pairs: [(String, String)]
        switch metric {
        case .cpu: pairs = [("用户", "18%"), ("系统", "6%"), ("空闲", "76%")]
        case .gpu: pairs = [("数据源", "待验证"), ("占用率", "不可用"), ("内存模型", "统一内存")]
        case .memory: pairs = [("总内存", "24 GB"), ("压缩内存", "1.2 GB"), ("交换空间", "0.8 GB")]
        case .disk: pairs = [("读取", "18 MB/s"), ("写入", "4.2 MB/s"), ("可用容量", "482 GB")]
        case .network:
            pairs = [("下载", scenario == .offline ? "—" : scenario == .idle ? "0 MB/s" : "2.3 MB/s"), ("上传", scenario == .offline ? "—" : scenario == .idle ? "0 KB/s" : "128 KB/s"), ("连接", scenario == .offline ? "未连接" : "Wi-Fi")]
        }
        return pairs.map { Fact(label: $0.0, value: scenario == .empty ? "—" : $0.1) }
    }
    var rows: [Fact] {
        guard scenario != .empty else { return [] }
        if metric == .gpu, gpuEnabled {
            return [Fact(label: "数据源", value: "IORegistry · PerformanceStatistics"),
                    Fact(label: "驱动", value: gpuReading?.driver ?? "不可用"),
                    Fact(label: "有效样本", value: "\(gpuHistory.count)"),
                    Fact(label: "最后更新", value: gpuReading?.date.formatted(date: .omitted, time: .standard) ?? "—")]
        }
        let pairs: [(String, String)]
        switch metric {
        case .cpu: pairs = [("Xcode", "12%"), ("Safari", "5%"), ("WindowServer", "3%")]
        case .gpu: pairs = []
        case .memory: pairs = [("Safari", "4.1 GB"), ("Xcode", "3.2 GB"), ("WindowServer", "0.7 GB")]
        case .disk: pairs = [("总容量", "1 TB"), ("已用容量", "518 GB"), ("可用容量", "482 GB")]
        case .network: pairs = scenario == .offline ? [("连接状态", "未连接"), ("流量读数", "不可用")] : [("会话接收", "1.82 GB"), ("会话发送", "246 MB"), ("连接状态", "已连接")]
        }
        return pairs.map { Fact(label: $0.0, value: $0.1) }
    }
    var note: String {
        if metric == .gpu, gpuEnabled {
            return "读取 Apple GPU 驱动的 Device Utilization %，是设备级计数器，不是进程 GPU 时间；驱动统计窗口未有稳定公开保证。渲染器和分块器百分比不可相加。仅绘制启动后真实样本，不补造历史；读取失败或超过 6 秒未更新即显示不可用并中断曲线。Apple Silicon 使用统一内存。此实验性驱动字段可能随系统升级变化。"
        }
        return switch metric {
        case .cpu: "CPU 按整机总算力归一化；只列出前三个进程，其余合计 4%。全部为演示数据。"
        case .gpu: "GPU 数据源尚未验证，因此不显示占用率或虚构曲线。Apple Silicon 使用统一内存，没有在此模拟独立显存。"
        case .memory: "统一内存供系统与 GPU 共享。进程内存不可简单相加等同系统已用；占用率高不直接代表压力异常。"
        case .disk: "曲线仅表示读取速率；写入速率和磁盘容量分别列出。容量以十进制 GB / TB 展示。"
        case .network: "曲线表示下载速率。未连接表示不可用；连接正常且没有传输才显示 0。会话流量为独立累计值。"
        }
    }
    func plotStart(_ range: HistoryRange) -> Double {
        guard metric == .gpu, gpuEnabled, let first = samples(range).first else { return -Double(range.rawValue) }
        return min(-1.0 / 6, first.minute)
    }
    // shortcut: 合成样本只验证交互；接入真实采集时须替换为带时间戳且区分缺失值的数据。
    func samples(_ range: HistoryRange) -> [Sample] {
        guard let value else { return [] }
        if metric == .gpu, gpuEnabled {
            return gpuHistory.compactMap { reading in
                let minute = reading.date.timeIntervalSince(now) / 60
                guard minute >= -Double(range.rawValue), minute <= 0 else { return nil }
                return Sample(id: reading.date.timeIntervalSinceReferenceDate, minute: minute, value: reading.utilization)
            }
        }
        let base: [Double] = range == .short ? [0.6,0.8,0.65,1,0.75,0.6,0.8,1.1,1.5,0.8,0.7,1.2,2.2,1.6,0.8,0.7,1.2,1] : [0.4,0.5,0.9,0.7,0.4,1.5,2,1,0.8,0.5,0.6,0.9,1.8,1.5,1.1,1.3,0.8,1]
        return base.indices.map { i in
            let factor = metric == .disk ? base[(i + 5) % base.count] * 0.8 : metric == .network ? base[(i * 3) % base.count] * 1.1 : base[i]
            let raw = metric == .memory ? value - (range == .short ? 1.6 : 3.2) * (1 - Double(i) / 17) : value * factor
            return Sample(id: Double(i), minute: -Double(range.rawValue) * (1 - Double(i) / 17), value: i == 17 ? value : min(metric.maximum, max(0, raw)))
        }
    }
}
@MainActor final class MonitorModel: ObservableObject {
    @Published var metric: Metric = .cpu
    @Published var scenario: Scenario = .normal
    @Published var theme: Theme = .system
    @Published var range: HistoryRange = .short
    @Published var reduceTransparency = false
    @Published var overviewPresented = false
    @Published var detailsPresented = false
    let backdropDiagnostics = BackdropDiagnostics()
    @Published private(set) var gpuReading: GPUReading?
    @Published private(set) var gpuHistory: [GPUReading] = []
    @Published private(set) var gpuError: String?
    @Published private(set) var now = Date()
    private var gpuTimer: Timer?
    private var gpuInFlight = false
    private var gpuRequestDate: Date?
    private var gpuEnabled = false

    func startGPU() {
        guard gpuTimer == nil else { return }
        gpuEnabled = true
        refreshGPU()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshGPU() }
        }
        RunLoop.main.add(timer, forMode: .common)
        gpuTimer = timer
    }
    func stopGPU() { gpuTimer?.invalidate(); gpuTimer = nil }
    private func refreshGPU() {
        now = Date()
        if gpuReading.map({ now.timeIntervalSince($0.date) > 6 }) == true || (gpuInFlight && gpuRequestDate.map({ now.timeIntervalSince($0) > 6 }) == true) {
            gpuReading = nil; gpuHistory = []
            gpuError = "GPU 读取超时；若持续不可用，请重新打开程序。"
        }
        guard !gpuInFlight else { return }
        gpuInFlight = true
        gpuRequestDate = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = GPUReader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.gpuInFlight = false
                self.now = Date()
                switch result {
                case .success(let reading):
                    self.gpuReading = reading; self.gpuError = nil
                    self.gpuHistory.removeAll { self.now.timeIntervalSince($0.date) > 1800 }
                    self.gpuHistory.append(reading)
                case .failure(let error):
                    self.gpuReading = nil; self.gpuHistory = []
                    self.gpuError = error.localizedDescription
                }
            }
        }
    }
    func snapshot(_ metric: Metric) -> Snapshot {
        Snapshot(metric: metric, scenario: scenario, gpuReading: gpuReading, gpuHistory: gpuHistory,
                 gpuEnabled: gpuEnabled, gpuError: gpuError, now: now)
    }
}
