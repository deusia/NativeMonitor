import SwiftUI
import Charts
import PrivateBackdrop

private let darkMetricColor = Color(red: 0.35, green: 0.75, blue: 1)

struct GlassButton: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let reduce: Bool
    var circular = false
    var card = false
    var translucent = false
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduce && !systemReduce {
            if card || translucent {
                content.buttonStyle(.plain).background {
                    RoundedRectangle(cornerRadius: 22).fill(.clear)
                        .glassEffect(Glass.clear.tint(colorScheme == .dark ? .black.opacity(0.18) : nil).interactive(), in: RoundedRectangle(cornerRadius: 22))
                        .opacity(translucent ? 0.65 : 1)
                        .allowsHitTesting(false)
                }
            } else {
                content.buttonStyle(.glass).buttonBorderShape(circular ? .circle : .capsule)
            }
        } else { content.buttonStyle(.bordered) }
    }
}

struct PrivateRegionBackdrop: NSViewRepresentable {
    let presented: Bool
    let reduceMotion: Bool
    let diagnostics: BackdropDiagnostics?
    final class Coordinator {
        let id = UUID()
        let diagnostics: BackdropDiagnostics?
        var active = true
        init(_ diagnostics: BackdropDiagnostics?) { self.diagnostics = diagnostics }
    }
    func makeCoordinator() -> Coordinator { Coordinator(diagnostics) }
    static func dismantleNSView(_ view: NMPrivateBackdropView, coordinator: Coordinator) {
        coordinator.active = false
        coordinator.diagnostics?.remove(coordinator.id)
    }
    func makeNSView(context: Context) -> NMPrivateBackdropView { NMPrivateBackdropView(frame: .zero) }
    func updateNSView(_ view: NMPrivateBackdropView, context: Context) {
        view.setPresented(presented, animated: !reduceMotion)
        let coordinator = context.coordinator
        let id = coordinator.id
        DispatchQueue.main.async { [weak view] in
            guard coordinator.active, let view, diagnostics?.reports[id] != view.effectStatus else { return }
            diagnostics?.update(id, view.effectStatus)
        }
    }
}

