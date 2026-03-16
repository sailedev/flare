import AppKit
import ScreenCaptureKit

/// Result of a unified selection: either a window or a region rect.
enum UnifiedSelectionResult {
    case window(SCWindow)
    case region(CGRect) // Global CG coordinates (origin top-left of primary display)
}

/// Data for one display in a multi-monitor setup.
struct DisplayData {
    let screen: NSScreen
    let displayFrame: CGRect   // CG coordinates (origin top-left of primary display)
    let frozenImage: CGImage
    let windows: [SCWindow]
    let scaleFactor: CGFloat
}

// MARK: - Selection Coordinator

@MainActor
final class SelectionCoordinator {
    private(set) var displays: [DisplayData]
    let windowOnly: Bool
    private let completion: (UnifiedSelectionResult?) -> Void

    var overlayWindows: [UnifiedOverlayWindow] = []
    var overlayViews: [UnifiedOverlayView] = []
    var notificationTokens: [Any] = []

    var dragStartGlobal: CGPoint?
    var dragCurrentGlobal: CGPoint?
    var isDragging = false
    var hoveredWindow: SCWindow?
    private var hasCompleted = false

    let primaryHeight: CGFloat
    let dragThreshold: CGFloat = 4.0

    // Overlay appearance (snapshotted from UserDefaults at capture time)
    let dimOpacity: CGFloat
    let highlightColor: NSColor
    let highlightOpacity: CGFloat

    init(displays: [DisplayData], windowOnly: Bool, completion: @escaping (UnifiedSelectionResult?) -> Void) {
        self.displays = displays
        self.windowOnly = windowOnly
        self.completion = completion
        self.primaryHeight = NSScreen.screens.first?.frame.height ?? 900

        let defaults = UserDefaults.standard
        self.dimOpacity = CGFloat(defaults.object(forKey: "overlayDimOpacity") != nil
            ? defaults.double(forKey: "overlayDimOpacity") : 35.0) / 100.0
        self.highlightOpacity = CGFloat(defaults.object(forKey: "overlayHighlightOpacity") != nil
            ? defaults.double(forKey: "overlayHighlightOpacity") : 22.0) / 100.0
        if let colorData = defaults.data(forKey: "overlayHighlightColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            self.highlightColor = color
        } else {
            self.highlightColor = .systemBlue
        }
    }

    /// Convert AppKit screen coordinates (origin bottom-left of primary) to global CG coordinates (origin top-left of primary).
    func appKitToGlobalCG(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The current selection rectangle in global CG coordinates.
    func globalSelectionRect() -> CGRect? {
        guard isDragging, let start = dragStartGlobal, let current = dragCurrentGlobal else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    /// Trigger redraw on all overlay views (needed for cross-monitor selection).
    func setNeedsDisplayAll() {
        for view in overlayViews {
            view.needsDisplay = true
        }
    }

    /// Complete the selection and close all overlays.
    func finish(_ result: UnifiedSelectionResult?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        for window in overlayWindows {
            window.contentView = nil
            window.orderOut(nil)
        }
        completion(result)
        overlayViews.removeAll()
        overlayWindows.removeAll()
        displays.removeAll()
    }
}

@MainActor
final class UnifiedSelector {

    static func select(
        displays: [DisplayData],
        windowOnly: Bool = false
    ) async throws -> UnifiedSelectionResult {
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false

            let coordinator = SelectionCoordinator(displays: displays, windowOnly: windowOnly) { result in
                guard !hasResumed else { return }
                hasResumed = true
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: CaptureError.cancelled)
                }
            }

            // Create one overlay window per display
            for (index, data) in displays.enumerated() {
                let overlay = UnifiedOverlayWindow(
                    screen: data.screen,
                    coordinator: coordinator
                )
                let view = UnifiedOverlayView(
                    frame: NSRect(origin: .zero, size: data.screen.frame.size),
                    displayIndex: index,
                    coordinator: coordinator
                )
                overlay.contentView = view
                coordinator.overlayWindows.append(overlay)
                coordinator.overlayViews.append(view)
            }

            NSApp.activate(ignoringOtherApps: true)

            for (i, overlay) in coordinator.overlayWindows.enumerated() {
                let token = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: overlay,
                    queue: .main
                ) { [weak coordinator] _ in
                    Task { @MainActor in coordinator?.finish(nil) }
                }
                coordinator.notificationTokens.append(token)

                if i == 0 {
                    overlay.makeKeyAndOrderFront(nil)
                } else {
                    overlay.orderFront(nil)
                }
            }

