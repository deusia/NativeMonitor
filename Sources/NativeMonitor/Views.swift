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
struct MonitorSettings: View {
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    @ObservedObject var model: MonitorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("外观")
                Spacer()
                Menu {
                    ForEach(Theme.allCases) { theme in
                        Button { model.theme = theme } label: {
                            if model.theme == theme { Label(theme.rawValue, systemImage: "checkmark") }
                            else { Text(theme.rawValue) }
                        }
                    }
                } label: {
                    HStack { Text(model.theme.rawValue); Spacer(minLength: 8); Image(systemName: "chevron.down") }
                        .padding(.horizontal, 12).frame(width: 170, height: 30)
                        .contentShape(Rectangle())
                        .modifier(ControlMaterial(cornerRadius: 15, reduce: model.reduceTransparency))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel("外观").accessibilityValue(model.theme.rawValue)
                .accessibilityIdentifier("themePicker")
            }
            Picker("采样间隔", selection: $model.interval) {
                Text("1 秒").tag(1); Text("2 秒").tag(2); Text("5 秒").tag(5)
            }
            Picker("CPU 口径", selection: $model.cpuScale) {
                ForEach(CPUScale.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("主读数小数位", selection: $model.precision) {
                Text("最多 0 位").tag(0); Text("最多 1 位").tag(1); Text("最多 2 位").tag(2)
            }
            Text("速率自动选择 B/s、KB/s、MB/s 或 GB/s。设置会自动保存。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("减少透明度", isOn: $model.reduceTransparency).toggleStyle(.switch)
            if !model.reduceTransparency && !systemReduce {
                BackdropStatus(diagnostics: model.backdropDiagnostics)
            }
        }.font(.system(size: 12)).padding(14)
            .modifier(ControlMaterial(cornerRadius: 22, reduce: model.reduceTransparency))
    }
}
struct Trend: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var chartColor: Color { colorScheme == .dark ? darkMetricColor : .blue }
    let snapshot: Snapshot
    let range: HistoryRange
    var mini = false
    @State private var revealed = false
    var body: some View {
        let samples = snapshot.samples(range)
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
                .chartXScale(domain: snapshot.plotStart(range)...0)
                .chartYScale(domain: 0...snapshot.maximum)
                .chartXAxis(.hidden)
                .chartYAxis {
                    if !mini {
                        AxisMarks(position: .leading, values: [0, snapshot.maximum / 2, snapshot.maximum]) { value in
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
                .mask(alignment: .leading) {
                    Rectangle().scaleEffect(x: revealed || reduceMotion ? 1 : 0, anchor: .leading)
                }
                .onAppear {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55)) { revealed = true }
                }
                .onDisappear { revealed = false }
                if !mini {
                    HStack {
                        Text(snapshot.plotStart(range) <= -1 ? "−\((-snapshot.plotStart(range)).formatted(.number.precision(.fractionLength(0...1)))) 分钟" : "−\(Int(-snapshot.plotStart(range) * 60)) 秒")
                        Spacer()
                        Text("现在")
                    }.font(.system(size: 10)).foregroundStyle(colorScheme == .dark ? .primary : .secondary)
                }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: samples)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.metric.rawValue)，最近 \(range.rawValue) 分钟，\(snapshot.missingReason ?? snapshot.reading)，\(snapshot.sourceLabel)")
    }
}
struct DetailSeriesChart: View {
    let snapshot: Snapshot
    let range: HistoryRange
    private let colors: [String: Color] = ["用户": .blue, "系统": .orange, "设备": .blue,
        "渲染器": .purple, "分块器": .orange, "活跃": .blue, "不可换出": .orange,
        "压缩": .purple, "读取": .blue, "写入": .orange, "接收": .blue, "发送": .orange]
    var body: some View {
        let points = snapshot.seriesSamples(range)
        let names = Array(Set(points.map(\.name))).sorted()
        VStack(alignment: .leading, spacing: 12) {
            Label("分项趋势", systemImage: "chart.xyaxis.line").font(.headline)
            if points.isEmpty {
                Text(snapshot.missingReason ?? "等待分项样本").foregroundStyle(.secondary).frame(height: 80)
            } else {
                Chart {
                    ForEach(points) { point in
                        let color = colors[point.name] ?? .gray
                        AreaMark(x: .value("时间", point.minute), y: .value(snapshot.metric.unit, point.value), series: .value("连续区间", point.segment), stacking: .unstacked)
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.18), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", point.minute), y: .value(snapshot.metric.unit, point.value), series: .value("连续区间", point.segment))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(color)
                    }
                    ForEach(names, id: \.self) { name in
                        if let latest = points.last(where: { $0.name == name }) {
                            PointMark(x: .value("时间", latest.minute), y: .value(snapshot.metric.unit, latest.value))
                                .symbolSize(22).foregroundStyle(colors[name] ?? .gray)
                        }
                    }
                }
                .chartXScale(domain: snapshot.plotStart(range)...0)
                .chartYScale(domain: 0...snapshot.maximum)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, snapshot.maximum / 2, snapshot.maximum]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(ValueFormat.reading(number, metric: snapshot.metric, precision: snapshot.precision)) }
                        }
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("\(snapshot.metric.rawValue)分项趋势，包含\(names.joined(separator: "、"))")
                HStack(spacing: 16) {
                    ForEach(names, id: \.self) { name in
                        Label(name, systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(colors[name] ?? .gray)
                    }
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct RangePicker: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    var body: some View {
        Group {
            if #available(macOS 26.0, *), !model.reduceTransparency && !systemReduce {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 12).fill(.clear)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                        .frame(width: 84, height: 28)
                        .offset(x: model.range == .short ? 0 : 84)
                        .allowsHitTesting(false)
                    HStack(spacing: 0) {
                        ForEach(HistoryRange.allCases) { range in
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
                Picker("历史范围", selection: $model.range) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
        }.frame(width: 168).accessibilityIdentifier("rangePicker")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("性能概览").font(.headline)
                    Text("本机实时采样 · GPU 为实验性数据").font(.system(size: 11))
                }
                Spacer()
                Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
                    .accessibilityLabel("概览设置")
                    .popover(isPresented: $showSettings) {
                        MonitorSettings(model: model).padding(14).frame(width: 350)
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
                Button("退出原型", action: quit).buttonStyle(.link)
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
                HStack {
                    Label(metric.rawValue, systemImage: metric.symbol).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("实时").font(.system(size: 10))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot.number).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: snapshot.value ?? 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: snapshot.value)
                    if snapshot.value != nil { Text(snapshot.unit).font(.caption) }
                    Spacer(minLength: 0)
                }
                Text(snapshot.status).font(.system(size: 11)).lineLimit(2)
                Trend(snapshot: snapshot, range: model.range, mini: true).frame(height: 25)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 22))
        }.modifier(GlassButton(reduce: model.reduceTransparency, card: true))
            .modifier(GlassReveal(presented: model.overviewPresented, delay: 0.04 + Double(Metric.allCases.firstIndex(of: metric) ?? 0) * 0.02))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("查看\(metric.rawValue)详情，\(snapshot.reading)，\(snapshot.sourceLabel)")
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
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var glowMetric: Metric?
    @State private var glowVisible = false
    @State private var glowGeneration = 0
    @State private var showSettings = false
    let showOverview: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if columns != .detailOnly {
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
                            .overlay {
                                if glowMetric == metric, !reduceMotion {
                                    Capsule().stroke(metricColor.opacity(glowVisible ? 0.5 : 0), lineWidth: 2)
                                        .scaleEffect(glowVisible ? 1 : 1.10)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.metric)
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                            .help("切换到\(metric.rawValue) · ⌥⌘\(index + 1)")
                            .accessibilityLabel("切换到\(metric.rawValue)")
                            .accessibilityAddTraits(model.metric == metric ? .isSelected : [])
                    }
                    Spacer()
                }.padding(.horizontal, 10).padding(.top, 14)
                Text("本机实时采样\nGPU 为实验性数据")
                    .font(.system(size: 11)).foregroundStyle(.primary)
                    .padding(12).modifier(ControlMaterial(reduce: model.reduceTransparency))
                    .modifier(GlassReveal(presented: model.detailsPresented, delay: 0.14)).padding(10)
            }
            .frame(width: 190).frame(maxHeight: .infinity)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    Trend(snapshot: model.snapshot(model.metric), range: model.range)
                        .frame(height: 180)
                    facts
                    if model.metric == .cpu { cpuCores }
                    DetailSeriesChart(snapshot: model.snapshot(model.metric), range: model.range)
                    Divider()
                    comparison
                    Divider()
                    breakdown
                    DisclosureGroup("口径说明") {
                        Text(model.snapshot(model.metric).note)
                            .font(.callout).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        Text("图表仅显示本次启动后的真实样本，最多保留 30 分钟。")
                            .font(.caption).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }.font(.caption).foregroundStyle(.primary)
                }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }
            // A different metric is a new detail page. Reset only its scroll subtree;
            // live sample updates, range, theme and sidebar state retain identity.
            .id(model.metric)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
            .modifier(ControlMaterial(cornerRadius: 24, materialOpacity: 0.65, reduce: model.reduceTransparency))
            .modifier(GlassReveal(presented: model.detailsPresented, delay: 0.04))
            .navigationTitle("性能监控")
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) { sidebarToggle }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) { toolbarActions }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { sidebarToggle }
                    ToolbarItem(placement: .primaryAction) { toolbarActions }
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
                columns = columns == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left").font(.system(size: 16)).frame(width: 36, height: 36)
                .background(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .padding(4)
                .contentShape(Circle())
                .modifier(ControlMaterial(cornerRadius: 22, reduce: model.reduceTransparency))
        }
        .buttonStyle(.plain)
        .help(columns == .detailOnly ? "展开侧栏" : "收起侧栏")
        .accessibilityLabel(columns == .detailOnly ? "展开侧栏" : "收起侧栏")
        .accessibilityIdentifier("sidebarToggle")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private var toolbarActions: some View {
        HStack(spacing: 4) {
            Button(action: showOverview) {
                Image(systemName: "menubar.rectangle").font(.system(size: 16)).frame(width: 36, height: 36)
                    .background(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("显示紧凑概览").accessibilityLabel("显示概览")
            Button { showSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 36, height: 36)
                    .background(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("监控设置").accessibilityLabel("设置")
            .popover(isPresented: $showSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("设置").font(.headline); Spacer(); Button("完成") { showSettings = false }.modifier(GlassButton(reduce: model.reduceTransparency)) }
                    MonitorSettings(model: model)
                    Text("设置只影响本应用。").font(.caption).foregroundStyle(.primary)
                }.padding(18).frame(width: 350)
            }
        }
        .padding(4)
        .modifier(ControlMaterial(cornerRadius: 22, reduce: model.reduceTransparency))
    }

    private func selectMetric(_ metric: Metric) {
        guard model.metric != metric else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { model.metric = metric }
        guard !reduceMotion else { return }
        glowGeneration += 1
        let generation = glowGeneration
        glowMetric = metric
        glowVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            guard generation == glowGeneration else { return }
            withAnimation(.easeOut(duration: 0.42)) { glowVisible = false }
        }
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
                        .id(model.metric)
                        .contentTransition(.numericText(value: snapshot.value ?? 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: snapshot.value)
                    if snapshot.value != nil { Text(snapshot.unit).font(.title3).foregroundStyle(.primary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(snapshot.status).font(.callout)
                    Text(snapshot.sourceLabel).font(.caption).foregroundStyle(.primary)
                    Text("最多 \(model.range.rawValue) 分钟 · 启动后实测").font(.caption2).foregroundStyle(.primary)
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
            Label("逻辑核心", systemImage: "square.grid.3x3.fill").font(.headline)
            if cores.isEmpty { Text("等待核心采样").foregroundStyle(.secondary) }
            if model.coreLabels != nil {
                Text("类型根据系统拓扑和核心数量推断，颜色用于区分核心类别。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                    let kind = model.coreLabels.flatMap { index < $0.count ? $0[index] : nil }
                    let color: Color = kind == "超能核" ? Color(red: 0.78, green: 0.47, blue: 0.98) : kind == "性能核" ? Color(red: 0.48, green: 0.32, blue: 0.9) : kind == "能效核" ? .teal : metricColor
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("\(kind ?? "核心") \(index + 1)"); Spacer(); Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "—").monospacedDigit() }
                        ProgressView(value: value ?? 0, total: 100).tint(color)
                    }.font(.caption).padding(10).modifier(ControlMaterial(reduce: model.reduceTransparency))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(kind ?? "核心") \(index + 1)，\(value.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "暂无数据")")
                }
            }
        }
    }
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("趋势对照").font(.system(size: 13, weight: .medium)); Spacer(); Text("独立量纲 · 实时采样").font(.caption).foregroundStyle(.primary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                ForEach(Metric.allCases) { metric in
                    let snapshot = model.snapshot(metric)
                    Button { selectMetric(metric) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("\(metric.rawValue) · 实时").font(.caption).foregroundStyle(.primary)
                            Text(snapshot.reading).font(.system(size: 14, weight: .medium)).monospacedDigit()
                                .contentTransition(.numericText(value: snapshot.value ?? 0))
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: snapshot.value)
                            Trend(snapshot: snapshot, range: model.range, mini: true).frame(height: 25)
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
        return VStack(alignment: .leading, spacing: 12) {
            Text("细分信息")
                .font(.system(size: 13, weight: .medium))
            if snapshot.rows.isEmpty {
                Text(snapshot.missingReason ?? "暂无数据").font(.callout).foregroundStyle(.primary)
            } else {
                ForEach(snapshot.rows) { row in
                    HStack { Text(row.label).foregroundStyle(.primary); Spacer(); Text(row.value).monospacedDigit() }.font(.callout)
                }
            }
        }
    }
}