struct ControlMaterial: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 12
    var materialOpacity: Double = 1
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    let reduce: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if reduce || systemReduce {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.clear)
                    .glassEffect(Glass.clear.tint(colorScheme == .dark ? .black.opacity(0.18) : nil), in: RoundedRectangle(cornerRadius: cornerRadius))
                    .opacity(materialOpacity)
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
private struct SettingsMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    let reduce: Bool
    private var selectedLabel: String { options.first { $0.0 == selection }?.1 ?? "—" }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button { selection = option.0 } label: {
                        if selection == option.0 { Label(option.1, systemImage: "checkmark") }
                        else { Text(option.1) }
                    }
                }
            } label: {
                HStack { Text(selectedLabel); Spacer(minLength: 8); Image(systemName: "chevron.down") }
                    .padding(.horizontal, 12).frame(width: 170, height: 30)
                    .contentShape(Rectangle())
                    .modifier(ControlMaterial(cornerRadius: 15, reduce: reduce))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel(title).accessibilityValue(selectedLabel)
        }
    }
}
struct MonitorSettings: View {
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    @ObservedObject var model: MonitorModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button("完成", action: close).modifier(GlassButton(reduce: model.reduceTransparency))
            }
            SettingsMenu(title: "外观", selection: $model.theme,
                         options: Theme.allCases.map { ($0, $0.rawValue) }, reduce: model.reduceTransparency)
                .accessibilityIdentifier("themePicker")
            SettingsMenu(title: "历史范围", selection: $model.range,
                         options: HistoryRange.allCases.map { ($0, $0.label) }, reduce: model.reduceTransparency)
            SettingsMenu(title: "采样间隔", selection: $model.interval,
                         options: [1, 2, 5].map { ($0, "\($0) 秒") }, reduce: model.reduceTransparency)
            SettingsMenu(title: "CPU 口径", selection: $model.cpuScale,
                         options: CPUScale.allCases.map { ($0, $0.rawValue) }, reduce: model.reduceTransparency)
            SettingsMenu(title: "主读数小数位", selection: $model.precision,
                         options: [0, 1, 2].map { ($0, "最多 \($0) 位") }, reduce: model.reduceTransparency)
            Text("速率自动选择 B/s、KB/s、MB/s 或 GB/s。设置会自动保存。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("减少透明度", isOn: $model.reduceTransparency).toggleStyle(.switch)
            if !model.reduceTransparency && !systemReduce {
                BackdropStatus(diagnostics: model.backdropDiagnostics)
            }
            Text("设置只影响本应用。").font(.caption).foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(18).frame(width: 350)
    }
}
struct Trend: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.range == rhs.range && lhs.mini == rhs.mini && lhs.snapshot.hasSameChart(as: rhs.snapshot)
    }
    @Environment(\.colorScheme) private var colorScheme
    private var chartColor: Color { colorScheme == .dark ? darkMetricColor : .blue }
    let snapshot: Snapshot
    let range: HistoryRange
    var mini = false
    var body: some View {
        let samples = snapshot.samples(range, limit: mini ? 160 : 480)
        let plotStart = snapshot.plotStart(range)
        let maximum = snapshot.maximum(range)
        Group {
            if let reason = snapshot.missingReason {
                Text(reason).font(.system(size: mini ? 11 : 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                Chart {
                ForEach(samples) { sample in
                    AreaMark(x: .value("分钟", sample.minute), y: .value(snapshot.metric.unit, sample.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [chartColor.opacity(colorScheme == .dark ? 0.24 : 0.16), chartColor.opacity(0.025)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("分钟", sample.minute), y: .value(snapshot.metric.unit, sample.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(chartColor).lineStyle(StrokeStyle(lineWidth: mini ? 1.5 : 2))
                }
                if let latest = samples.last {
                    PointMark(x: .value("分钟", latest.minute), y: .value(snapshot.metric.unit, latest.value))
                        .foregroundStyle(chartColor.opacity(colorScheme == .dark ? 0.24 : 0.16)).symbolSize(mini ? 45 : 110)
                    PointMark(x: .value("分钟", latest.minute), y: .value(snapshot.metric.unit, latest.value))
                        .foregroundStyle(chartColor).symbolSize(mini ? 9 : 24)
                }
                }
                // 范围切换和实时采样直接更新曲线，避免逐点插值阻塞滚动。
                .transaction { $0.animation = nil }
                .chartXScale(domain: plotStart...0)
                .chartYScale(domain: 0...maximum)
                .chartXAxis(.hidden)
                .chartYAxis {
                    if !mini {
                        AxisMarks(position: .leading, values: [0, maximum / 2, maximum]) { value in
                            AxisGridLine().foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.22) : Color.secondary.opacity(0.15))
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(ValueFormat.reading(number, metric: snapshot.metric, precision: snapshot.precision)).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, mini ? 0 : 8)
                if !mini {
                    HStack {
                        Text(plotStart <= -1 ? "−\((-plotStart).formatted(.number.precision(.fractionLength(0...1)))) 分钟" : "−\(Int(-plotStart * 60)) 秒")
                        Spacer()
                        Text("现在")
                    }.font(.system(size: 10)).foregroundStyle(colorScheme == .dark ? .primary : .secondary)
                }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.metric.rawValue)，最近 \(range.label)，\(snapshot.missingReason ?? snapshot.reading)")
    }
}
struct DetailSeriesChart: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.range == rhs.range && lhs.snapshot.hasSameChart(as: rhs.snapshot)
    }
    let snapshot: Snapshot
    let range: HistoryRange
    static let colors: [String: Color] = ["用户": .blue, "系统": .orange, "设备": .blue,
        "渲染器": .purple, "分块器": .orange, "活跃": .blue, "不可换出": .orange,
        "压缩": .purple, "非活跃": .teal, "空闲": .green, "读取": .blue, "写入": .orange, "接收": .blue, "发送": .orange]
    var body: some View {
        let points = snapshot.seriesSamples(range, limit: 480)
        let plotStart = snapshot.plotStart(range)
        let maximum = snapshot.maximum(range)
        let names = Array(Set(points.map(\.name))).sorted()
        VStack(alignment: .leading, spacing: 12) {
            Label("分项趋势", systemImage: "chart.xyaxis.line").font(.headline)
            if points.isEmpty {
                Text(snapshot.missingReason ?? "等待分项样本").foregroundStyle(.secondary).frame(height: 80)
            } else {
                Chart {
                    ForEach(points) { point in
                        let color = Self.colors[point.name] ?? .gray
                        AreaMark(x: .value("时间", point.minute), y: .value(snapshot.metric.unit, point.value), series: .value("连续区间", point.segment), stacking: .unstacked)
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [color.opacity(snapshot.metric == .memory ? 0.10 : 0.18), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", point.minute), y: .value(snapshot.metric.unit, point.value), series: .value("连续区间", point.segment))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(color)
                    }
                    ForEach(names, id: \.self) { name in
                        if let latest = points.last(where: { $0.name == name }) {
                            PointMark(x: .value("时间", latest.minute), y: .value(snapshot.metric.unit, latest.value))
                                .symbolSize(22).foregroundStyle(Self.colors[name] ?? .gray)
                        }
                    }
                }
                .transaction { $0.animation = nil }
                .chartXScale(domain: plotStart...0)
                .chartYScale(domain: 0...maximum)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, maximum / 2, maximum]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(ValueFormat.reading(number, metric: snapshot.metric, precision: snapshot.precision)) }
                        }
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("\(snapshot.metric.rawValue)分项趋势，包含\(names.joined(separator: "、"))")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(names, id: \.self) { name in
                        Label(name, systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Self.colors[name] ?? .gray)
                    }
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct MemorySeriesCharts: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.range == rhs.range && lhs.reduce == rhs.reduce && lhs.snapshot.hasSameChart(as: rhs.snapshot)
    }
    let snapshot: Snapshot
    let range: HistoryRange
    let reduce: Bool
    private let names = ["活跃", "非活跃", "不可换出", "压缩", "空闲"]
    var body: some View {
        let points = snapshot.seriesSamples(range, limit: 480)
        let plotStart = snapshot.plotStart(range)
        VStack(alignment: .leading, spacing: 12) {
            Label("内存分项趋势", systemImage: "chart.xyaxis.line").font(.headline)
            Text("各图纵轴独立缩放，刻度单位为 GB；高度不能直接比较。")
                .font(.caption).foregroundStyle(.secondary)
            if points.isEmpty {
                Text(snapshot.missingReason ?? "等待分项样本").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(names, id: \.self) { name in
                        let samples = points.filter { $0.name == name }
                        let scale = MemoryTrendScale.domain(samples.map(\.value))
                        let color = DetailSeriesChart.colors[name] ?? .gray
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(name, systemImage: "circle.fill").foregroundStyle(color)
                                Spacer()
                                Text(snapshot.current?.series[name].map { ValueFormat.reading($0, metric: .memory, precision: 2) } ?? "—")
                                    .monospacedDigit()
                            }.font(.caption.weight(.medium))
                            if samples.isEmpty {
                                Text("暂无样本").font(.caption).foregroundStyle(.secondary).frame(height: 90)
                            } else {
                                Chart {
                                    ForEach(samples) { point in
                                        AreaMark(x: .value("时间", point.minute), yStart: .value("下限", scale.lowerBound), yEnd: .value("GB", point.value), series: .value("连续区间", point.segment))
                                            .interpolationMethod(.monotone)
                                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.24), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                                        LineMark(x: .value("时间", point.minute), y: .value("GB", point.value), series: .value("连续区间", point.segment))
                                            .interpolationMethod(.monotone)
                                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).foregroundStyle(color)
                                    }
                                    if let latest = samples.last {
                                        PointMark(x: .value("时间", latest.minute), y: .value("GB", latest.value)).symbolSize(20).foregroundStyle(color)
                                    }
                                }
                                .transaction { $0.animation = nil }
                                .chartXScale(domain: plotStart...0)
                                .chartYScale(domain: scale)
                                .chartXAxis(.hidden)
                                .chartYAxis {
                                    AxisMarks(position: .leading, values: [scale.lowerBound, scale.upperBound]) { value in
                                        AxisGridLine()
                                        AxisValueLabel {
                                            if let number = value.as(Double.self) {
                                                Text(number.formatted(.number.precision(.fractionLength(2))))
                                            }
                                        }
                                    }
                                }
                                .frame(height: 90)
                                .accessibilityLabel("\(name)内存趋势，当前\(snapshot.current?.series[name].map { ValueFormat.reading($0, metric: .memory, precision: 2) } ?? "暂无数据")，刻度\(scale.lowerBound.formatted(.number.precision(.fractionLength(2))))至\(scale.upperBound.formatted(.number.precision(.fractionLength(2)))) GB")
                            }
                        }.padding(12).modifier(ControlMaterial(cornerRadius: 16, reduce: reduce))
                    }
                }
            }
        }
    }
}
struct RangePicker: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    private let quickRanges: [HistoryRange] = [.short, .long]
    var body: some View {
        HStack(spacing: 8) {
            if !quickRanges.contains(model.range) {
                Text(model.range.label).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("当前历史范围：\(model.range.label)")
            }
            Group {
                if #available(macOS 26.0, *), !model.reduceTransparency && !systemReduce {
                    ZStack(alignment: .leading) {
                        if let index = quickRanges.firstIndex(of: model.range) {
                            RoundedRectangle(cornerRadius: 12).fill(.clear)
                                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                                .frame(width: 84, height: 28)
                                .offset(x: CGFloat(index) * 84)
                                .allowsHitTesting(false)
                        }
                        HStack(spacing: 0) {
                            ForEach(quickRanges) { range in
                                Button {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                                        model.range = range
                                    }
                                } label: {
                                    Text(range.label).frame(maxWidth: .infinity).frame(height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(model.range == range ? .isSelected : [])
                            }
                        }
                    }
                } else {
                    Picker("历史范围", selection: Binding<HistoryRange?>(
                        get: { quickRanges.contains(model.range) ? model.range : nil },
                        set: { if let range = $0 { model.range = range } }
                    )) {
                        ForEach(quickRanges) { Text($0.label).tag(Optional.some($0)) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }.frame(width: 168)
        }.accessibilityIdentifier("rangePicker")
    }
}

private struct GlassReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presented: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content
            .opacity(presented ? 1 : 0)
            .scaleEffect(reduceMotion || presented ? 1 : 0.96)
            .offset(y: reduceMotion || presented ? 0 : 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.26).delay(delay), value: presented)
            .allowsHitTesting(presented)
    }
}
struct Overview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    @ObservedObject var model: MonitorModel
    @State private var showSettings = false
    let open: (Metric) -> Void
    let close: () -> Void
    let quit: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("性能概览").font(.headline)
                Spacer()
                Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
                    .accessibilityLabel("概览设置")
                    .popover(isPresented: $showSettings) {
                        MonitorSettings(model: model, close: { showSettings = false })
                    }
                Button(action: close) { Image(systemName: "xmark") }
                    .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
                    .accessibilityLabel("关闭概览")
            }.padding(10).modifier(ControlMaterial(cornerRadius: 22, reduce: model.reduceTransparency))
                .modifier(GlassReveal(presented: model.overviewPresented, delay: 0))
            HStack { Text("资源状态").font(.caption); Spacer(); RangePicker(model: model) }
                .padding(8).modifier(ControlMaterial(cornerRadius: 22, reduce: model.reduceTransparency))
                .modifier(GlassReveal(presented: model.overviewPresented, delay: 0.025))
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { metricCard(.cpu); metricCard(.gpu) }
                GridRow { metricCard(.memory); metricCard(.disk) }
                metricCard(.network).gridCellColumns(2)
            }
            HStack {
                Button("退出", action: quit).buttonStyle(.link)
                Spacer()
                Button("打开详情窗口") { open(model.metric) }
                    .modifier(GlassButton(reduce: model.reduceTransparency)).keyboardShortcut("1", modifiers: .command)
            }.modifier(GlassReveal(presented: model.overviewPresented, delay: 0.14))
        }.padding([.horizontal, .bottom], 16).padding(.top, 4).frame(width: 440)
            .modifier(WindowGlass(reduce: model.reduceTransparency || systemReduce, presented: model.overviewPresented, topPadding: 16, diagnostics: model.backdropDiagnostics))
            .onExitCommand(perform: close)
    }
    private func metricCard(_ metric: Metric) -> some View {
        let snapshot = model.snapshot(metric)
        return Button { open(metric) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(metric.rawValue, systemImage: metric.symbol).font(.system(size: 12, weight: .medium))
                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot.number).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: snapshot.value ?? 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: snapshot.value)
                    if snapshot.value != nil { Text(snapshot.unit).font(.caption) }
                    Spacer(minLength: 0)
                }
                Text(snapshot.status).font(.system(size: 11)).lineLimit(2)
                Trend(snapshot: snapshot, range: model.range, mini: true).equatable().frame(height: 25)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 22))
        }.modifier(GlassButton(reduce: model.reduceTransparency, card: true))
            .modifier(GlassReveal(presented: model.overviewPresented, delay: 0.04 + Double(Metric.allCases.firstIndex(of: metric) ?? 0) * 0.02))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("查看\(metric.rawValue)详情，\(snapshot.reading)")
            .accessibilityIdentifier("overview-\(metric.id)")
            .accessibilityAddTraits(.isButton)
    }
}
struct WindowGlass: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reduce: Bool
    var presented = true
    var topPadding: CGFloat = 32
    var diagnostics: BackdropDiagnostics? = nil
    func body(content: Content) -> some View {
        // 整窗只做背景模糊，避免大块玻璃透镜产生矩形明暗边界。
        content.padding([.horizontal, .bottom], 32).padding(.top, topPadding)
            .background {
                if reduce {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    PrivateRegionBackdrop(presented: presented, reduceMotion: reduceMotion, diagnostics: diagnostics).allowsHitTesting(false)
                }
            }
    }
}
struct Details: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: MonitorModel
    private var metricColor: Color { colorScheme == .dark ? darkMetricColor : .accentColor }
    @State private var sidebarVisible = true
    @State private var showSettings = false
    @State private var expandedClusters: Set<Int> = []
    let showOverview: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if sidebarVisible {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("本机资源").font(.caption.weight(.medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .modifier(ControlMaterial(reduce: model.reduceTransparency))
                        .modifier(GlassReveal(presented: model.detailsPresented, delay: 0))
                    ForEach(Array(Metric.allCases.enumerated()), id: \.element.id) { index, metric in
                        Button { selectMetric(metric) } label: {
                            HStack {
                                Label(metric.rawValue, systemImage: metric.symbol)
                                Spacer(minLength: 4)
                                Image(systemName: "checkmark").opacity(model.metric == metric ? 1 : 0)
                            }
                                .font(.system(size: 14, weight: model.metric == metric ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .foregroundStyle(model.metric == metric ? metricColor : Color.primary)
                        }.modifier(GlassButton(reduce: model.reduceTransparency, translucent: true))
                            .modifier(GlassReveal(presented: model.detailsPresented, delay: 0.025 + Double(index) * 0.02))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.metric)
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                            .help("切换到\(metric.rawValue) · ⌥⌘\(index + 1)")
                            .accessibilityLabel("切换到\(metric.rawValue)")
                            .accessibilityAddTraits(model.metric == metric ? .isSelected : [])
                    }
                    Spacer()
                }.padding(.horizontal, 10).padding(.top, 14)
            }
            .frame(width: 190).frame(maxHeight: .infinity)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.metric == .sensors {
                        sensorPage
                    } else {
                    hero
                    Trend(snapshot: model.snapshot(model.metric), range: model.range).equatable()
                        .frame(height: 180)
                    facts
                    if model.metric == .cpu { cpuCores }
                    if model.metric == .gpu { gpuAcceleration }
                    if model.metric == .memory {
                        MemorySeriesCharts(snapshot: model.snapshot(.memory), range: model.range, reduce: model.reduceTransparency).equatable()
                    } else {
                        DetailSeriesChart(snapshot: model.snapshot(model.metric), range: model.range).equatable()
                    }
                    Divider()
                    comparison
                    Divider()
                    breakdown
                    DisclosureGroup("口径说明") {
                        Text(model.snapshot(model.metric).note)
                            .font(.callout).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        Text("图表显示本次运行的数据，最多保留 24 小时。")
                            .font(.caption).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }.font(.caption).foregroundStyle(.primary)
                    }
                }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }
            // 切换指标时重置滚动位置；采样、范围和主题更新保留当前页面状态。
            .id(model.metric)
            .modifier(ControlMaterial(cornerRadius: 24, materialOpacity: 0.65, reduce: model.reduceTransparency))
            .modifier(GlassReveal(presented: model.detailsPresented, delay: 0.04))
            .navigationTitle("性能监控")
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) { sidebarToggle }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarItemGroup(placement: .primaryAction) { toolbarActions }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { sidebarToggle }
                    ToolbarItemGroup(placement: .primaryAction) { toolbarActions }
                }
            }
        }

        .toolbarBackground(.hidden, for: .windowToolbar)
        .padding(10)
        .frame(minWidth: 640, minHeight: 520)
        .modifier(WindowGlass(reduce: model.reduceTransparency || systemReduce, presented: model.detailsPresented, diagnostics: model.backdropDiagnostics))
        .onExitCommand(perform: close)
    }

    private var sidebarToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left").font(.system(size: 16)).frame(width: 28, height: 28)
        }
        .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
        .help(sidebarVisible ? "收起侧栏" : "展开侧栏")
        .accessibilityLabel(sidebarVisible ? "收起侧栏" : "展开侧栏")
        .accessibilityIdentifier("sidebarToggle")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private var toolbarActions: some View {
        Group {
            Button(action: showOverview) {
                Image(systemName: "menubar.rectangle").font(.system(size: 16)).frame(width: 28, height: 28)
            }
            .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
            .help("显示紧凑概览").accessibilityLabel("显示概览")
            Button { showSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 28, height: 28)
            }
            .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
            .help("监控设置").accessibilityLabel("设置")
            .popover(isPresented: $showSettings) {
                MonitorSettings(model: model, close: { showSettings = false })
            }
        }
    }

    private func selectMetric(_ metric: Metric) {
        guard model.metric != metric else { return }
        model.metric = metric
    }

    private var sensorPage: some View {
        let fans = model.sensors.filter { $0.unit == "rpm" }
        let groups = SensorReading.temperatureGroups(model.sensors)
        let temperatureCount = groups.reduce(0) { $0 + $1.readings.count }
        let cpuAverage = SensorReading.temperatureAverage(model.sensors, chip: SensorReading.chipName, gpu: false)
        let gpuAverage = SensorReading.temperatureAverage(model.sensors, chip: SensorReading.chipName, gpu: true)
        return VStack(alignment: .leading, spacing: 20) {
            Label("传感器", systemImage: "thermometer.medium").font(.system(size: 22, weight: .semibold))
            if !model.sensorStatus.isEmpty { Text(model.sensorStatus).font(.callout).foregroundStyle(.secondary) }
            if !model.sensors.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("风扇转速", systemImage: "fanblades").font(.headline)
                    if fans.isEmpty {
                        Text("未发现可读取的风扇转速").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(fans) { sensor in sensorRow(sensor) }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("局部平均温度", systemImage: "thermometer.medium").font(.headline)
                    ForEach([false, true], id: \.self) { gpu in
                        if let average = gpu ? gpuAverage : cpuAverage {
                            HStack {
                                Text("\(gpu ? "GPU" : "CPU") · \(average.count) 个测点")
                                Spacer()
                                Text("\(ValueFormat.number(average.value, precision: model.precision)) °C").monospacedDigit()
                            }.font(.callout)
                        }
                    }
                    if cpuAverage == nil && gpuAverage == nil {
                        Text("当前机型没有可用的已识别测点").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("参考 Stats 的 M5 系列测点映射，按可用读数等权平均；不是整机或最高温度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                DisclosureGroup("温度传感器 · \(temperatureCount) 项") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("按系统键名前缀分组；测点名称为第三方参考，并非 Apple 官方定义。核心簇测点不一定对应单个核心；附近测点不一定是部件内部温度。")
                            .font(.caption).foregroundStyle(.secondary)
                        if groups.isEmpty { Text("未发现可读取的温度传感器").font(.callout).foregroundStyle(.secondary) }
                        ForEach(groups, id: \.key) { group in
                            DisclosureGroup("\(group.key) 系列 · \(group.readings.count) 项") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(group.readings) { sensor in sensorRow(sensor) }
                                }.padding(.top, 10)
                            }
                        }
                    }.padding(.top, 12)
                }.font(.headline)
            }
            Text("数据来自 AppleSMC 私有接口，键名和可用项目因设备及系统版本而异；无风扇设备可能没有转速读数。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func sensorRow(_ sensor: SensorReading) -> some View {
        HStack {
            Text(sensor.displayName)
            Spacer()
            Text("\(ValueFormat.number(sensor.value, precision: model.precision)) \(sensor.unit)").monospacedDigit()
        }.font(.callout)
    }
    private var hero: some View {
        let snapshot = model.snapshot(model.metric)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Label(model.metric.rawValue, systemImage: model.metric.symbol).font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 12)
                RangePicker(model: model)
            }
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(snapshot.number).font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: snapshot.value ?? 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: snapshot.value)
                    if snapshot.value != nil { Text(snapshot.unit).font(.title3).foregroundStyle(.primary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(snapshot.status).font(.callout)
                    Text("最多 \(model.range.label)").font(.caption2).foregroundStyle(.primary)
                }.padding(.bottom, 5)
            }
        }
    }
    private var facts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(model.snapshot(model.metric).facts) { fact in
                VStack(alignment: .leading, spacing: 7) {
                    Text(fact.label).font(.caption).foregroundStyle(.primary)
                    Text(fact.value).font(.system(size: 17, weight: .medium)).monospacedDigit()
                }.padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .modifier(ControlMaterial(cornerRadius: 16, reduce: model.reduceTransparency))
            }
        }
    }
    private var cpuCores: some View {
        let cores = model.snapshot(.cpu).current?.cores ?? []
        return VStack(alignment: .leading, spacing: 12) {
            Label("CPU 核心簇", systemImage: "square.grid.3x3.fill").font(.headline)
            if cores.isEmpty { Text("等待核心采样").foregroundStyle(.secondary) }
            if let clusters = model.coreClusters, !cores.isEmpty {
                ForEach(clusters) { cluster in
                    let kind = cluster.indices.first.flatMap { index in model.coreLabels.flatMap { index < $0.count ? $0[index] : nil } }
                    let sameKind = kind != nil && cluster.indices.allSatisfy { model.coreLabels?[$0] == kind }
                    let total = cluster.total(cores)
                    DisclosureGroup(isExpanded: Binding(get: { expandedClusters.contains(cluster.id) }, set: { expanded in
                        if expanded { expandedClusters.insert(cluster.id) } else { expandedClusters.remove(cluster.id) }
                    })) {
                        coreGrid(cluster.indices, cores: cores).padding(.top, 12)
                    } label: {
                        HStack {
                            Text("\(sameKind ? kind! + " · " : "")簇 \(cluster.id)")
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 8)
                            Text("\(cluster.indices.count) 核 · 总量 \(total.map { ValueFormat.number($0, precision: 1) + "%" } ?? "—") / \(cluster.indices.count * 100)% · 平均 \(total.map { ValueFormat.number($0 / Double(cluster.indices.count), precision: 1) + "%" } ?? "—")")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }.padding(.vertical, 4)
                    }
                    if cluster.id != clusters.last?.id { Divider() }
                }
            } else if !cores.isEmpty {
                Text("无法读取核心簇拓扑，显示全部逻辑核心。")
                    .font(.caption).foregroundStyle(.secondary)
                coreGrid(Array(cores.indices), cores: cores)
            }
        }
    }
    private func coreGrid(_ indices: [Int], cores: [Double?]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
            ForEach(indices, id: \.self) { index in
                let value = cores[index]
                let kind = model.coreLabels.flatMap { index < $0.count ? $0[index] : nil }
                let color: Color = kind == "超能核" ? Color(red: 0.78, green: 0.47, blue: 0.98) : kind == "性能核" ? Color(red: 0.48, green: 0.32, blue: 0.9) : kind == "能效核" ? .teal : metricColor
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(kind ?? "核心") \(index + 1)").lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "—").monospacedDigit().fixedSize()
                    }
                    ProgressView(value: value ?? 0, total: 100).tint(color)
                }.font(.caption).padding(10).frame(maxWidth: .infinity, minHeight: 64).modifier(ControlMaterial(reduce: model.reduceTransparency))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(kind ?? "核心") \(index + 1)，\(value.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "暂无数据")")
            }
        }
    }
    private var gpuAcceleration: some View {
        let capabilities = GPUReader.capabilities
        return VStack(alignment: .leading, spacing: 12) {
            Label("AI 与图形能力", systemImage: "brain.head.profile").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("GPU Neural Accelerator", systemImage: "cpu")
                    Text(capabilities.supportsNeuralAccelerator == true ? "支持 · 每个 GPU 核心内置" : "未确认硬件支持")
                    Text("独立利用率：暂不可读取").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).padding(12)
                    .modifier(ControlMaterial(cornerRadius: 16, reduce: model.reduceTransparency))
                VStack(alignment: .leading, spacing: 6) {
                    Label("Apple Neural Engine", systemImage: "brain")
                    Text("独立神经网络引擎")
                    Text(model.snapshot(.gpu).current?.anePower.map { "平均功耗：\(ValueFormat.number($0, precision: 2)) W" } ?? "平均功耗：暂不可用")
                    Text("利用率：暂不可读取").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).padding(12)
                    .modifier(ControlMaterial(cornerRadius: 16, reduce: model.reduceTransparency))
            }.font(.caption)
            HStack {
                Text("GPU 核心数")
                Spacer()
                Text(capabilities.coreCount.map { "\($0)" } ?? "—").monospacedDigit()
                Text("· 光线追踪")
                Text(capabilities.supportsRayTracing.map { $0 ? "支持" : "不支持" } ?? "未知")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("趋势对照").font(.system(size: 13, weight: .medium)); Spacer(); Text("不同单位").font(.caption).foregroundStyle(.primary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                ForEach(Metric.allCases.filter { $0 != .sensors }) { metric in
                    let snapshot = model.snapshot(metric)
                    Button { selectMetric(metric) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(metric.rawValue).font(.caption).foregroundStyle(.primary)
                            Text(snapshot.reading).font(.system(size: 14, weight: .medium)).monospacedDigit()
                                .contentTransition(.numericText(value: snapshot.value ?? 0))
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: snapshot.value)
                            Trend(snapshot: snapshot, range: model.range, mini: true).equatable().frame(height: 25)
                        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.metric == metric ? metricColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel("对照\(metric.rawValue)，\(snapshot.reading)")
                        .accessibilityAddTraits(model.metric == metric ? .isSelected : [])
                }
            }
        }
    }
    private var breakdown: some View {
        let snapshot = model.snapshot(model.metric)
        let rows = snapshot.rows
        return VStack(alignment: .leading, spacing: 12) {
            Text("细分信息")
                .font(.system(size: 13, weight: .medium))
            if rows.isEmpty {
                Text(snapshot.missingReason ?? "暂无数据").font(.callout).foregroundStyle(.primary)
            } else {
                ForEach(rows) { row in
                    HStack { Text(row.label).foregroundStyle(.primary); Spacer(); Text(row.value).monospacedDigit() }.font(.callout)
                }
            }
        }
    }
}