            // Immediately highlight the window under the cursor so there's
            // no dim flash before the first mouseMoved fires.
            let cursorGlobal = coordinator.appKitToGlobalCG(NSEvent.mouseLocation)
            for display in displays {
                if let window = display.windows.first(where: { $0.frame.contains(cursorGlobal) }) {
                    coordinator.hoveredWindow = window
                    coordinator.setNeedsDisplayAll()
                    break
                }
            }
        }
    }
}

// MARK: - Overlay Window

final class UnifiedOverlayWindow: NSWindow {
    let coordinator: SelectionCoordinator

    init(screen: NSScreen, coordinator: SelectionCoordinator) {
        self.coordinator = coordinator
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false
        self.level = .screenSaver
        self.isOpaque = true
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            coordinator.finish(nil)
        }
    }
}

// MARK: - Overlay View

final class UnifiedOverlayView: NSView {
    let displayIndex: Int
    let coordinator: SelectionCoordinator

    private var display: DisplayData? {
        displayIndex < coordinator.displays.count ? coordinator.displays[displayIndex] : nil
    }

    init(frame: NSRect, displayIndex: Int, coordinator: SelectionCoordinator) {
        self.displayIndex = displayIndex
        self.coordinator = coordinator
        super.init(frame: frame)

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        // Safety net: if drag state is stuck (mouseUp was swallowed by system gesture),
        // reset it when the mouse button is no longer pressed.
        if coordinator.isDragging && NSEvent.pressedMouseButtons & 1 == 0 {
            coordinator.isDragging = false
            coordinator.dragStartGlobal = nil
            coordinator.dragCurrentGlobal = nil
        }
        guard !coordinator.isDragging, let display else { return }
        let global = coordinator.appKitToGlobalCG(NSEvent.mouseLocation)
        coordinator.hoveredWindow = display.windows.first { $0.frame.contains(global) }
        coordinator.setNeedsDisplayAll()
    }

    override func mouseDown(with event: NSEvent) {
        let global = coordinator.appKitToGlobalCG(NSEvent.mouseLocation)
        coordinator.dragStartGlobal = global
        coordinator.dragCurrentGlobal = global
        coordinator.isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard coordinator.dragStartGlobal != nil else { return }
        // Use NSEvent.mouseLocation for global position (works even when cursor is on another monitor)
        let global = coordinator.appKitToGlobalCG(NSEvent.mouseLocation)
        coordinator.dragCurrentGlobal = global

        if let start = coordinator.dragStartGlobal {
            let distance = hypot(global.x - start.x, global.y - start.y)
            if distance > coordinator.dragThreshold && !coordinator.windowOnly {
                coordinator.isDragging = true
                coordinator.hoveredWindow = nil
            }
        }

        coordinator.setNeedsDisplayAll()
    }

    override func mouseUp(with event: NSEvent) {
        let global = coordinator.appKitToGlobalCG(NSEvent.mouseLocation)

        if coordinator.isDragging, let start = coordinator.dragStartGlobal {
            let rect = CGRect(
                x: min(start.x, global.x),
                y: min(start.y, global.y),
                width: abs(global.x - start.x),
                height: abs(global.y - start.y)
            )
            guard rect.width > 5, rect.height > 5 else {
                // Too small, treat as miss — reset state
                coordinator.isDragging = false
                coordinator.dragStartGlobal = nil
                coordinator.dragCurrentGlobal = nil
                coordinator.setNeedsDisplayAll()
                return
            }
            coordinator.finish(.region(rect))
        } else if let window = coordinator.hoveredWindow {
            coordinator.finish(.window(window))
        } else {
            // Clicked on empty area — just reset
        }

        coordinator.isDragging = false
        coordinator.dragStartGlobal = nil
        coordinator.dragCurrentGlobal = nil
    }

    // MARK: - Coordinate Conversion

