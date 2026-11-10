import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreImage.CIFilterBuiltins
import OSLog

@MainActor final class BackdropDiagnostics: ObservableObject {
    @Published private(set) var reports: [UUID: String] = [:]
    func update(_ id: UUID, _ text: String) { reports[id] = text }
    func remove(_ id: UUID) { reports.removeValue(forKey: id) }
    var summary: String { reports.values.sorted().joined(separator: "\n") }
}

struct BackdropGeometry: Equatable {
    let source: CGRect
    let destination: CGRect
    static func make(view: CGRect, screen: CGRect) -> BackdropGeometry? {
        guard !view.isEmpty, [view.minX, view.minY, view.width, view.height].allSatisfy(\.isFinite) else { return nil }
        let rect = view.integral
        guard screen.contains(rect), rect.width <= 4096, rect.height <= 4096 else { return nil }
        return BackdropGeometry(
            source: CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height),
            destination: CGRect(x: rect.minX - view.minX, y: rect.minY - view.minY, width: rect.width, height: rect.height))
    }
}

final class BackdropRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cachedSize = CGSize.zero
    private var blurMask: CIImage?
    private var edgeMask: CIImage?
    static func mask(width: Int, height: Int, feather: Double) -> CIImage? {
        guard width > 0, height > 0, width <= 4096, height <= 4096, feather.isFinite, feather > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let radius = min(64.0, Double(min(width, height)) / 3)
        for y in 0..<height { for x in 0..<width {
            let qx = abs(Double(x) + 0.5 - Double(width)/2) - Double(width)/2 + radius
            let qy = abs(Double(y) + 0.5 - Double(height)/2) - Double(height)/2 + radius
            let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
            let t = min(1, max(0, -distance / feather))
            let gray = UInt8((255 * t*t*(3-2*t)).rounded())
            let offset = (y*width+x)*4
            bytes[offset] = gray; bytes[offset+1] = gray; bytes[offset+2] = gray; bytes[offset+3] = 255
        }}
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width*4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    func render(_ input: CIImage) -> CGImage? {
        let extent = input.extent
        guard extent.width > 0, extent.height > 0, extent.width <= 4096, extent.height <= 4096 else { return nil }
        if cachedSize != extent.size {
            cachedSize = extent.size
            blurMask = Self.mask(width: Int(extent.width), height: Int(extent.height), feather: 80)
            edgeMask = Self.mask(width: Int(extent.width), height: Int(extent.height), feather: 12)
        }
        guard let blurMask, let edgeMask else { return nil }
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = input.clampedToExtent()
        blur.mask = blurMask
        blur.radius = 12
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return nil }
        let composite = CIFilter.blendWithMask()
        composite.inputImage = blurred
        composite.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        composite.maskImage = edgeMask
        guard let result = composite.outputImage else { return nil }
        return context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

private final class BackdropStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "local.ashen.backdrop.render", qos: .utility)
    private let renderer = BackdropRenderer()
    private let lock = NSLock()
    private var stopped = false
    private var pending = false
    private var frames = 0
    private var elapsedMS: Double = 0
    private var maximumMS: Double = 0
    private let began = ProcessInfo.processInfo.systemUptime
    let deliver: (CGImage, String) -> Void
    let failure: (String) -> Void
    init(deliver: @escaping (CGImage, String) -> Void, failure: @escaping (String) -> Void) {
        self.deliver = deliver; self.failure = failure
    }
    func invalidate() { lock.lock(); stopped = true; lock.unlock() }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        DispatchQueue.main.async { [failure] in failure("采集已中断（\(code)）；请重新开启实验模式或检查屏幕录制权限") }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .blank || status == .suspended || status == .stopped {
            DispatchQueue.main.async { [failure] in failure("屏幕采集暂停；已清除背景，请重新开启实验模式") }
            return
        }
        guard status == .complete, let pixelBuffer = buffer.imageBuffer else { return }
        lock.lock()
        guard !stopped, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        let start = ProcessInfo.processInfo.systemUptime
        guard let image = autoreleasepool(invoking: { renderer.render(CIImage(cvPixelBuffer: pixelBuffer)) }) else {
            lock.lock(); pending = false; lock.unlock()
            DispatchQueue.main.async { [failure] in failure("背景渲染失败；已回退系统材质") }
            return
        }
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        frames += 1; elapsedMS += ms; maximumMS = max(maximumMS, ms)
        let seconds = max(0.1, ProcessInfo.processInfo.systemUptime - began)
        let report = String(format: "本地采集 · %d 帧 · %.1f 帧/秒\n渲染平均 %.1f ms · 最大 %.1f ms · %d×%d", frames, Double(frames)/seconds, elapsedMS/Double(frames), maximumMS, image.width, image.height)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let valid = !self.stopped; self.pending = false; self.lock.unlock()
            if valid { self.deliver(image, report) }
        }
    }
}

struct ExperimentalBackdrop: NSViewRepresentable {
    let diagnostics: BackdropDiagnostics
    func makeNSView(context: Context) -> CapturedBackdropView { CapturedBackdropView(diagnostics: diagnostics) }
    func updateNSView(_ view: CapturedBackdropView, context: Context) {}
    static func dismantleNSView(_ view: CapturedBackdropView, coordinator: ()) { view.shutdown() }
}

