import AppKit
import SwiftUI
import Combine

struct StatusReadout {
    @MainActor static func title(_ model: MonitorModel) -> String {
        let cpu = model.snapshot(.cpu), memory = model.snapshot(.memory), network = model.snapshot(.network)
        return "\(cpu.number)\(cpu.value == nil ? "" : "%")  \(memory.number)\(memory.value == nil ? "" : "G")  ↓\(network.value == nil ? "—" : network.reading)"
    }
}
final class DetailWindow: NSWindow {
    private var chrome: WindowChrome?
    func installChrome() {
        guard chrome == nil, let frameView = contentView?.superview else { return }
        let chrome = WindowChrome(frame: frameView.bounds)
        chrome.autoresizingMask = [.width, .height]
        frameView.addSubview(chrome, positioned: .above, relativeTo: nil)
        self.chrome = chrome
        chrome.updateTrackingAreas()
    }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = MonitorModel()
    var status: NSStatusItem!
    var overviewPanel: OverviewPanel!
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    var detailWindow: NSWindow?
    var subscriptions = Set<AnyCancellable>()
    var transitionIDs: [ObjectIdentifier: UUID] = [:]
    var transitionFrames: [ObjectIdentifier: NSRect] = [:]
    var closingWindows = Set<ObjectIdentifier>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        model.start()
        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self
        status.button?.action = #selector(toggleOverview)
        status.button?.font = statusFont
        status.button?.setAccessibilityLabel("性能监控，点击打开概览")
        status.button?.toolTip = "性能监控 · 实时采样"
        overviewPanel = OverviewPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        overviewPanel.isOpaque = false
        overviewPanel.backgroundColor = .clear
        overviewPanel.hasShadow = false
        overviewPanel.hidesOnDeactivate = false
        overviewPanel.level = .statusBar
        overviewPanel.isReleasedWhenClosed = false
        overviewPanel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        overviewPanel.contentViewController = NSHostingController(rootView: Overview(model: model, open: { [weak self] in self?.showDetails($0) }, close: { [weak self] in self?.hideOverview() }, quit: { NSApp.terminate(nil) }))
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.overviewPanel.isVisible, event.window === self.detailWindow { self.hideOverview() }
            return event
        }
        model.$readings.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateStatus() }.store(in: &subscriptions)
        model.$cpuScale.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateStatus() }.store(in: &subscriptions)
        model.$precision.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateStatus() }.store(in: &subscriptions)
        model.$theme.sink { [weak self] theme in
            let appearance = theme == .system ? nil : NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            self?.detailWindow?.appearance = appearance
            self?.detailWindow?.contentViewController?.view.appearance = appearance
            self?.overviewPanel.appearance = appearance
            self?.overviewPanel.contentViewController?.view.appearance = appearance
        }.store(in: &subscriptions)
        DispatchQueue.main.async { [weak self] in self?.showOverview() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }
    func present(_ window: NSWindow, frame: NSRect? = nil) {
        let key = ObjectIdentifier(window)
        let token = UUID()
        let target = frame ?? transitionFrames[key] ?? window.frame
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        transitionIDs[key] = token
        transitionFrames[key] = target
        closingWindows.remove(key)
        window.ignoresMouseEvents = false
        if !window.isVisible { setContentPresented(false, for: window) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.transitionIDs[key] == token else { return }
            self.setContentPresented(true, for: window)
        }
        if !model.reduceTransparency && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            // 避免整窗 alpha/缩放动画把背景合成临时扁平化成灰色底板。
            window.animationBehavior = .none
            window.alphaValue = 1
            window.setFrame(target, display: true)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            transitionFrames.removeValue(forKey: key)
            return
        }
        if !window.isVisible {
            window.alphaValue = reduce ? 1 : 0
            window.setFrame(reduce ? target : target.insetBy(dx: target.width * 0.008, dy: target.height * 0.008), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.18
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.transitionIDs[key] == token else { return }
                self.transitionFrames.removeValue(forKey: key)
            }
        }
    }
    func dismiss(_ window: NSWindow) {
        guard window.isVisible else { return }
        let key = ObjectIdentifier(window)
        let token = UUID()
        let target = transitionFrames[key] ?? window.frame
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        transitionIDs[key] = token
        transitionFrames[key] = target
        closingWindows.insert(key)
        window.ignoresMouseEvents = true
        setContentPresented(false, for: window)
        if !model.reduceTransparency && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : 0.42)) { [weak self] in
                guard let self, self.transitionIDs[key] == token else { return }
                window.orderOut(nil)
                window.setFrame(target, display: false)
                window.alphaValue = 1
                window.ignoresMouseEvents = false
                self.closingWindows.remove(key)
                self.transitionFrames.removeValue(forKey: key)
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.42
            window.animator().alphaValue = 0
            if !reduce { window.animator().setFrame(target.insetBy(dx: target.width * 0.006, dy: target.height * 0.006), display: true) }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.transitionIDs[key] == token else { return }
                window.orderOut(nil)
                window.setFrame(target, display: false)
                window.alphaValue = 1
                window.ignoresMouseEvents = false
                self.closingWindows.remove(key)
                self.transitionFrames.removeValue(forKey: key)
            }
        }
    }
    private func setContentPresented(_ presented: Bool, for window: NSWindow) {
        if window === overviewPanel { model.overviewPresented = presented }
        else { model.detailsPresented = presented }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(sender); return false }
    func updateStatus() {
        status.button?.title = StatusReadout.title(model)
        status.button?.toolTip = "实时采样 · CPU / 内存 / 接收"
    }
    @objc func toggleOverview() { overviewPanel.isVisible && !closingWindows.contains(ObjectIdentifier(overviewPanel)) ? hideOverview() : showOverview() }
    func hideOverview() {
        if let overviewPanel { dismiss(overviewPanel) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
    }
    func showOverview() {
        guard let button = status.button, let statusWindow = button.window,
              let screen = statusWindow.screen, let content = overviewPanel.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let anchorReady = screen.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) && anchor.midY >= visible.maxY
        let origin = NSPoint(x: anchorReady ? min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8) : visible.maxX - size.width - 8,
                             y: max(visible.minY + 8, (anchorReady ? anchor.minY : visible.maxY) - size.height - 6))
        present(overviewPanel, frame: NSRect(origin: origin, size: size))
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self else { return }
                let statusFrame: NSRect?
                if let button = self.status.button, let window = button.window {
                    statusFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
                } else {
                    statusFrame = nil
                }
                guard Self.shouldDismissOverview(at: NSEvent.mouseLocation, panel: self.overviewPanel.frame, status: statusFrame) else { return }
                self.hideOverview()
            }
        }
    }
    static func shouldDismissOverview(at point: NSPoint, panel: NSRect, status: NSRect?) -> Bool {
        !panel.contains(point) && !(status?.contains(point) ?? false)
    }
    @objc func openDetails() { showDetails(model.metric) }
    func showDetails(_ metric: Metric) {
        model.metric = metric
        hideOverview()
        if detailWindow == nil {
            let window = DetailWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.appearance = model.theme == .system ? nil : NSAppearance(named: model.theme == .dark ? .darkAqua : .aqua)
            window.title = "性能监控"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.contentViewController = NSHostingController(rootView: Details(model: model, showOverview: { [weak self] in self?.showOverview() }, close: { [weak self] in self?.detailWindow?.performClose(nil) }))
            window.contentMinSize = NSSize(width: 704, height: 584)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            detailWindow = window
        }
        if let detailWindow { present(detailWindow); (detailWindow as? DetailWindow)?.installChrome() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !overviewPanel.isVisible { showDetails(model.metric) }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let overview = NSMenuItem(title: "显示概览", action: #selector(toggleOverview), keyEquivalent: "o"); overview.target = self; appMenu.addItem(overview)
        let details = NSMenuItem(title: "打开详情", action: #selector(openDetails), keyEquivalent: "1"); details.target = self; appMenu.addItem(details)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出性能监控原型", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = menu
    }
}
@main enum NativeMonitor {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
