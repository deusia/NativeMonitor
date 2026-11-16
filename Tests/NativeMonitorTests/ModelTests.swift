import XCTest
import AppKit
import PrivateBackdrop
import SwiftUI
import Combine
@testable import NativeMonitor
private struct MaterialContentProbe: NSViewRepresentable {
    let created: () -> Void
    func makeNSView(context: Context) -> NSView { created(); return NSView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
private final class DragProbeWindow: NSWindow {
    var dragCount = 0
    override func performDrag(with event: NSEvent) { dragCount += 1 }
}
private func statusValues(_ cpu: String, _ memory: String, _ network: String, _ unit: String) -> [StatusReadoutValue] {
    [StatusReadoutValue(number: cpu, unit: cpu == "—" ? "" : "%"),
     StatusReadoutValue(number: memory, unit: memory == "—" ? "" : "G"),
     StatusReadoutValue(number: network, unit: unit.isEmpty ? "" : " " + unit, prefix: "↓")]
}
final class ModelTests: XCTestCase {
    @MainActor func testInvisibleDragAreaDoesNotExpandHeader() throws {
        let suite = "NativeMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        let host = NSHostingView(rootView: Details(model: model, showOverview: {}, close: {}))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 780)
        host.layoutSubtreeIfNeeded()
        func findDragArea(_ view: NSView) -> WindowDragView? {
            if let area = view as? WindowDragView { return area }
            return view.subviews.lazy.compactMap { findDragArea($0) }.first
        }
        let area = try XCTUnwrap(findDragArea(host))
        XCTAssertGreaterThan(area.frame.width, 200)
        XCTAssertEqual(area.frame.height, 36, accuracy: 1)
    }

    @MainActor func testWindowDragAreaUsesNativeWindowDragging() throws {
        let window = DragProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let area = WindowDragView(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
        window.contentView = area
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 18),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(area.acceptsFirstMouse(for: event))
        area.mouseDown(with: event)
        XCTAssertEqual(window.dragCount, 1)
    }

    @MainActor func testStatusReadoutOnlyReconfiguresLayoutWhenSettingsChange() {
        let readout = StatusReadout(cpuScale: .average, precision: 0)
        XCTAssertFalse(readout.update(statusValues("9", "10", "0", "B/s"), cpuScale: .average, precision: 0))
        XCTAssertTrue(readout.update(statusValues("9.1", "10.1", "1", "B/s"), cpuScale: .average, precision: 1))
        XCTAssertFalse(readout.update(statusValues("99", "20", "999", "MB/s"), cpuScale: .average, precision: 1))
        XCTAssertTrue(readout.update(statusValues("999", "20", "999", "MB/s"), cpuScale: .total, precision: 1))
    }

    @MainActor func testMaterialChangesPreserveContentIdentity() {
        var creations = 0
        func root(_ appearance: AppearanceSettings, reduce: Bool) -> some View {
            MaterialContentProbe(created: { creations += 1 })
                .frame(width: 200, height: 100)
                .modifier(ControlMaterial(reduce: reduce))
                .environment(\.monitorAppearance, appearance)
        }
        var appearance = AppearanceSettings()
        let host = NSHostingView(rootView: root(appearance, reduce: false))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(creations, 1)
        appearance[.controls].blur = 20
        host.rootView = root(appearance, reduce: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(creations, 1)
        host.rootView = root(AppearanceSettings(), reduce: true)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(creations, 1)
    }

    @MainActor func testFocusLossHidesUnpinnedWindowsAndKeepsPinnedWindows() {
        let suite = "NativeMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate(defaults: defaults)
        let panel = OverviewPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        let details = DetailWindow(contentRect: panel.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        delegate.overviewPanel = panel
        delegate.detailWindow = details
        panel.orderFront(nil); details.orderFront(nil)
        defer { panel.orderOut(nil); details.orderOut(nil) }
        XCTAssertFalse(delegate.model.pinWindows)
        delegate.model.pinWindows = true
        XCTAssertTrue(MonitorModel(defaults: defaults).pinWindows)
        let notification = Notification(name: NSApplication.didResignActiveNotification)
        delegate.applicationDidResignActive(notification)
        XCTAssertTrue(panel.isVisible); XCTAssertTrue(details.isVisible)
        XCTAssertTrue(delegate.closingWindows.isEmpty)
        delegate.model.pinWindows = false
        delegate.applicationDidResignActive(notification)
        XCTAssertTrue(delegate.closingWindows.contains(ObjectIdentifier(panel)))
        XCTAssertTrue(delegate.closingWindows.contains(ObjectIdentifier(details)))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.55))
        XCTAssertFalse(panel.isVisible); XCTAssertFalse(details.isVisible)
        XCTAssertFalse(MonitorModel(defaults: defaults).pinWindows)
    }

    @MainActor func testDetailWindowHidesTrafficLightsAndRetainsCloseAction() {
        let window = DetailWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.installChrome()
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(window.standardWindowButton(button)?.isHidden, true)
        }
        window.orderFront(nil)
        window.cancelOperation(nil)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testAppearancePersistsIndependentlyAndResets() {
        let suite = "NativeMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        for region in AppearanceRegion.allCases { XCTAssertEqual(model.appearance[region], SurfaceAppearance()) }
        model.appearance[.overview] = SurfaceAppearance(clarity: 0.8, transparency: 0.4, blur: 12)
        model.appearance[.cards].blur = 25
        let restored = MonitorModel(defaults: defaults)
        XCTAssertEqual(restored.appearance[.overview], model.appearance[.overview])
        XCTAssertEqual(restored.appearance[.cards].blur, 25)
        XCTAssertEqual(restored.appearance[.details], SurfaceAppearance())
        XCTAssertEqual(restored.appearance[.controls], SurfaceAppearance())
        restored.reduceTransparency = true
        XCTAssertEqual(restored.appearance[.overview].blur, 12)
        restored.appearance[.overview] = SurfaceAppearance()
        XCTAssertEqual(restored.appearance[.cards].blur, 25)
        restored.appearance = AppearanceSettings()
        let reset = MonitorModel(defaults: defaults)
        for region in AppearanceRegion.allCases { XCTAssertEqual(reset.appearance[region], SurfaceAppearance()) }
        XCTAssertTrue(reset.reduceTransparency)
    }

    func testAppearanceRejectsInvalidValues() {
        XCTAssertEqual(SurfaceAppearance(clarity: .nan, transparency: .infinity, blur: -.infinity), SurfaceAppearance())
        XCTAssertEqual(SurfaceAppearance(clarity: -1, transparency: 2, blur: 99),
                       SurfaceAppearance(clarity: 0, transparency: 1, blur: 30))
        let suite = "NativeMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-100, forKey: "appearance.overview.blur")
        defaults.set("invalid", forKey: "appearance.cards.transparency")
        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings[.overview].blur, 0)
        XCTAssertEqual(settings[.cards].transparency, 0)
    }

    @MainActor func testBackdropCustomParametersAndPresentation() throws {
        let view = NMPrivateBackdropView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.configure(withBlurRadius: 18, opacity: 0.4, dimming: 2, fadesEdges: false)
        view.layout()
        let layers = try XCTUnwrap(view.layer?.sublayers)
        let blur = try XCTUnwrap(layers.first?.filters?.first as? NSObject)
        XCTAssertEqual(try XCTUnwrap(blur.value(forKey: "inputRadius") as? Double), 18)
        XCTAssertEqual(try XCTUnwrap(layers.last?.backgroundColor).alpha, 0.12, accuracy: 0.001)
        let image = try XCTUnwrap(layers.last?.mask?.contents) as! CGImage
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)).alphaComponent, 1)
        view.setPresented(true, animated: false)
        for layer in layers { XCTAssertEqual(layer.opacity, 0.4, accuracy: 0.001) }
        view.setPresented(false, animated: true)
        view.configure(withBlurRadius: 0, opacity: 0.7, dimming: 0, fadesEdges: true)
        for layer in layers { XCTAssertEqual(layer.opacity, 0) }
        view.setPresented(true, animated: false)
        for layer in layers { XCTAssertEqual(layer.opacity, 0.7, accuracy: 0.001) }
        XCTAssertEqual(try XCTUnwrap(layers.last?.backgroundColor).alpha, 0)
        view.configure(withBlurRadius: .nan, opacity: .infinity, dimming: -.infinity, fadesEdges: true)
        XCTAssertEqual(try XCTUnwrap(blur.value(forKey: "inputRadius") as? Double), 2)
        for layer in layers { XCTAssertEqual(layer.opacity, 1) }
    }

    @MainActor func testMultipleBackdropsRestoreWindowConfigurationAfterLastRemoval() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let oldFlatten = try XCTUnwrap(window.value(forKey: "shouldAutoFlattenLayerTree") as? Bool)
        let oldHosting = try XCTUnwrap(window.value(forKey: "canHostLayersInWindowServer") as? Bool)
        let first = NMPrivateBackdropView(frame: window.contentView!.bounds)
        let second = NMPrivateBackdropView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(first)
        window.contentView!.addSubview(second)
        first.removeFromSuperview()
        XCTAssertEqual(window.value(forKey: "shouldAutoFlattenLayerTree") as? Bool, false)
        XCTAssertEqual(window.value(forKey: "canHostLayersInWindowServer") as? Bool, true)
        second.removeFromSuperview()
        XCTAssertEqual(window.value(forKey: "shouldAutoFlattenLayerTree") as? Bool, oldFlatten)
        XCTAssertEqual(window.value(forKey: "canHostLayersInWindowServer") as? Bool, oldHosting)
    }

    @MainActor func testStatusReadoutKeepsColumnsFixedAcrossDigitAndUnitChanges() throws {
        for scale in CPUScale.allCases {
            for precision in 0...2 {
                let readout = StatusReadout(cpuScale: scale, precision: precision)
                readout.setFrameSize(readout.fittingSize)
                readout.layoutSubtreeIfNeeded()
                let fields = try readout.arrangedSubviews.map { try XCTUnwrap($0 as? StatusReadoutColumn) }
                let frames = fields.map(\.frame)
                let width = readout.fittingSize.width
                let maximumCPU = scale == .average ? 100 : Double(ProcessInfo.processInfo.processorCount * 100)
                let maximumMemory = ValueFormat.memoryGigabytes(ProcessInfo.processInfo.physicalMemory)
                for value in [0.0, 0.001, 9.99, 10, 99.99, 100, 999.999, maximumCPU, maximumMemory] {
                    for rate in [0.0, 0.001, 999.99, 1000, 999_999.999, 1_000_000, 999_999_999.999, 1_000_000_000, 1_000_000_000_000] {
                        let network = ValueFormat.display(rate / 1e6, metric: .network, precision: precision)
                        let values = statusValues(ValueFormat.number(min(value, maximumCPU), precision: precision),
                                                  ValueFormat.number(min(value, maximumMemory), precision: precision), network.0, network.1)
                        readout.update(values, cpuScale: scale, precision: precision)
                        readout.layoutSubtreeIfNeeded()
                        XCTAssertEqual(fields.map(\.frame), frames)
                        XCTAssertEqual(readout.fittingSize.width, width)
                        for (field, value) in zip(fields, values) {
                            XCTAssertEqual(field.stringValue, value.text)
                            XCTAssertEqual(field.unit.alignmentRect(forFrame: field.unit.frame).minX,
                                           field.number.alignmentRect(forFrame: field.number.frame).maxX, accuracy: 1)
                            XCTAssertLessThanOrEqual((value.text as NSString).size(withAttributes: [.font: StatusReadout.font]).width, field.frame.width)
                        }
                    }
                }
                readout.update(statusValues("—", "—", "—", ""), cpuScale: scale, precision: precision)
                readout.layoutSubtreeIfNeeded()
                XCTAssertEqual(fields.map(\.frame), frames)
                XCTAssertEqual(readout.fittingSize.width, width)
                XCTAssertNil(readout.hitTest(.zero))
                XCTAssertTrue(fields[2].arrangedSubviews.first === fields[2].prefix)
            }
        }
    }

    @MainActor func testStatusAnimationKeepsMountedColumnsAndContentStable() throws {
        let readout = StatusReadout(cpuScale: .average, precision: 0)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: readout.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = readout
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        readout.update(statusValues("9", "9", "999", "B/s"), cpuScale: .average, precision: 0)
        readout.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let fields = try readout.arrangedSubviews.map { try XCTUnwrap($0 as? StatusReadoutColumn) }
        let frames = fields.map(\.frame)
        let readings = fields.map { ObjectIdentifier($0) }
        for values in [statusValues("100", "10", "1", "MB/s"), statusValues("1", "9", "999", "KB/s"),
                       statusValues("1", "9", "999", "MB/s"), statusValues("—", "—", "—", "")] {
            let previousNumbers = fields.map { $0.number.stringValue }
            let previousReadings = fields.map(\.stringValue)
            readout.update(values, cpuScale: .average, precision: 0)
            for (index, field) in fields.enumerated() {
                XCTAssertNil(field.unit.layer?.animation(forKey: kCATransition))
                XCTAssertNil(field.prefix.layer?.animation(forKey: kCATransition))
                // 完全相同的读数不触碰现有图层，只有单位切换时才要求清除旧数字过渡。
                if previousReadings[index] == values[index].text { continue }
                if values[index].number == "—" || values[index].number == previousNumbers[index]
                    || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    XCTAssertNil(field.number.layer?.animation(forKey: kCATransition))
                } else {
                    XCTAssertEqual(field.number.layer?.animation(forKey: kCATransition)?.duration, 0.22)
                }
            }
            for _ in 0..<3 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                readout.layoutSubtreeIfNeeded()
                XCTAssertEqual(fields.map(\.frame), frames)
                XCTAssertEqual(fields.map { ObjectIdentifier($0) }, readings)
                XCTAssertEqual(fields.map { $0.stringValue }, values.map(\.text))
            }
        }
    }

    @MainActor func testStatusReadoutUsesCompactWidthsForCurrentSettings() {
        let readout = StatusReadout(cpuScale: .average, precision: 0)
        let compactWidth = readout.fittingSize.width
        readout.update(statusValues("16", "19", "8", "KB/s"), cpuScale: .total, precision: 2)
        XCTAssertGreaterThan(readout.fittingSize.width - compactWidth, 30)
        readout.update(statusValues("16", "19", "8", "KB/s"), cpuScale: .average, precision: 0)
        XCTAssertEqual(readout.fittingSize.width, compactWidth)
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
        XCTAssertEqual(try XCTUnwrap(dimming.backgroundColor).alpha, 0.06, accuracy: 0.001)
        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(try XCTUnwrap(dimming.backgroundColor).alpha, 0.18, accuracy: 0.001)
        view.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(try XCTUnwrap(dimming.backgroundColor).alpha, 0.06, accuracy: 0.001)
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

    @MainActor func testOptimizedBackdropMaskKeepsRoundedGradient() throws {
        for size in [NSSize(width: 320, height: 400), NSSize(width: 100, height: 80)] {
            let view = NMPrivateBackdropView(frame: NSRect(origin: .zero, size: size))
            view.layout()
            let image = try XCTUnwrap(view.layer?.sublayers?.last?.mask?.contents) as! CGImage
            let bitmap = NSBitmapImageRep(cgImage: image)
            for y in stride(from: 0, to: Int(size.height), by: 7) {
                for x in stride(from: 0, to: Int(size.width), by: 7) {
                    let qx = abs(Double(x) + 0.5 - size.width / 2) - size.width / 2 + 64
                    let qy = abs(Double(y) + 0.5 - size.height / 2) - size.height / 2 + 64
                    let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - 64
                    let t = min(1, max(0, -distance / min(160, min(size.width, size.height) / 3)))
                    let expected = (255 * t * t * (3 - 2 * t)).rounded() / 255
                    XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, expected, accuracy: 0.001)
                }
            }
        }
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

    @MainActor func testOverviewPlacementHandlesHiddenMenuBarAndScreenEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let size = NSSize(width: 440, height: 600)
        let centered = AppDelegate.overviewFrame(size: size, anchor: NSRect(x: 650, y: 875, width: 100, height: 25), screen: screen, visible: visible)
        XCTAssertEqual(centered, NSRect(x: 480, y: 269, width: 440, height: 600))
        let left = AppDelegate.overviewFrame(size: size, anchor: NSRect(x: 0, y: 875, width: 40, height: 25), screen: screen, visible: visible)
        XCTAssertEqual(left.minX, 8)
        let right = AppDelegate.overviewFrame(size: size, anchor: NSRect(x: 1400, y: 875, width: 40, height: 25), screen: screen, visible: visible)
        XCTAssertEqual(right.maxX, 1432)
        let hidden = AppDelegate.overviewFrame(size: size, anchor: .zero, screen: screen, visible: visible)
        XCTAssertEqual(hidden, NSRect(x: 992, y: 269, width: 440, height: 600))
        let offscreen = AppDelegate.overviewFrame(size: size, anchor: NSRect(x: 1600, y: 875, width: 40, height: 25), screen: screen, visible: visible)
        XCTAssertEqual(offscreen, hidden)
    }

    @MainActor func testOverviewStaysInPlaceWhenMenuBarMoves() throws {
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
        delegate.model.stop()
        delegate.showOverview()
        let panel = delegate.overviewPanel.frame
        let anchorReady = screen.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) && anchor.midY >= screen.visibleFrame.maxY
        let expectedX = min(max(anchor.midX - panel.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - panel.width - 8)
        XCTAssertEqual(panel.minX, anchorReady ? expectedX : screen.visibleFrame.maxX - panel.width - 8, accuracy: 1)
        XCTAssertEqual(panel.maxY, (anchorReady ? anchor.minY : screen.visibleFrame.maxY) - 6, accuracy: 1)
        button.title += "宽宽"
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: statusWindow)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(delegate.overviewPanel.frame.origin.x, panel.origin.x, accuracy: 1)
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
        XCTAssertEqual(snapshot.maximum(.short), 0.001)
        XCTAssertNil(snapshot.value)
    }
    @MainActor func testPageTransitionCancelsOldTargetAndOnlyReplacesAfterFadeOut() async throws {
        let transition = MetricPageTransition(metric: .cpu)
        let first = Task { await transition.show(.gpu, animated: true) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(transition.metric, .cpu)
        XCTAssertFalse(transition.visible)
        first.cancel()
        let latest = Task { await transition.show(.memory, animated: true) }
        await first.value
        await latest.value
        XCTAssertEqual(transition.metric, .memory)
        XCTAssertTrue(transition.visible)
        await transition.show(.network, animated: false)
        XCTAssertEqual(transition.metric, .network)
        XCTAssertTrue(transition.visible)
    }

    @MainActor func testReturningToCurrentPageCancelsFadeWithoutLeavingItInvisible() async throws {
        let transition = MetricPageTransition(metric: .cpu)
        let outgoing = Task { await transition.show(.gpu, animated: true) }
        try await Task.sleep(for: .milliseconds(20))
        outgoing.cancel()
        await transition.show(.cpu, animated: true)
        await outgoing.value
        XCTAssertEqual(transition.metric, .cpu)
        XCTAssertTrue(transition.visible)
    }

    func testSamplingRequestTimeoutAndStopDoNotQueueOrAcceptLateResults() {
        var request = SamplingRequest()
        XCTAssertTrue(request.begin(at: 100))
        XCTAssertFalse(request.begin(at: 101))
        XCTAssertFalse(request.timedOut(at: 106, after: 6))
        XCTAssertTrue(request.timedOut(at: 107, after: 6))
        XCTAssertFalse(request.timedOut(at: 120, after: 6))
        XCTAssertFalse(request.begin(at: 120))
        XCTAssertFalse(request.finish())
        XCTAssertTrue(request.begin(at: 121))
        XCTAssertTrue(request.finish())
        XCTAssertFalse(request.finish())
        XCTAssertTrue(request.begin(at: 122))
        request.invalidate()
        XCTAssertFalse(request.begin(at: 123))
        XCTAssertFalse(request.finish())
        XCTAssertTrue(request.begin(at: 124))
        XCTAssertTrue(request.finish())
    }

    func testHistoryWindowIncludesBoundariesAndExcludesFutureSamples() {
        let now = Date(timeIntervalSince1970: 100_000)
        let offsets = [-86_401.0, -86_400, -301, -300, -1, 0, 1]
        let history = offsets.map { TimedValue(date: now.addingTimeInterval($0), value: abs($0), series: ["设备": abs($0)]) }
        let current = MetricReading(date: now, value: 0, status: "", facts: [], rows: [])
        let snapshot = Snapshot(metric: .network, current: current, history: history, now: now)
        XCTAssertEqual(snapshot.samples(.short).map(\.value), [300, 1, 0])
        XCTAssertEqual(snapshot.seriesSamples(.short).map(\.value), [300, 1, 0])
        XCTAssertEqual(snapshot.samples(.day).count, 5)
        XCTAssertEqual(snapshot.plotStart(.short), -5)
        XCTAssertEqual(history.lowerBound(now.addingTimeInterval(-300)), 3)
        XCTAssertEqual(history.lowerBound(now, strictlyAfter: true), 6)
        XCTAssertEqual([TimedValue]().lowerBound(now), 0)
        XCTAssertEqual(history.lowerBound(now.addingTimeInterval(2)), history.count)
    }

    @MainActor func testBatchUpdatesPublishOnceAndRetainOnlyOrderedValidHistory() throws {
        let model = MonitorModel()
        let start = Date(timeIntervalSince1970: 100_000)
        var notifications = 0
        let subscription = model.$readings.dropFirst().sink { _ in notifications += 1 }
        defer { subscription.cancel() }
        func reading(_ date: Date, value: Double = 1, series: [String: Double] = [:]) -> MetricReading {
            MetricReading(date: date, value: value, status: "正常", facts: [], rows: [], series: series)
        }
        model.record([.disk: reading(start), .network: reading(start)], at: start)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(model.histories[.disk]?.count, 1)
        let day = start.addingTimeInterval(86_400)
        model.record([.disk: reading(day)], at: day)
        XCTAssertEqual(model.histories[.disk]?.count, 2)
        let later = day.addingTimeInterval(1)
        model.record([.disk: reading(later)], at: later)
        XCTAssertEqual(model.histories[.disk]?.map(\.date), [day, later])
        model.record([.disk: reading(start)], at: start)
        XCTAssertEqual(model.histories[.disk]?.map(\.date), [start])
        let snapshot = model.snapshot(.disk)
        model.record([.network: reading(start.addingTimeInterval(1))], at: start.addingTimeInterval(1))
        XCTAssertTrue(snapshot.hasSameChart(as: model.snapshot(.disk)))
        XCTAssertEqual(model.snapshot(.disk).now, start)
        model.record([.disk: reading(start, value: .nan)], at: start)
        XCTAssertNil(model.readings[.disk]?.value)
        XCTAssertTrue(try XCTUnwrap(model.histories[.disk]).isEmpty)
        model.record([.disk: reading(start, series: ["写入": .infinity])], at: start)
        XCTAssertNil(model.readings[.disk]?.value)
        model.record([.disk: reading(start)], at: start.addingTimeInterval(100))
        XCTAssertNil(model.readings[.disk]?.value)
        model.record([.disk: reading(later)], at: later)
        XCTAssertEqual(model.histories[.disk]?.count, 1)
        XCTAssertEqual(snapshot.history.count, 1)
        XCTAssertFalse(snapshot.hasSameChart(as: model.snapshot(.disk)))
    }

    func testChartReductionPreservesExtremaEndpointsAndOrder() {
        let samples: [Sample] = (0..<1000).map { index in
            let value: Double = index == 337 ? 10_000 : (index == 338 ? -100 : 5)
            return Sample(id: Double(index), minute: Double(index), value: value)
        }
        for limit in [4, 5, 160, 480] {
            let reduced = Sample.reduced(samples, limit: limit)
            XCTAssertLessThanOrEqual(reduced.count, limit)
            XCTAssertEqual(reduced.first, samples.first)
            XCTAssertEqual(reduced.last, samples.last)
            XCTAssertEqual(reduced.map(\.value).max(), 10_000)
            XCTAssertEqual(reduced.map(\.value).min(), -100)
            XCTAssertEqual(reduced.map(\.id), reduced.map(\.id).sorted())
            XCTAssertEqual(Set(reduced.map(\.id)).count, reduced.count)
        }
        XCTAssertEqual(Sample.reduced([], limit: 4), [])
        XCTAssertEqual(Sample.reduced(Array(samples.prefix(3)), limit: 4), Array(samples.prefix(3)))
        let flat = samples.map { Sample(id: $0.id, minute: $0.minute, value: 1) }
        XCTAssertEqual(Sample.reduced(flat, limit: 160).last, flat.last)
    }

    func testFullDayChartsStayBoundedWithoutChangingStatistics() {
        let now = Date(timeIntervalSince1970: 100_000)
        let history = (0...86_400).map { index in
            let value = index == 86_399 ? 10_000.0 : Double(index % 100)
            return TimedValue(date: now.addingTimeInterval(Double(index - 86_400)), value: value,
                              series: ["读取": value, "写入": Double(index % 50)])
        }
        let reading = MetricReading(date: now, value: 0, status: "", facts: [], rows: [])
        let snapshot = Snapshot(metric: .disk, current: reading, history: history, now: now)
        let started = Date()
        for range in HistoryRange.allCases {
            let samples = snapshot.samples(range, limit: 160)
            XCTAssertLessThanOrEqual(samples.count, 160)
            XCTAssertEqual(samples.first?.minute, -Double(range.rawValue))
            XCTAssertEqual(samples.last?.minute, 0)
            XCTAssertEqual(samples.map(\.value).max(), 10_000)
            let points = snapshot.seriesSamples(range, limit: 480)
            for name in ["读取", "写入"] {
                let series = points.filter { $0.name == name }
                XCTAssertLessThanOrEqual(series.count, 480)
                XCTAssertEqual(series.first?.minute, -Double(range.rawValue))
                XCTAssertEqual(series.last?.minute, 0)
            }
            XCTAssertEqual(snapshot.maximum(range), 12_000)
        }
        print("一天历史、五种范围的绘图数据准备耗时：\(Date().timeIntervalSince(started)) 秒")
        let rawValues = snapshot.samples(.long).map(\.value)
        XCTAssertEqual(rawValues.count, 1801)
        let average = rawValues.reduce(0, +) / Double(rawValues.count)
        XCTAssertEqual(snapshot.rows.first { $0.label.contains("均值") }?.value,
                       ValueFormat.reading(average, metric: .disk, precision: 1))
        XCTAssertEqual(snapshot.history.count, 86_401)
    }

    func testReducedSeriesKeepGapsAndLatestAfterManySegments() {
        let now = Date(timeIntervalSince1970: 1000)
        let history: [TimedValue] = (0...100).map { index in
            let series: [String: Double] = index % 2 == 0 ? ["设备": Double(index)] : [:]
            return TimedValue(date: now.addingTimeInterval(Double(index - 100)),
                              value: Double(index), series: series)
        }
        let reading = MetricReading(date: now, value: 100, status: "", facts: [], rows: [])
        let snapshot = Snapshot(metric: .gpu, current: reading, history: history, now: now)
        let points = snapshot.seriesSamples(.short, limit: 4)
        XCTAssertEqual(points.count, 51)
        XCTAssertEqual(Set(points.map(\.segment)).count, 51)
        XCTAssertEqual(points.last?.value, 100)
        XCTAssertEqual(points.map(\.minute), points.map(\.minute).sorted())
        var unavailable = snapshot
        unavailable.current = nil
        XCTAssertTrue(unavailable.seriesSamples(.short, limit: 4).isEmpty)
        XCTAssertTrue(unavailable.samples(.short, limit: 4).isEmpty)
    }

    func testExtendedHistoryRanges() {
        let now = Date(timeIntervalSince1970: 100_000)
        let reading = MetricReading(date: now, value: 1, status: "", facts: [], rows: [])
        let history = [3601.0, 3600, 21600, 86400, 86401].map {
            TimedValue(date: now.addingTimeInterval(-$0), value: $0)
        }.sorted { $0.date < $1.date }
        let snapshot = Snapshot(metric: .network, current: reading, history: history, now: now)
        XCTAssertEqual(snapshot.samples(.hour).count, 1)
        XCTAssertEqual(snapshot.samples(.sixHours).count, 3)
        XCTAssertEqual(snapshot.samples(.day).count, 4)
        XCTAssertEqual(snapshot.maximum(.day), 86400 * 1.2, accuracy: 0.001)
        XCTAssertEqual(HistoryRange.day.label, "24 小时")
    }
    @MainActor func testSettingsPersistAndValidate() {
        let suite = "NativeMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MonitorModel(defaults: defaults)
        first.interval = 5; first.cpuScale = .average; first.precision = 2
        first.theme = .dark; first.reduceTransparency = true; first.range = .day
        let restored = MonitorModel(defaults: defaults)
        XCTAssertEqual(restored.interval, 5); XCTAssertEqual(restored.cpuScale, .average)
        XCTAssertEqual(restored.precision, 2); XCTAssertEqual(restored.theme, .dark)
        XCTAssertTrue(restored.reduceTransparency); XCTAssertEqual(restored.range, .day)
        defaults.set(99, forKey: "samplingInterval"); defaults.set(-1, forKey: "precision")
        XCTAssertEqual(MonitorModel(defaults: defaults).interval, 2)
        XCTAssertEqual(MonitorModel(defaults: defaults).precision, 1)
    }
    func testCPUScaleAndAdaptiveUnits() {
        let date = Date()
        let reading = MetricReading(date: date, value: 150, status: "", facts: [], rows: [], cores: [50, 100], cpuParts: [100, 50, 50])
        let total = Snapshot(metric: .cpu, current: reading, history: [TimedValue(date: date, value: 150)], now: date)
        let average = Snapshot(metric: .cpu, current: reading, history: [TimedValue(date: date, value: 150)], now: date, cpuScale: .average)
        XCTAssertEqual(total.value, 150); XCTAssertEqual(total.maximum(.short), 200)
        let eighteen = MetricReading(date: date, value: 1800, status: "", facts: [], rows: [], cores: Array(repeating: 100, count: 18))
        XCTAssertEqual(Snapshot(metric: .cpu, current: eighteen).maximum(.short), 1800)
        XCTAssertEqual(average.value, 75); XCTAssertEqual(average.maximum(.short), 100)
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
    func testNetworkChartsKeepUploadAndDownloadIndependent() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let history = [
            TimedValue(date: start, value: 1, series: ["接收": 1, "发送": 20]),
            TimedValue(date: start.addingTimeInterval(1), value: 2, series: ["接收": 2]),
            TimedValue(date: start.addingTimeInterval(2), value: 3, series: ["接收": 3, "发送": 40])
        ]
        let current = MetricReading(date: start.addingTimeInterval(2), value: 3, status: "正常", facts: [], rows: [],
                                    series: ["接收": 3, "发送": 40])
        let snapshot = Snapshot(metric: .network, current: current, history: history, now: current.date)
        for limit in [160, 480] {
            let points = snapshot.seriesSamples(.short, limit: limit)
            XCTAssertEqual(points.filter { $0.name == "接收" }.map(\.value), [1, 2, 3])
            let upload = points.filter { $0.name == "发送" }
            XCTAssertEqual(upload.map(\.value), [20, 40])
            XCTAssertEqual(upload.map { $0.plotValue(for: .network) }, [20, 40])
            let download = points.filter { $0.name == "接收" }
            XCTAssertEqual(download.map { $0.plotValue(for: .network) }, [-1, -2, -3])
            XCTAssertEqual(download.map { $0.plotValue(for: .disk) }, [1, 2, 3])
            XCTAssertTrue(chartAxisReading(-20, snapshot: snapshot).hasPrefix("↓ "))
            XCTAssertTrue(chartAxisReading(20, snapshot: snapshot).hasPrefix("↑ "))
            XCTAssertFalse(chartAxisReading(-20, snapshot: snapshot).contains("-"))
            XCTAssertEqual(Set(upload.map(\.segment)).count, 2)
            XCTAssertGreaterThan(snapshot.maximum(.short), 40)
        }
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
