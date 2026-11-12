#if os(macOS)
import AppKit
import SwiftUI

/// Observe the window's mouse events without placing a hit-testing layer over its controls.
struct MacSidebarHover: NSViewRepresentable {
    var sidebarOpen: Bool
    var dismissOnExit: Bool
    var sidebarWidth: CGFloat
    var onOpen: () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> SidebarEdgeView {
        let view = SidebarEdgeView()
        view.onOpen = onOpen
        view.onClose = onClose
        view.dismissOnExit = dismissOnExit
        view.sidebarWidth = sidebarWidth
        view.sidebarOpen = sidebarOpen
        return view
    }

    func updateNSView(_ view: SidebarEdgeView, context: Context) {
        view.onOpen = onOpen
        view.onClose = onClose
        view.dismissOnExit = dismissOnExit
        view.sidebarWidth = sidebarWidth
        view.sidebarOpen = sidebarOpen
    }

    static func dismantleNSView(_ view: SidebarEdgeView, coordinator: ()) {
        view.stopTracking()
    }
}

@MainActor
final class SidebarEdgeView: NSView {
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var dismissOnExit = false
    var sidebarWidth: CGFloat = 320
    var sidebarOpen = false {
        didSet { if sidebarOpen { cancelDwell() } }
    }
    private var monitor: Any?
    private var area: NSTrackingArea?
    private var dwell: Timer?
    private var armed = true
    private weak var trackedWindow: NSWindow?
    private var originalMouseMoved = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopTracking()
        guard let window else { return }
        trackedWindow = window
        originalMouseMoved = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            if event.window === self.trackedWindow {
                self.track(self.convert(event.locationInWindow, from: nil))
            } else {
                self.pointerLeft()
            }
            return event // Never consume a click, scroll, or mouse event.
        }
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        track(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        pointerLeft()
    }

    private func pointerLeft() {
        cancelDwell()
        armed = true
        if sidebarOpen && dismissOnExit { onClose() }
    }

    private func atLeftEdge(_ point: NSPoint) -> Bool {
        bounds.width > 0 && bounds.contains(point) && point.x <= bounds.minX + 28
    }

    private func track(_ point: NSPoint) {
        if sidebarOpen {
            cancelDwell()
            if dismissOnExit && (!bounds.contains(point) || point.x > bounds.minX + sidebarWidth) {
                onClose()
            }
            return
        }
        guard atLeftEdge(point) else {
            cancelDwell()
            armed = true
            return
        }
        guard !sidebarOpen, armed, dwell == nil else { return }
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dwell = nil
                guard let window = self.trackedWindow, window.isVisible, !window.isMiniaturized,
                      !self.sidebarOpen, self.atLeftEdge(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
                self.armed = false
                self.onOpen()
            }
        }
        dwell = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelDwell() {
        dwell?.invalidate()
        dwell = nil
    }

    func stopTracking() {
        cancelDwell()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let window = trackedWindow { window.acceptsMouseMovedEvents = originalMouseMoved }
        trackedWindow = nil
        armed = true
    }
}
#endif
