import XCTest
import AppKit
import PrivateBackdrop
import SwiftUI
@testable import NativeMonitor
final class ModelTests: XCTestCase {
    func testResizeHitRegionsAndContentPassThrough() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let cases: [(NSPoint, ResizeEdges)] = [
            (.init(x: 1, y: 1), [.left, .bottom]), (.init(x: 799, y: 1), [.right, .bottom]),
            (.init(x: 1, y: 599), [.left, .top]), (.init(x: 799, y: 599), [.right, .top]),
            (.init(x: 1, y: 300), .left), (.init(x: 799, y: 300), .right),
            (.init(x: 400, y: 1), .bottom), (.init(x: 400, y: 599), .top),
            (.init(x: 400, y: 300), []), (.init(x: -1, y: 0), [])]
        for (point, expected) in cases { XCTAssertEqual(ResizeEdges.at(point, in: bounds), expected) }
    }
    func testResizeClampsAndKeepsOppositeCornerFixed() {
        let start = NSRect(x: 100, y: 200, width: 800, height: 600)
        let edges: ResizeEdges = [.left, .bottom]
        let minimum = NSSize(width: 704, height: 584)
        let maximum = NSSize(width: 1400, height: 1000)
        let small = edges.frame(from: start, delta: NSPoint(x: 900, y: 900), minimum: minimum, maximum: maximum)
        XCTAssertEqual(small.size, minimum)
        XCTAssertEqual(small.maxX, start.maxX); XCTAssertEqual(small.maxY, start.maxY)
        let large = edges.frame(from: start, delta: NSPoint(x: -900, y: -900), minimum: minimum, maximum: maximum)
        XCTAssertEqual(large.size, maximum)
        XCTAssertEqual(large.maxX, start.maxX); XCTAssertEqual(large.maxY, start.maxY)
        let right: ResizeEdges = [.right, .top]
        let grown = right.frame(from: start, delta: NSPoint(x: 50, y: 40), minimum: minimum, maximum: maximum)
        XCTAssertEqual(grown, NSRect(x: 100, y: 200, width: 850, height: 640))
    }

    @MainActor func testBackdropDimmingFadesToTransparentAtPerimeter() throws {
        let view = NMPrivateBackdropView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        view.appearance = NSAppearance(named: .aqua)
        view.layout()
        let dimming = try XCTUnwrap(view.layer?.sublayers?.last)
        XCTAssertEqual(try XCTUnwrap(dimming.backgroundColor).alpha, 0.10, accuracy: 0.001)
        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(try XCTUnwrap(dimming.backgroundColor).alpha, 0.30, accuracy: 0.001)
        view.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(try XCTUnwrap(dimming.backgroundColor).alpha, 0.10, accuracy: 0.001)
        XCTAssertFalse(dimming.isHidden)
        let contents = try XCTUnwrap(dimming.mask?.contents)
        XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)
        let image = contents as! CGImage
        let bitmap = NSBitmapImageRep(cgImage: image)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent
        let edge = try XCTUnwrap(bitmap.colorAt(x: 1, y: 200)).alphaComponent
        let transition = try XCTUnwrap(bitmap.colorAt(x: 40, y: 200)).alphaComponent
        let innerEdge = try XCTUnwrap(bitmap.colorAt(x: 90, y: 200)).alphaComponent
        let center = try XCTUnwrap(bitmap.colorAt(x: 160, y: 200)).alphaComponent
        XCTAssertEqual(corner, 0, accuracy: 0.001)
        XCTAssertLessThan(edge, transition)
        XCTAssertLessThan(transition, center)
        XCTAssertGreaterThan(innerEdge, transition)
        XCTAssertLessThan(innerEdge, center)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 120, y: 200)).alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(center, 1, accuracy: 0.001)
        view.setFrameSize(NSSize(width: 600, height: 600)); view.layout()
        let largeImage = try XCTUnwrap(dimming.mask?.contents) as! CGImage
        let largeBitmap = NSBitmapImageRep(cgImage: largeImage)
        XCTAssertLessThan(try XCTUnwrap(largeBitmap.colorAt(x: 120, y: 300)).alphaComponent, 1)
        XCTAssertEqual(try XCTUnwrap(largeBitmap.colorAt(x: 170, y: 300)).alphaComponent, 1, accuracy: 0.001)
        view.setFrameSize(.zero); view.layout()
        XCTAssertTrue(dimming.isHidden)
    }

    @MainActor func testBackdropPresentationAnimationCanReverse() throws {
        let view = NMPrivateBackdropView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        view.layout()
        let layers = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertEqual(layers.count, 2)
        view.setPresented(false, animated: false)
        XCTAssertTrue(layers.allSatisfy { $0.opacity == 0 && $0.animation(forKey: "presentationOpacity") == nil })
        view.setPresented(true, animated: true)
        XCTAssertTrue(layers.allSatisfy { $0.opacity == 1 && $0.animation(forKey: "presentationOpacity") != nil })
        view.setPresented(false, animated: true)
        XCTAssertTrue(layers.allSatisfy { $0.opacity == 0 && $0.animation(forKey: "presentationOpacity") != nil })
        view.setPresented(true, animated: false)
        XCTAssertTrue(layers.allSatisfy { $0.opacity == 1 && $0.animation(forKey: "presentationOpacity") == nil })
    }

    @MainActor func testPrivateBackdropUsesFilterWithoutHUDFallback() throws {
        let view = NMPrivateBackdropView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        view.layout()
        let layer = try XCTUnwrap(view.layer?.sublayers?.first)
        XCTAssertTrue(NSStringFromClass(type(of: layer)).contains("CABackdropLayer"))
        XCTAssertFalse(layer.isHidden)
        XCTAssertEqual(layer.filters?.count, 1)
        XCTAssertFalse(view.subviews.contains { $0 is NSVisualEffectView })
        view.setFrameSize(NSSize(width: 480, height: 500))
        view.layout()
        XCTAssertEqual(layer.frame.size, NSSize(width: 480, height: 500))
        XCTAssertFalse(layer.isHidden)
        view.setFrameSize(.zero)
        view.layout()
        XCTAssertTrue(layer.isHidden)
    }

    @MainActor func testOverviewOutsideClickExcludesMenuBarButton() {
        let panel = NSRect(x: 100, y: 100, width: 200, height: 300)
        let status = NSRect(x: 180, y: 450, width: 100, height: 24)
        XCTAssertFalse(AppDelegate.shouldDismissOverview(at: NSPoint(x: 200, y: 200), panel: panel, status: status))
        XCTAssertFalse(AppDelegate.shouldDismissOverview(at: NSPoint(x: 200, y: 460), panel: panel, status: status))
        XCTAssertTrue(AppDelegate.shouldDismissOverview(at: NSPoint(x: 400, y: 460), panel: panel, status: status))
        XCTAssertTrue(AppDelegate.shouldDismissOverview(at: NSPoint(x: 400, y: 460), panel: panel, status: nil))
    }

    @MainActor func testOverviewFollowsMenuBarAfterStartup() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            delegate.overviewPanel.orderOut(nil)
            NSStatusBar.system.removeStatusItem(delegate.status)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let button = try XCTUnwrap(delegate.status.button)
        let statusWindow = try XCTUnwrap(button.window)
        let screen = try XCTUnwrap(statusWindow.screen)
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let panel = delegate.overviewPanel.frame
        let expectedX = min(max(anchor.midX - panel.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - panel.width - 8)
        XCTAssertEqual(panel.minX, expectedX, accuracy: 1)
        XCTAssertEqual(panel.maxY, anchor.minY - 6, accuracy: 1)
        delegate.toggleOverview()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.55))
        XCTAssertFalse(delegate.overviewPanel.isVisible)
        delegate.toggleOverview()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.55))
        XCTAssertTrue(delegate.overviewPanel.isVisible)
        delegate.toggleOverview()
        delegate.toggleOverview()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.55))
        XCTAssertTrue(delegate.overviewPanel.isVisible)
    }

    @MainActor func testGlassContentSizingMatchesTransparencyFallback() {
        guard #available(macOS 26.0, *) else { return }
        for reduced in [false, true] {
            let host = NSHostingView(rootView: Text("清晰前景").frame(width: 440, height: 500).modifier(WindowGlass(reduce: reduced)))
            XCTAssertEqual(host.fittingSize.width, 504, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, 564, accuracy: 1)
        }
    }

    func testGPUCounterValidation() throws {
        for value in [NSNumber(value: -1), NSNumber(value: 101), NSNumber(value: Double.nan), NSNumber(value: true)] {
            XCTAssertThrowsError(try GPUReading.parse(["Device Utilization %": value], driver: "AGX-test"))
        }
        XCTAssertThrowsError(try GPUReading.parse([:], driver: "AGX-test"))
        XCTAssertThrowsError(try GPUReading.parse(["Device Utilization %": "50"], driver: "AGX-test"))
        let zero = try GPUReading.parse(["Device Utilization %": 0, "Renderer Utilization %": 20], driver: "AGX-test")
        XCTAssertEqual(zero.utilization, 0)
        XCTAssertEqual(zero.renderer, 20)
        XCTAssertNil(zero.tiler)
    }
    func testRealHistoryIsTimeBoundedAndMissingClearsChart() {
        let now = Date(timeIntervalSince1970: 2000)
        let current = MetricReading(date: now, value: 0, status: "正常", facts: [], rows: [])
        let history = [TimedValue(date: now.addingTimeInterval(-400), value: 15), TimedValue(date: now.addingTimeInterval(-2), value: 0)]
        var snapshot = Snapshot(metric: .network, current: current, history: history, now: now)
        XCTAssertEqual(snapshot.samples(.short).map(\.value), [0])
        XCTAssertEqual(snapshot.samples(.long).count, 2)
        XCTAssertEqual(snapshot.value, 0)
        XCTAssertEqual(snapshot.rows.first(where: { $0.label.contains("均值") })?.value, "7.5 MB/s")
        XCTAssertEqual(snapshot.rows.first(where: { $0.label.contains("峰值") })?.value, "15 MB/s")
        snapshot.current = nil
        XCTAssertTrue(snapshot.samples(.short).isEmpty)
        XCTAssertNil(snapshot.value)
    }
    @MainActor func testSettingsPersistAndValidate() {
        let suite = "NativeMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MonitorModel(defaults: defaults)
        first.interval = 5; first.cpuScale = .average; first.precision = 2
        first.theme = .dark; first.reduceTransparency = true; first.range = .long
        let restored = MonitorModel(defaults: defaults)
        XCTAssertEqual(restored.interval, 5); XCTAssertEqual(restored.cpuScale, .average)
        XCTAssertEqual(restored.precision, 2); XCTAssertEqual(restored.theme, .dark)
        XCTAssertTrue(restored.reduceTransparency); XCTAssertEqual(restored.range, .long)
        defaults.set(99, forKey: "samplingInterval"); defaults.set(-1, forKey: "precision")
        XCTAssertEqual(MonitorModel(defaults: defaults).interval, 2)
        XCTAssertEqual(MonitorModel(defaults: defaults).precision, 1)
    }
    func testCPUScaleAndAdaptiveUnits() {
        let date = Date()
        let reading = MetricReading(date: date, value: 150, status: "", facts: [], rows: [], cores: [50, 100], cpuParts: [100, 50, 50])
        let total = Snapshot(metric: .cpu, current: reading, history: [TimedValue(date: date, value: 150)], now: date)
        let average = Snapshot(metric: .cpu, current: reading, history: [TimedValue(date: date, value: 150)], now: date, cpuScale: .average)
        XCTAssertEqual(total.value, 150); XCTAssertEqual(total.maximum, 200)
        let eighteen = MetricReading(date: date, value: 1800, status: "", facts: [], rows: [], cores: Array(repeating: 100, count: 18))
        XCTAssertEqual(Snapshot(metric: .cpu, current: eighteen).maximum, 1800)
        XCTAssertEqual(average.value, 75); XCTAssertEqual(average.maximum, 100)
        XCTAssertEqual(average.status, "整机平均使用率")
        XCTAssertEqual(average.samples(.short).first?.value, 75)
        XCTAssertEqual(ValueFormat.rate(0.01, precision: 1), "<0.1 B/s")
        XCTAssertEqual(ValueFormat.rate(0, precision: 1), "0 B/s")
        XCTAssertEqual(ValueFormat.rate(250, precision: 1), "250 B/s")
        XCTAssertEqual(ValueFormat.rate(1250, precision: 1), "1.2 KB/s")
        XCTAssertEqual(ValueFormat.rate(1_250_000, precision: 2), "1.25 MB/s")
    }
    func testSeriesGapsAndGPUOptionalMetrics() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let reading = MetricReading(date: start, value: 30, status: "", facts: [], rows: [])
        let history = [TimedValue(date: start, value: 10, series: ["设备": 10, "渲染器": 5]),
                       TimedValue(date: start.addingTimeInterval(1), value: 20, series: ["设备": 20]),
                       TimedValue(date: start.addingTimeInterval(2), value: 30, series: ["设备": 30, "渲染器": 8])]
        let snapshot = Snapshot(metric: .gpu, current: reading, history: history, now: start.addingTimeInterval(2))
        let renderer = snapshot.seriesSamples(.short).filter { $0.name == "渲染器" }
        XCTAssertEqual(renderer.count, 2)
        XCTAssertNotEqual(renderer[0].segment, renderer[1].segment)
        let gpu = try GPUReading.parse(["Device Utilization %": 50, "Alloc system memory": 1024, "In use system memory": true], driver: "AGX")
        XCTAssertEqual(gpu.allocatedMemory, 1024)
        XCTAssertNil(gpu.usedMemory)
    }
    func testGPUCoreCountValidation() {
        let config: [String: Any] = ["num_cores": 40, "num_mgpus": 4, "core_mask_list": [987, 987, 987, 987]]
        XCTAssertEqual(GPUCapabilities.coreCount(from: config), 32)
        XCTAssertEqual(GPUCapabilities.coreCount(from: ["num_cores": 8, "num_mgpus": 1, "core_mask_list": [255]]), 8)
        XCTAssertNil(GPUCapabilities.coreCount(from: ["num_cores": 40]))
        XCTAssertNil(GPUCapabilities.coreCount(from: ["num_cores": 40, "num_mgpus": 2, "core_mask_list": [255]]))
        XCTAssertNil(GPUCapabilities.coreCount(from: ["num_cores": 4, "num_mgpus": 1, "core_mask_list": [255]]))
        for value: Any in [true, -1, 1.5, Double.nan, "255"] {
            XCTAssertNil(GPUCapabilities.coreCount(from: ["num_cores": 40, "num_mgpus": 1, "core_mask_list": [value]]))
        }
        XCTAssertNil(GPUCapabilities.coreCount(from: ["num_cores": 40, "num_mgpus": 1, "core_mask_list": [0]]))
    }
    func testMemoryTrendScalesEachSeriesAndHandlesFlatValues() {
        let high = MemoryTrendScale.domain([14.8, 15.0])
        let low = MemoryTrendScale.domain([0.92, 1.03])
        XCTAssertLessThan(high.lowerBound, 14.8); XCTAssertGreaterThan(high.upperBound, 15.0)
        XCTAssertLessThan(low.lowerBound, 0.92); XCTAssertGreaterThan(low.upperBound, 1.03)
        XCTAssertLessThan(low.upperBound - low.lowerBound, 1)
        let flat = MemoryTrendScale.domain([1, 1])
        XCTAssertLessThan(flat.lowerBound, 1); XCTAssertGreaterThan(flat.upperBound, 1)
        XCTAssertEqual(MemoryTrendScale.domain([0, 0]).lowerBound, 0)
        XCTAssertEqual(MemoryTrendScale.domain([.nan]), 0...0.01)
    }
}