@MainActor final class CapturedBackdropView: NSView {
    private let id = UUID()
    private let diagnostics: BackdropDiagnostics
    private let fallback = NSVisualEffectView()
    private let imageLayer = CALayer()
    private var observers: [NSObjectProtocol] = []
    private var stream: SCStream?
    private var output: BackdropStreamOutput?
    private var reconcileTask: Task<Void, Never>?
    private var revision = 0
    private var firstFrameTimeout: Task<Void, Never>?
    private var disabled = false
    private var lastGeometry: BackdropGeometry?
    private var reportTime: TimeInterval = 0
    private let logger = Logger(subsystem: "local.ashen.NativeMonitorPrototype", category: "ExperimentalBackdrop")
    init(diagnostics: BackdropDiagnostics) {
        self.diagnostics = diagnostics
        super.init(frame: .zero)
        wantsLayer = true
        fallback.material = .hudWindow; fallback.blendingMode = .behindWindow; fallback.state = .active
        fallback.maskImage = WindowMaterial.edgeMask()
        addSubview(fallback)
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("此视图只通过代码创建") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh(force: true) }
                })
            }
        }
        refresh(force: true)
    }
    override func layout() {
        super.layout()
        fallback.frame = bounds
        refresh(force: false)
    }
    private func request() -> (BackdropGeometry, CGDirectDisplayID)? {
        guard !disabled, let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        guard let geometry = BackdropGeometry.make(view: rect, screen: screen.frame) else {
            diagnostics.update(id, "跨屏或区域过大；移动到单块屏幕内后重试")
            return nil
        }
        return (geometry, number.uint32Value)
    }
    private func refresh(force: Bool) {
        let desired = request()
        guard force || desired?.0 != lastGeometry else { return }
        lastGeometry = desired?.0
        revision += 1
        imageLayer.contents = nil; fallback.isHidden = false
        output?.invalidate()
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        guard reconcileTask == nil else { return }
        reconcileTask = Task { await self.reconcile() }
    }
    private func reconcile() async {
        while true {
            let version = revision
            if let previous = stream {
                stream = nil; output?.invalidate(); output = nil
                do { try await previous.stopCapture() }
                catch { logger.error("停止采集返回错误码 \((error as NSError).code)") }
                logger.info("capture-stop")
            }
            if let (geometry, displayID) = request() {
                diagnostics.update(id, "正在启动本地区域采集…")
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    guard version == revision else { continue }
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard version == revision else { continue }
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw BackdropError.displayUnavailable }
                    let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    guard !own.isEmpty else { throw BackdropError.cannotExcludeSelf }
                    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.sourceRect = geometry.source
                    config.width = Int(geometry.source.width); config.height = Int(geometry.source.height)
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                    config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.colorSpaceName = CGColorSpace.sRGB
                    let receiver = BackdropStreamOutput(deliver: { [weak self] image, report in
                        guard let self, self.revision == version else { return }
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        self.imageLayer.frame = geometry.destination
                        self.imageLayer.contents = image
                        self.fallback.isHidden = true
                        self.firstFrameTimeout?.cancel(); self.firstFrameTimeout = nil
                        CATransaction.commit()
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - self.reportTime > 1 {
                            self.reportTime = now; self.diagnostics.update(self.id, report)
                        }
                    }, failure: { [weak self] reason in
                        guard let self, self.revision == version else { return }
                        self.disabled = true; self.refresh(force: true)
                        self.diagnostics.update(self.id, reason)
                    })
                    let candidate = SCStream(filter: filter, configuration: config, delegate: receiver)
                    try candidate.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
                    try await candidate.startCapture()
                    stream = candidate; output = receiver
                    logger.info("capture-start \(config.width)x\(config.height) maxFPS=10 excludeSelf=true")
                    if version != revision { receiver.invalidate(); continue }
                    firstFrameTimeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard let self, self.revision == version, !self.fallback.isHidden else { return }
                        self.disabled = true; self.refresh(force: true)
                        self.diagnostics.update(self.id, "5 秒内未收到画面；已停止采集，请检查权限后重新开启实验模式")
                    }
                } catch {
                    if version == revision {
                        let detail = (error as? BackdropError)?.description ?? "采集不可用（\((error as NSError).code)）；请授权屏幕录制，再关闭并重新开启实验模式"
                        diagnostics.update(id, detail)
                        logger.error("capture-start-failed code=\((error as NSError).code)")
                    }
                }
            } else if !disabled { diagnostics.update(id, "窗口不可见，采集已停止") }
            if version == revision { break }
        }
        reconcileTask = nil
    }
    func shutdown() {
        disabled = true
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        refresh(force: true)
        diagnostics.remove(id)
    }
}

private enum BackdropError: Error {
    case displayUnavailable, cannotExcludeSelf
    var description: String {
        switch self {
        case .displayUnavailable: "显示器不可用；请移动窗口后重试"
        case .cannotExcludeSelf: "无法排除本程序窗口，已停止采集以避免画面反馈；请重新开启实验模式"
        }
    }
}

struct BackdropStatus: View {
    @ObservedObject var diagnostics: BackdropDiagnostics
    var body: some View {
        Text(diagnostics.summary.isEmpty ? "关闭面板即停止；不保存、不上传" : diagnostics.summary)
            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
    }
}
