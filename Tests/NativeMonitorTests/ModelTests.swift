import XCTest
import AppKit
import PrivateBackdrop
import SwiftUI
@testable import NativeMonitor
final class ModelTests: XCTestCase {
    func testChartSampleIdentitySurvivesHistoryPruning() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let first = GPUReading(date: date.addingTimeInterval(-4), driver: "test", utilization: 20, renderer: nil, tiler: nil)
        let second = GPUReading(date: date.addingTimeInterval(-2), driver: "test", utilization: 40, renderer: nil, tiler: nil)
        var snapshot = Snapshot(metric: .gpu, scenario: .normal, gpuReading: second, gpuHistory: [first, second], gpuEnabled: true, now: date)
        let before = try XCTUnwrap(snapshot.samples(.short).last)
        snapshot.gpuHistory = [second]
        let after = try XCTUnwrap(snapshot.samples(.short).last)
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(before.value, after.value)
        XCTAssertEqual(before, after)
        let empty = Snapshot(metric: .gpu, scenario: .empty, gpuReading: second, gpuHistory: [second], gpuEnabled: true, now: date)
        XCTAssertTrue(empty.samples(.short).isEmpty)
    }

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
    func testRealGPUHistoryNeverSynthesizesSamples() throws {
        let now = Date(timeIntervalSince1970: 2000)
        let history = try [(-400.0, 15.0), (-120.0, 20.0), (-2.0, 0.0)].map { offset, value in
            try GPUReading.parse(["Device Utilization %": value], driver: "AGX-test", date: now.addingTimeInterval(offset))
        }
        let snapshot = Snapshot(metric: .gpu, scenario: .normal, gpuReading: history.last, gpuHistory: history, gpuEnabled: true, now: now)
        XCTAssertEqual(snapshot.value, 0)
        XCTAssertEqual(snapshot.samples(.short).map(\.value), [20, 0])
        XCTAssertEqual(snapshot.samples(.long).count, 3)
        XCTAssertEqual(snapshot.plotStart(.short), -2)
        XCTAssertEqual(snapshot.samples(.short).last!.minute, -2.0 / 60, accuracy: 0.0001)
        XCTAssertTrue(snapshot.sourceLabel.contains("实时"))
        var missing = snapshot
        missing.gpuReading = nil
        XCTAssertNil(missing.value)
        XCTAssertTrue(missing.samples(.short).isEmpty)
        let empty = Snapshot(metric: .gpu, scenario: .empty, gpuReading: history.last, gpuHistory: history, gpuEnabled: true, now: now)
        XCTAssertNil(empty.value)
        XCTAssertTrue(empty.samples(.short).isEmpty)
        XCTAssertTrue(empty.facts.allSatisfy { $0.value == "—" || $0.value == "暂无有效样本" })
    }
    func testCompactStatusWidthFitsEveryScenario() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let width = StatusReadout.width(font: font)
        XCTAssertLessThan(width, 200)
        for scenario in Scenario.allCases {
            let title = StatusReadout.title(scenario)
            XCTAssertLessThanOrEqual((title as NSString).size(withAttributes: [.font: font]).width + 12, width)
            XCTAssertFalse(title.contains("CPU"))
            XCTAssertTrue(title.contains("↓"))
            if scenario == .empty { XCTAssertFalse(title.contains("0")) }
        }
        print("菜单栏宽度：\(width) pt（原 266 pt）")
    }
    func testGPUIsUnavailableWithoutInventedHistory() {
        let s = Snapshot(metric: .gpu, scenario: .normal)
        XCTAssertNil(s.value); XCTAssertEqual(s.missingReason, "来源未验证")
        XCTAssertTrue(s.samples(.short).isEmpty)
        XCTAssertTrue(s.note.contains("统一内存"))
    }
    func testDisconnectedAndZeroTrafficDiffer() {
        let offline = Snapshot(metric: .network, scenario: .offline)
        let idle = Snapshot(metric: .network, scenario: .idle)
        XCTAssertNil(offline.value); XCTAssertTrue(offline.samples(.long).isEmpty)
        XCTAssertEqual(idle.value, 0); XCTAssertTrue(idle.samples(.long).allSatisfy { $0.value == 0 })
        XCTAssertEqual(offline.status, "未连接"); XCTAssertEqual(idle.status, "已连接 · 零流量")
    }
    func testEmptyStateNeverLeaksValues() {
        for metric in Metric.allCases {
            let s = Snapshot(metric: metric, scenario: .empty)
            XCTAssertNil(s.value); XCTAssertEqual(s.reading, "—"); XCTAssertTrue(s.rows.isEmpty)
            XCTAssertTrue(s.facts.allSatisfy { $0.value == "—" })
            for range in HistoryRange.allCases { XCTAssertTrue(s.samples(range).isEmpty) }
        }
    }
    func testHistoryBoundsAndCurrentValue() {
        for metric in Metric.allCases where metric != .gpu {
            let s = Snapshot(metric: metric, scenario: .normal)
            for range in HistoryRange.allCases {
                let samples = s.samples(range)
                XCTAssertEqual(samples.count, 18)
                XCTAssertEqual(samples.first?.minute, -Double(range.rawValue))
                XCTAssertEqual(samples.last?.minute, 0)
                XCTAssertEqual(samples.last?.value, s.value)
                XCTAssertTrue(samples.allSatisfy { $0.value.isFinite && $0.value >= 0 && $0.value <= metric.maximum })
                XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0.minute < $1.minute })
            }
            XCTAssertNotEqual(s.samples(.short).map(\.value), s.samples(.long).map(\.value))
        }
    }
    func testDiskCapacitySeparateFromRate() {
        let s = Snapshot(metric: .disk, scenario: .normal)
        XCTAssertEqual(s.reading, "18 MB/s")
        XCTAssertEqual(s.rows.first(where: { $0.label == "可用容量" })?.value, "482 GB")
        XCTAssertEqual(s.facts.first(where: { $0.label == "写入" })?.value, "4.2 MB/s")
    }
}
