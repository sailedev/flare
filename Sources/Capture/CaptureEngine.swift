import AppKit
import ScreenCaptureKit
import os

private let logger = Logger(subsystem: "com.saile.flare", category: "capture")

@MainActor
final class CaptureEngine {

    // MARK: - Permission

    func requestPermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    // MARK: - Display Detection

    private func findDisplayUnderCursor(
        from displays: [SCDisplay]
    ) -> (screen: NSScreen, display: SCDisplay)? {
        // 1. Find which NSScreen contains the mouse (AppKit-to-AppKit, always correct)
        let mouseLocation = NSEvent.mouseLocation
        guard let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            return nil
        }

        // 2. Get the CGDirectDisplayID for that NSScreen
        guard let screenNumber = mouseScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        // 3. Find the SCDisplay with the matching displayID
        guard let matchedDisplay = displays.first(where: { $0.displayID == screenNumber }) else {
            return nil
        }

        return (mouseScreen, matchedDisplay)
    }

    // MARK: - Full Screen

    func captureFullScreen() async throws -> NSImage {
        guard CGPreflightScreenCaptureAccess() else {
            logger.warning("Screen Recording permission not granted")
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let (mouseScreen, display) = findDisplayUnderCursor(from: content.displays) else {
            logger.error("No display found under cursor")
            throw CaptureError.noDisplay
        }
        logger.info("Full screen capture on display \(display.displayID)")

        let scaleFactor = Int(mouseScreen.backingScaleFactor)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.frame.width) * scaleFactor
        config.height = Int(display.frame.height) * scaleFactor
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Self.ownedImage(cgImage: cgImage, size: NSSize(width: display.frame.width, height: display.frame.height))
    }

    // MARK: - Unified Selection

    func captureUnifiedSelection() async throws -> NSImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier

        // Front-to-back z-order from CGWindowList
        var zOrderMap: [CGWindowID: Int] = [:]
        if let cgWindowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
            for (index, entry) in cgWindowList.enumerated() {
                if let windowNumber = entry[kCGWindowNumber as String] as? CGWindowID {
                    zOrderMap[windowNumber] = index
                }
            }
        }
        logger.debug("Built z-order map with \(zOrderMap.count) entries")

        var displayDataArray: [DisplayData] = []

        for screen in NSScreen.screens {
            // Match NSScreen to SCDisplay via CGDirectDisplayID
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let scDisplay = content.displays.first(where: { $0.displayID == screenNumber }) else {
                continue
            }

            let scaleFactor = screen.backingScaleFactor

            // Capture frozen image for this display
            let freezeFilter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let freezeConfig = SCStreamConfiguration()
            freezeConfig.width = Int(scDisplay.frame.width) * Int(scaleFactor)
            freezeConfig.height = Int(scDisplay.frame.height) * Int(scaleFactor)
            freezeConfig.showsCursor = false

            let frozenImage = try await SCScreenshotManager.captureImage(
                contentFilter: freezeFilter, configuration: freezeConfig
            )

            // Normal (0) and floating (3) windows only, skip system chrome
            let displayFrame = scDisplay.frame
            let displayWindows = content.windows.filter { window in
                guard window.isOnScreen else { return false }
                guard window.frame.width > 1, window.frame.height > 1 else { return false }
                guard window.windowLayer == 0 || window.windowLayer == 3 else { return false }
                if let bundleId = window.owningApplication?.bundleIdentifier,
                   bundleId == ownBundleID { return false }
                return window.frame.intersects(displayFrame)
            }.sorted { a, b in
                // Sort front-to-back using CGWindowList z-order
                (zOrderMap[a.windowID] ?? Int.max) < (zOrderMap[b.windowID] ?? Int.max)
            }
            logger.debug("Display \(screenNumber): \(displayWindows.count) windows (filtered from \(content.windows.count) total)")
            for (i, w) in displayWindows.prefix(10).enumerated() {
                logger.debug("  [\(i)] id=\(w.windowID) layer=\(w.windowLayer) z=\(zOrderMap[w.windowID] ?? -1) '\(w.title ?? "untitled", privacy: .public)' \(w.owningApplication?.applicationName ?? "?", privacy: .public)")
            }

            displayDataArray.append(DisplayData(
                screen: screen,
                displayFrame: scDisplay.frame,
                frozenImage: frozenImage,
                windows: displayWindows,
                scaleFactor: scaleFactor
            ))
        }

        guard !displayDataArray.isEmpty else {
            throw CaptureError.noDisplay
        }

        let result = try await UnifiedSelector.select(displays: displayDataArray)

        switch result {
        case .window(let selectedWindow):
            logger.info("Selected window: id=\(selectedWindow.windowID) layer=\(selectedWindow.windowLayer) '\(selectedWindow.title ?? "untitled", privacy: .public)'")
            // Find the scale factor from the display containing this window
            let windowCenter = CGPoint(
                x: selectedWindow.frame.midX,
                y: selectedWindow.frame.midY
            )
            let scaleFactor = displayDataArray
                .first(where: { $0.displayFrame.contains(windowCenter) })?
                .scaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0)
            let intScale = Int(scaleFactor)

            // Re-fetch shareable content to get a fresh window reference
            let freshContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let freshWindow = freshContent.windows.first { $0.windowID == selectedWindow.windowID }
            guard let windowToCapture = freshWindow else {
                throw CaptureError.noWindow
            }

            let windowFilter = SCContentFilter(desktopIndependentWindow: windowToCapture)
            let windowConfig = SCStreamConfiguration()
            windowConfig.width = Int(windowToCapture.frame.width) * intScale
            windowConfig.height = Int(windowToCapture.frame.height) * intScale
            windowConfig.showsCursor = false
            windowConfig.capturesShadowsOnly = false
            windowConfig.shouldBeOpaque = false

            let windowImage = try await SCScreenshotManager.captureImage(
                contentFilter: windowFilter, configuration: windowConfig
            )
            return Self.ownedImage(
                cgImage: windowImage,
                size: NSSize(width: windowToCapture.frame.width, height: windowToCapture.frame.height)
            )

        case .region(let globalRect):
            logger.info("Selected region: \(Int(globalRect.width))x\(Int(globalRect.height)) at (\(Int(globalRect.origin.x)), \(Int(globalRect.origin.y)))")
            // Region is in global CG coordinates — may span multiple displays
            let stitched = try stitchRegion(globalRect, from: displayDataArray)
            return Self.ownedImage(
                cgImage: stitched,
                size: NSSize(width: globalRect.width, height: globalRect.height)
            )
        }
    }

    // MARK: - Cross-Display Region Stitching

    /// Composites a region from multiple displays' frozen images.
    /// `globalRect` is in global CG coordinates (origin top-left of primary display).
    private func stitchRegion(
        _ globalRect: CGRect,
        from displays: [DisplayData]
    ) throws -> CGImage {
        // Find all displays that intersect the selection
        let intersecting = displays.filter { $0.displayFrame.intersects(globalRect) }
        guard !intersecting.isEmpty else {
            throw CaptureError.cancelled
        }

        // If region is entirely on one display, just crop directly (fast path)
        if intersecting.count == 1 {
            let data = intersecting[0]
            let scale = data.scaleFactor
            // Convert global rect to display-local coordinates
            let localRect = CGRect(
                x: (globalRect.origin.x - data.displayFrame.origin.x) * scale,
                y: (globalRect.origin.y - data.displayFrame.origin.y) * scale,
                width: globalRect.width * scale,
                height: globalRect.height * scale
            )
            guard let cropped = data.frozenImage.cropping(to: localRect) else {
                throw CaptureError.cancelled
            }
            return cropped
        }

        // Multi-display compositing: use the max scale factor for output quality
        let maxScale = intersecting.map { $0.scaleFactor }.max() ?? 2.0
        let outputWidth = Int(globalRect.width * maxScale)
        let outputHeight = Int(globalRect.height * maxScale)

        guard let colorSpace = intersecting.first?.frozenImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw CaptureError.cancelled
        }

        // CGContext origin is bottom-left. Global CG origin is top-left.
        // We need to draw each display's contribution at the correct position.
        for data in intersecting {
            let intersection = globalRect.intersection(data.displayFrame)
            guard !intersection.isEmpty else { continue }

            let displayScale = data.scaleFactor

            // Source rect in the frozen image (pixels)
            let srcX = (intersection.origin.x - data.displayFrame.origin.x) * displayScale
            let srcY = (intersection.origin.y - data.displayFrame.origin.y) * displayScale
            let srcW = intersection.width * displayScale
            let srcH = intersection.height * displayScale
            let srcRect = CGRect(x: srcX, y: srcY, width: srcW, height: srcH)

            guard let cropped = data.frozenImage.cropping(to: srcRect) else { continue }

            // Destination rect in output context (pixels, bottom-left origin)
            // In global CG coords: intersection.origin.x - globalRect.origin.x gives X offset
            // For Y: globalRect is top-left origin, CGContext is bottom-left origin
            let destX = (intersection.origin.x - globalRect.origin.x) * maxScale
            // Flip Y: in global CG, higher Y = lower on screen. In CGContext, higher Y = higher on screen.
            let destY = (globalRect.maxY - intersection.maxY) * maxScale
            let destW = intersection.width * maxScale
            let destH = intersection.height * maxScale
            let destRect = CGRect(x: destX, y: destY, width: destW, height: destH)

            context.draw(cropped, in: destRect)
        }

        guard let result = context.makeImage() else {
            throw CaptureError.cancelled
        }
        return result
    }

    // MARK: - Image Ownership

    // Copy pixel data to break IOSurface ties (avoids autorelease crashes)
    private static func ownedImage(cgImage: CGImage, size: NSSize) -> NSImage {
        let w = cgImage.width
        let h = cgImage.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let copied = (ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h)),
                         ctx.makeImage()).1 else {
            return NSImage(cgImage: cgImage, size: size)
        }
        return NSImage(cgImage: copied, size: size)
    }


}

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case noDisplay
    case cancelled
    case noWindow

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required."
        case .noDisplay: return "No display found."
        case .cancelled: return "Capture was cancelled."
        case .noWindow: return "No window selected."
        }
    }
}
