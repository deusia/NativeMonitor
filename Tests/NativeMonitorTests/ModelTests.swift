import XCTest
import AppKit
import PrivateBackdrop
import SwiftUI
import CoreImage.CIFilterBuiltins
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
        view.layout()
        let dimming = try XCTUnwrap(view.layer?.sublayers?.last)
        XCTAssertEqual(try XCTUnwrap(dimming.backgroundColor).alpha, 0.10, accuracy: 0.001)
        XCTAssertFalse(dimming.isHidden)
        let contents = try XCTUnwrap(dimming.mask?.contents)
        XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)
        let image = contents as! CGImage
        let bitmap = NSBitmapImageRep(cgImage: image)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent
        let edge = try XCTUnwrap(bitmap.colorAt(x: 1, y: 200)).alphaComponent
        let transition = try XCTUnwrap(bitmap.colorAt(x: 40, y: 200)).alphaComponent
        let center = try XCTUnwrap(bitmap.colorAt(x: 160, y: 200)).alphaComponent
        XCTAssertEqual(corner, 0, accuracy: 0.001)
        XCTAssertLessThan(edge, transition)
        XCTAssertLessThan(transition, center)
        XCTAssertEqual(center, 1, accuracy: 0.001)
        view.setFrameSize(.zero); view.layout()
        XCTAssertTrue(dimming.isHidden)
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

    func testBackdropScreenCoordinatesAndBounds() throws {
        let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let view = CGRect(x: -1300, y: 350, width: 400, height: 300)
        let geometry = try XCTUnwrap(BackdropGeometry.make(view: view, screen: screen))
        XCTAssertEqual(geometry.source, CGRect(x: 140, y: 450, width: 400, height: 300))
        XCTAssertEqual(geometry.destination, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertNil(BackdropGeometry.make(view: CGRect(x: -1500, y: 350, width: 400, height: 300), screen: screen))
        XCTAssertNil(BackdropGeometry.make(view: .zero, screen: screen))
        XCTAssertNil(BackdropGeometry.make(view: CGRect(x: Double.nan, y: 0, width: 20, height: 20), screen: screen))
    }
    func testBackdropFractionalCoordinatesAlignWithoutStretch() throws {
        let geometry = try XCTUnwrap(BackdropGeometry.make(view: CGRect(x: 40.25, y: 80.75, width: 400.5, height: 300.5), screen: CGRect(x: 0, y: 0, width: 1440, height: 900)))
        XCTAssertEqual(geometry.source, CGRect(x: 40, y: 518, width: 401, height: 302))
        XCTAssertEqual(geometry.destination.origin.x, -0.25)
        XCTAssertEqual(geometry.destination.origin.y, -0.75)
    }
    func testVariableBlurMaskAndTransparentExterior() throws {
        XCTAssertNil(BackdropRenderer.mask(width: 0, height: 20, feather: 10))
        XCTAssertNil(BackdropRenderer.mask(width: 10, height: 20, feather: .nan))
        let mask = try XCTUnwrap(BackdropRenderer.mask(width: 240, height: 240, feather: 80))
        let context = CIContext()
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.createCGImage(mask, from: mask.extent)))
        let edge = try XCTUnwrap(bitmap.colorAt(x: 1, y: 120)).redComponent
        let middle = try XCTUnwrap(bitmap.colorAt(x: 40, y: 120)).redComponent
        let center = try XCTUnwrap(bitmap.colorAt(x: 120, y: 120)).redComponent
        XCTAssertLessThan(edge, middle); XCTAssertLessThan(middle, center)
        XCTAssertGreaterThan(center, 0.99)
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 240, height: 240))
        let result = NSBitmapImageRep(cgImage: try XCTUnwrap(BackdropRenderer().render(input)))
        XCTAssertLessThan(try XCTUnwrap(result.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(result.colorAt(x: 120, y: 120)).alphaComponent, 0.99)
    }

    @MainActor func testGlassContentSizingMatchesTransparencyFallback() {
        guard #available(macOS 26.0, *) else { return }
        for reduced in [false, true] {
            let host = NSHostingView(rootView: Text("清晰前景").frame(width: 440, height: 500).modifier(WindowGlass(reduce: reduced)))
            XCTAssertEqual(host.fittingSize.width, 504, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, 564, accuracy: 1)
        }
    }

    func testBackdropMaskFadesOnlyAtEdges() throws {
        let image = WindowMaterial.edgeMask()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let y = bitmap.pixelsHigh / 2
        func alpha(_ fraction: Double) throws -> CGFloat {
            try XCTUnwrap(bitmap.colorAt(x: Int(Double(bitmap.pixelsWide - 1) * fraction), y: y)).alphaComponent
        }
        XCTAssertLessThan(try alpha(0), 0.05)
        XCTAssertGreaterThan(try alpha(0.5), 0.95)
        XCTAssertLessThan(try alpha(0.15), try alpha(0.3))
        XCTAssertEqual(try alpha(0.15), try alpha(0.85), accuracy: 0.08)
        XCTAssertEqual(image.capInsets.left, 32)
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
