import SwiftUI
import Charts
import PrivateBackdrop

struct WindowMaterial: NSViewRepresentable {
    let reduce: Bool
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        let mask = Self.edgeMask()
        mask.size = NSSize(width: 193, height: 193)
        mask.capInsets = NSEdgeInsets(top: 96, left: 96, bottom: 96, right: 96)
        view.maskImage = mask
        return view
    }
    static func edgeMask() -> NSImage {
        let image = NSImage(size: NSSize(width: 65, height: 65), flipped: false) { rect in
            NSGraphicsContext.current?.compositingOperation = .copy
            for inset in 0...24 {
                let t = CGFloat(inset) / 24
                NSColor.white.withAlphaComponent(t * t * (3 - 2 * t)).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(inset), dy: CGFloat(inset)),
                             xRadius: 32 - CGFloat(inset), yRadius: 32 - CGFloat(inset)).fill()
            }
            return true
        }
        image.capInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        image.resizingMode = .stretch
        return image
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        // 统一承托底板采样窗口后方；前景模块不重复叠加 HUD 模糊。
        view.alphaValue = 1
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.isHidden = reduce
    }
}
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
                    RoundedRectangle(cornerRadius: 22).fill(colorScheme == .dark ? Color.black.opacity(0.72) : .clear)
                        .glassEffect((colorScheme == .dark ? Glass.regular : Glass.clear).interactive(), in: RoundedRectangle(cornerRadius: 22))
                        .opacity(colorScheme == .dark ? 1 : translucent ? 0.65 : 1)
                        .allowsHitTesting(false)
                }
            } else {
                content.buttonStyle(.glass).buttonBorderShape(circular ? .circle : .capsule)
                    .background {
                        if colorScheme == .dark {
                            if circular { Circle().fill(Color.black.opacity(0.72)) }
                            else { Capsule().fill(Color.black.opacity(0.72)) }
                        }
                    }
            }
        } else { content.buttonStyle(.bordered) }
    }
}

