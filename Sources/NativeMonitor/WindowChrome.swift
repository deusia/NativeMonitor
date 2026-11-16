import AppKit
import SwiftUI

struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let bottom = Self(rawValue: 4)
    static let top = Self(rawValue: 8)

    static func at(_ point: NSPoint, in bounds: NSRect) -> Self {
        guard bounds.contains(point) else { return [] }
        var edges: Self = []
        if point.x < bounds.minX + 10 { edges.insert(.left) }
        if point.x > bounds.maxX - 10 { edges.insert(.right) }
        if point.y < bounds.minY + 10 { edges.insert(.bottom) }
        if point.y > bounds.maxY - 10 { edges.insert(.top) }
        return edges
    }
    func frame(from start: NSRect, delta: NSPoint, minimum: NSSize, maximum: NSSize) -> NSRect {
        var result = start
        if contains(.left) || contains(.right) {
            result.size.width = min(maximum.width, max(minimum.width, start.width + (contains(.left) ? -delta.x : delta.x)))
            if contains(.left) { result.origin.x = start.maxX - result.width }
        }
        if contains(.bottom) || contains(.top) {
            result.size.height = min(maximum.height, max(minimum.height, start.height + (contains(.bottom) ? -delta.y : delta.y)))
            if contains(.bottom) { result.origin.y = start.maxY - result.height }
        }
        return result
    }
}

/// 只接管窗口边缘，内容、工具栏与系统窗口按钮保持原有事件处理。
final class WindowChrome: NSView {
    private var area: NSTrackingArea?
    private var edges: ResizeEdges = []
    override var acceptsFirstResponder: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); self.area = area
        updateHover()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return ResizeEdges.at(local, in: bounds).isEmpty ? nil : self
    }
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) {
        edges = []; needsDisplay = true
        NSCursor.arrow.set()
    }
    private func updateHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let wasResizing = !edges.isEmpty
        let updatedEdges = ResizeEdges.at(point, in: bounds)
        if updatedEdges != edges { needsDisplay = true }
        edges = updatedEdges
        if wasResizing && edges.isEmpty { NSCursor.arrow.set() }
        if #available(macOS 15.0, *), !edges.isEmpty {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case [.left, .top]: position = .topLeft
            case [.right, .top]: position = .topRight
            case [.left, .bottom]: position = .bottomLeft
            case [.right, .bottom]: position = .bottomRight
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            default: position = .bottom
            }
            NSCursor.frameResize(position: position, directions: .all).set()
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !edges.isEmpty else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.25).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12)
        path.lineWidth = 1; path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let edges = ResizeEdges.at(convert(event.locationInWindow, from: nil), in: bounds)
        guard !edges.isEmpty else { return }
        let start = window.frame
        let mouse = NSEvent.mouseLocation
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            let frame = edges.frame(from: start, delta: NSPoint(x: current.x - mouse.x, y: current.y - mouse.y), minimum: minimum, maximum: window.maxSize)
            window.setFrame(frame, display: true)
        }
        updateHover()
    }
}

// 让明确标出的顶部区域使用系统拖窗行为，不干扰按钮、图表与滚动操作。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