    private func globalCGRectToView(_ cgRect: CGRect) -> NSRect {
        guard let display else { return .zero }
        return NSRect(
            x: cgRect.origin.x - display.displayFrame.origin.x,
            y: cgRect.origin.y - display.displayFrame.origin.y,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    /// Convert SCWindow frame (global CG coordinates) to this view's coordinate system.
    private func windowFrameToView(_ windowFrame: CGRect) -> NSRect {
        globalCGRectToView(windowFrame)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let display else { return }

        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(display.frozenImage, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()

        NSColor.black.withAlphaComponent(coordinator.dimOpacity).setFill()
        bounds.fill()

        // 3. Window highlight (if hovering, not dragging)
        if !coordinator.isDragging, let hovered = coordinator.hoveredWindow {
            let viewRect = windowFrameToView(hovered.frame)
            if viewRect.intersects(bounds) {
                drawWindowHighlight(hovered, viewRect: viewRect)
            }
        }

        // 4. Selection rectangle (may span multiple monitors)
        if coordinator.isDragging, let globalRect = coordinator.globalSelectionRect() {
            let viewRect = globalCGRectToView(globalRect)
            let visible = viewRect.intersection(bounds)
            if !visible.isEmpty {
                drawSelectionRect(viewRect: viewRect, globalRect: globalRect)
            }
        }
    }

    /// Redraws the frozen image in a specific region, "punching through" the dim overlay.
    private func punchThroughDim(viewRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let display else { return }
        let clampedRect = viewRect.intersection(bounds)
        guard !clampedRect.isEmpty else { return }

        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let cgRect = CGRect(
            x: clampedRect.origin.x,
            y: bounds.height - clampedRect.origin.y - clampedRect.height,
            width: clampedRect.width,
            height: clampedRect.height
        )
        context.clip(to: cgRect)
        context.draw(display.frozenImage, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    /// Builds a path covering only the visible portion of a window (full frame minus
    /// areas covered by windows in front). Uses even-odd winding to subtract overlaps.
    private func visiblePath(for viewRect: NSRect, window: SCWindow) -> NSBezierPath {
        guard let display else { return NSBezierPath(rect: viewRect) }
        let path = NSBezierPath(rect: viewRect)
        path.windingRule = .evenOdd

        guard let hoveredIndex = display.windows.firstIndex(where: { $0.windowID == window.windowID }) else {
            return path
        }
        for i in 0..<hoveredIndex {
            let frontRect = windowFrameToView(display.windows[i].frame)
            let overlap = frontRect.intersection(viewRect)
            if !overlap.isEmpty {
                path.append(NSBezierPath(rect: overlap))
            }
        }
        return path
    }

    private func drawWindowHighlight(_ window: SCWindow, viewRect: NSRect) {
        let visPath = visiblePath(for: viewRect, window: window)
        guard let context = NSGraphicsContext.current?.cgContext, let display else { return }
        let clampedRect = viewRect.intersection(bounds)
        guard !clampedRect.isEmpty else { return }

        // Punch through dim only for the visible portion
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        var flippedTransform = AffineTransform(translationByX: 0, byY: bounds.height)
        flippedTransform.scale(x: 1, y: -1)
        guard let flippedPath = visPath.copy() as? NSBezierPath else { return }
        flippedPath.transform(using: flippedTransform)
        flippedPath.addClip()
        context.draw(display.frozenImage, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()

        // Tint only the visible portion
        context.saveGState()
        visPath.addClip()
        coordinator.highlightColor.withAlphaComponent(coordinator.highlightOpacity).setFill()
        visPath.fill()
        context.restoreGState()

        // Border covers the full window frame (no clip)
        coordinator.highlightColor.setStroke()
        let borderPath = NSBezierPath(roundedRect: viewRect, xRadius: 6, yRadius: 6)
        borderPath.lineWidth = 1.5
        borderPath.stroke()

        if let title = window.title, !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .backgroundColor: NSColor.black.withAlphaComponent(0.7),
            ]
            let string = NSAttributedString(string: " \(title) ", attributes: attrs)
            let labelPoint = NSPoint(
                x: viewRect.midX - string.size().width / 2,
                y: viewRect.maxY + 6
            )
            string.draw(at: labelPoint)
        }
    }

    private func drawSelectionRect(viewRect: NSRect, globalRect: CGRect) {
        // Punch through the dim for the visible portion on this display
        punchThroughDim(viewRect: viewRect)

        // Draw selection border (lines that extend past bounds are clipped automatically)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: viewRect)
        path.lineWidth = 1.5
        path.stroke()

        // Dimensions label — only show on the display containing the bottom-right corner
        let bottomRight = CGPoint(x: globalRect.maxX, y: globalRect.maxY)
        if let display, display.displayFrame.contains(bottomRight) {
            let dims = "\(Int(globalRect.width)) x \(Int(globalRect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .backgroundColor: NSColor.black.withAlphaComponent(0.7),
            ]
            let string = NSAttributedString(string: " \(dims) ", attributes: attrs)
            let labelPoint = NSPoint(
                x: viewRect.midX - string.size().width / 2,
                y: min(viewRect.maxY + 6, bounds.height - 20)
            )
            if labelPoint.x > 0 {
                string.draw(at: labelPoint)
            }
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