struct PrivateRegionBackdrop: NSViewRepresentable {
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
                RoundedRectangle(cornerRadius: cornerRadius).fill(colorScheme == .dark ? Color.black.opacity(0.72) : .clear)
                    .glassEffect(colorScheme == .dark ? .regular : .clear, in: RoundedRectangle(cornerRadius: cornerRadius))
                    .opacity(colorScheme == .dark ? 1 : materialOpacity)
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
struct DemoControls: View {
    @ObservedObject var model: MonitorModel
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("场景", selection: $model.scenario) {
                    ForEach(Scenario.allCases) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("scenarioPicker")
                if !compact { themePicker }
            }
            HStack {
                if compact { themePicker }
                Toggle("减少透明度", isOn: $model.reduceTransparency).toggleStyle(.checkbox)
                Spacer(minLength: 0)
            }
            Toggle("实验性区域模糊（私有 API）", isOn: $model.experimentalBlur).toggleStyle(.checkbox)
            if model.experimentalBlur {
                BackdropStatus(diagnostics: model.backdropDiagnostics)
            }
        }.font(.system(size: 12)).padding(10)
            .modifier(ControlMaterial(reduce: model.reduceTransparency))
    }
    var themePicker: some View {
        Picker("外观", selection: $model.theme) { ForEach(Theme.allCases) { Text($0.rawValue).tag($0) } }
            .accessibilityIdentifier("themePicker")
    }
}
struct Trend: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var chartColor: Color { colorScheme == .dark ? Color(red: 0.35, green: 0.75, blue: 1) : .blue }
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
                .chartYScale(domain: 0...snapshot.metric.maximum)
                .chartXAxis(.hidden)
                .chartYAxis {
                    if !mini {
                        AxisMarks(position: .leading, values: [0, snapshot.metric.maximum / 2, snapshot.metric.maximum]) { value in
                            AxisGridLine().foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.22) : Color.secondary.opacity(0.15))
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text("\(number.formatted()) \(snapshot.metric.unit)").foregroundStyle(.primary)
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
struct RangePicker: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        Picker("历史范围", selection: $model.range) {
            ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 168).accessibilityIdentifier("rangePicker")
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
                    Text("GPU 实测 · 其余模拟").font(.system(size: 11))
                }
                Spacer()
                Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
                    .accessibilityLabel("概览演示设置")
                    .popover(isPresented: $showSettings) {
                        DemoControls(model: model, compact: true).padding(14).frame(width: 350)
                    }
                Button(action: close) { Image(systemName: "xmark") }
                    .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
                    .accessibilityLabel("关闭概览")
            }.padding(10).modifier(ControlMaterial(reduce: model.reduceTransparency))
            HStack { Text("资源状态").font(.caption); Spacer(); RangePicker(model: model) }
                .padding(8).modifier(ControlMaterial(reduce: model.reduceTransparency))
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
            }
        }.padding(16).frame(width: 440)
            .opacity(model.overviewPresented ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.overviewPresented)
            .modifier(WindowGlass(reduce: model.reduceTransparency || systemReduce, experimental: model.experimentalBlur, diagnostics: model.backdropDiagnostics))
            .onExitCommand(perform: close)
    }
    private func metricCard(_ metric: Metric) -> some View {
        let snapshot = model.snapshot(metric)
        return Button { open(metric) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(metric.rawValue, systemImage: metric.symbol).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(metric == .gpu ? "实时" : "模拟").font(.system(size: 10))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot.number).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: snapshot.value ?? 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: snapshot.value)
                    if snapshot.value != nil { Text(metric.unit).font(.caption) }
                    Spacer(minLength: 0)
                }
                Text(snapshot.status).font(.system(size: 11)).lineLimit(2)
                Trend(snapshot: snapshot, range: model.range, mini: true).frame(height: 25)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 22))
        }.modifier(GlassButton(reduce: model.reduceTransparency, card: true))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("查看\(metric.rawValue)详情，\(snapshot.reading)，\(snapshot.sourceLabel)")
            .accessibilityIdentifier("overview-\(metric.id)")
            .accessibilityAddTraits(.isButton)
    }
}
struct WindowGlass: ViewModifier {
    let reduce: Bool
    var experimental = false
    var diagnostics: BackdropDiagnostics? = nil
    func body(content: Content) -> some View {
        // 整窗只做背景模糊，避免大块玻璃透镜产生矩形明暗边界。
        content.padding(32)
            .background {
                if reduce {
                    Color(nsColor: .windowBackgroundColor)
                } else if experimental {
                    PrivateRegionBackdrop(diagnostics: diagnostics).allowsHitTesting(false)
                }
            }
    }
}
struct Details: View {
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: MonitorModel
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
                                .foregroundStyle(model.metric == metric ? Color.accentColor : Color.primary)
                        }.modifier(GlassButton(reduce: model.reduceTransparency, translucent: true))
                            .overlay {
                                if glowMetric == metric, !reduceMotion {
                                    Capsule().stroke(Color.accentColor.opacity(glowVisible ? 0.5 : 0), lineWidth: 2)
                                        .blur(radius: glowVisible ? 2 : 6)
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
                Text("GPU 实验性实时\n其他指标为模拟数据")
                    .font(.system(size: 11)).foregroundStyle(.primary)
                    .padding(12).modifier(ControlMaterial(reduce: model.reduceTransparency)).padding(10)
            }
            .frame(width: 190).frame(maxHeight: .infinity)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    Trend(snapshot: model.snapshot(model.metric), range: model.range)
                        .frame(height: 180)
                    facts
                    Divider()
                    comparison
                    Divider()
                    breakdown
                    DisclosureGroup("口径说明") {
                        Text(model.snapshot(model.metric).note)
                            .font(.callout).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        Text("GPU 为驱动实时样本；其他指标为模拟数据。")
                            .font(.caption).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }.font(.caption).foregroundStyle(.primary)
                }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }
            // A different metric is a new detail page. Reset only its scroll subtree;
            // live sample updates, range, theme and sidebar state retain identity.
            .id(model.metric)
            .modifier(ControlMaterial(cornerRadius: 24, materialOpacity: 0.65, reduce: model.reduceTransparency))
            .navigationTitle("性能监控")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                            columns = columns == .detailOnly ? .all : .detailOnly
                        }
                    } label: { Image(systemName: "sidebar.left") }
                    .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
                    .help(columns == .detailOnly ? "展开侧栏" : "收起侧栏")
                    .accessibilityLabel(columns == .detailOnly ? "展开侧栏" : "收起侧栏")
                    .accessibilityIdentifier("sidebarToggle")
                    .keyboardShortcut("s", modifiers: [.command, .control])
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: showOverview) { Label("概览", systemImage: "menubar.rectangle") }
                        .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
                        .help("显示紧凑概览").accessibilityLabel("显示概览")
                    Button { showSettings.toggle() } label: { Label("演示设置", systemImage: "slider.horizontal.3") }
                        .modifier(GlassButton(reduce: model.reduceTransparency, circular: true))
                        .help("演示场景与外观").accessibilityLabel("演示设置")
                        .popover(isPresented: $showSettings) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Text("演示设置").font(.headline); Spacer(); Button("完成") { showSettings = false }.modifier(GlassButton(reduce: model.reduceTransparency)) }
                                DemoControls(model: model, compact: true)
                                Text("只改变原型，不修改系统设置。").font(.caption).foregroundStyle(.primary)
                            }.padding(18).frame(width: 350)
                        }
                }
            }
        }

        .toolbarBackground(.hidden, for: .windowToolbar)
        .padding(10)
        .frame(minWidth: 640, minHeight: 520)
        .opacity(model.detailsPresented ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.detailsPresented)
        .modifier(WindowGlass(reduce: model.reduceTransparency || systemReduce, experimental: model.experimentalBlur, diagnostics: model.backdropDiagnostics))
        .onExitCommand(perform: close)
    }

    private func selectMetric(_ metric: Metric) {
        model.metric = metric
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
                Text(model.metric.rawValue).font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 12)
                RangePicker(model: model)
            }
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(snapshot.number).font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
                        .id(model.metric)
                        .contentTransition(.numericText(value: snapshot.value ?? 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: snapshot.value)
                    if snapshot.value != nil { Text(model.metric.unit).font(.title3).foregroundStyle(.primary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(snapshot.status).font(.callout)
                    Text(snapshot.sourceLabel).font(.caption).foregroundStyle(.primary)
                    if model.metric == .gpu { Text("最多 \(model.range.rawValue) 分钟 · 启动后实测").font(.caption2).foregroundStyle(.primary) }
                }.padding(.bottom, 5)
            }
        }
    }
    private var facts: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(model.snapshot(model.metric).facts) { fact in
                VStack(alignment: .leading, spacing: 7) {
                    Text(fact.label).font(.caption).foregroundStyle(.primary)
                    Text(fact.value).font(.system(size: 17, weight: .medium)).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("趋势对照").font(.system(size: 13, weight: .medium)); Spacer(); Text("独立量纲 · GPU 实测").font(.caption).foregroundStyle(.primary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                ForEach(Metric.allCases) { metric in
                    let snapshot = model.snapshot(metric)
                    Button { model.metric = metric } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(metric == .gpu ? "GPU · 实时" : "\(metric.rawValue) · 模拟").font(.caption).foregroundStyle(.primary)
                            Text(snapshot.reading).font(.system(size: 14, weight: .medium)).monospacedDigit()
                                .contentTransition(.numericText(value: snapshot.value ?? 0))
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: snapshot.value)
                            Trend(snapshot: snapshot, range: model.range, mini: true).frame(height: 25)
                        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.metric == metric ? Color.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel("对照\(metric.rawValue)，\(snapshot.reading)")
                        .accessibilityAddTraits(model.metric == metric ? .isSelected : [])
                }
            }
        }
    }
    private var breakdown: some View {
        let snapshot = model.snapshot(model.metric)
        return VStack(alignment: .leading, spacing: 12) {
            Text([Metric.cpu, .memory].contains(model.metric) ? "高占用进程 · 模拟" : "细分信息")
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
