import AppKit
import SwiftUI
import Vision

@MainActor
final class EditorViewModel: ObservableObject {
    let originalScreenshot: NSImage
    let settingsStore: SettingsStore
    let outputEngine: OutputEngine
    let historyStore: HistoryStore
    let ocrEngine: OCREngine

    @Published var beautificationSettings: BeautificationSettings {
        didSet { renderPreview() }
    }
    @Published var annotations: [AnnotationItem] = []
    @Published var activeTool: AnnotationTool = .select
    @Published var annotationStyle: AnnotationStyle = AnnotationStyle()
    var nextCalloutNumber: Int = 1
    @Published var selectedAnnotationIndex: Int?

    /// True while the user is typing into a text annotation input field.
    @Published var isEditingText: Bool = false

    /// The SwiftUI canvas (ZStack) size, reported by AnnotationCanvasView.
    /// Used to map annotation coordinates to image pixels for export.
    var canvasSize: CGSize = .zero

    // Undo/redo
    @Published var undoStack: [[AnnotationItem]] = []
    @Published var redoStack: [[AnnotationItem]] = []

    // OCR
    @Published var ocrObservations: [VNRecognizedTextObservation] = []
    @Published var selectedOCRText: String = ""
    @Published var sensitiveRegions: [SensitiveRegion] = []
    @Published var showSensitiveWarning = false

    // Export
    @Published var estimatedFileSize: String = ""

    var onDismiss: (() -> Void)?

    init(originalScreenshot: NSImage,
         settingsStore: SettingsStore,
         outputEngine: OutputEngine,
         historyStore: HistoryStore,
         ocrEngine: OCREngine,
         initialSettings: BeautificationSettings? = nil) {
        self.originalScreenshot = originalScreenshot
        self.settingsStore = settingsStore
        self.outputEngine = outputEngine
        self.historyStore = historyStore
        self.ocrEngine = ocrEngine
        let settings = initialSettings ?? settingsStore.defaultBeautificationSettings()
        self.beautificationSettings = settings
        self.cachedPreview = BeautificationEngine.render(screenshot: originalScreenshot, settings: settings)

        Task {
            await runOCR()
        }
    }

    // MARK: - Rendered Preview

    @Published private(set) var cachedPreview: NSImage

    var renderedPreview: NSImage { cachedPreview }

    private func renderPreview() {
        cachedPreview = BeautificationEngine.render(screenshot: originalScreenshot, settings: beautificationSettings)
    }

    // MARK: - Annotation Actions

    private static let maxUndoDepth = 50

    func pushUndoState() {
        undoStack.append(annotations)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedAnnotationIndex = nil
        recalculateCalloutNumber()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedAnnotationIndex = nil
        recalculateCalloutNumber()
    }

    private func recalculateCalloutNumber() {
        let maxNumber = annotations.compactMap { item -> Int? in
            if case .callout(_, let number, _) = item { return number }
            return nil
        }.max() ?? 0
        nextCalloutNumber = maxNumber + 1
    }

    // MARK: - Selection & Manipulation

    func hitTest(at point: CGPoint) -> Int? {
        for i in annotations.indices.reversed() {
            if annotations[i].boundingRect.insetBy(dx: -6, dy: -6).contains(point) {
                return i
            }
        }
        return nil
    }

    func moveAnnotation(at index: Int, by delta: CGSize) {
        guard annotations.indices.contains(index) else { return }
        annotations[index] = annotations[index].translated(by: delta)
    }

    func resizeAnnotation(at index: Int, to newRect: CGRect) {
        guard annotations.indices.contains(index) else { return }
        annotations[index] = annotations[index].resized(to: newRect)
    }

    func moveArrowEndpoint(at index: Int, isStart: Bool, to point: CGPoint) {
        guard annotations.indices.contains(index) else { return }
        if isStart {
            annotations[index] = annotations[index].withArrowStart(point)
        } else {
            annotations[index] = annotations[index].withArrowEnd(point)
        }
    }

    func deleteSelectedAnnotation() {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        pushUndoState()
        annotations.remove(at: index)
        selectedAnnotationIndex = nil
    }

    // MARK: - Output Actions

    func copyToClipboard() {
        let final = composeFinalImage()
        outputEngine.copyToClipboard(final)
        outputEngine.autoSaveIfEnabled(final)
        outputEngine.showCaptureNotification()
        historyStore.save(image: final, captureMode: "editor", appName: "")
        onDismiss?()
    }

    func saveAs() {
        let final = composeFinalImage()
        outputEngine.saveAs(final, format: settingsStore.defaultFormat, quality: settingsStore.jpgQuality)
        historyStore.save(image: final, captureMode: "editor", appName: "")
    }

    func save() {
        let final = composeFinalImage()
        outputEngine.saveToDefaultFolder(final, format: settingsStore.defaultFormat, quality: settingsStore.jpgQuality)
        outputEngine.copyToClipboard(final)
        outputEngine.showCaptureNotification()
        historyStore.save(image: final, captureMode: "editor", appName: "")
        onDismiss?()
    }

    func discard() {
        onDismiss?()
    }

    // MARK: - Compose Final Image

    private func composeFinalImage() -> NSImage {
        let beautified = cachedPreview

        guard !annotations.isEmpty else { return beautified }

        guard let cgBeautified = beautified.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return beautified }

        let pixelW = CGFloat(cgBeautified.width)
        let pixelH = CGFloat(cgBeautified.height)

        guard let context = CGContext(
            data: nil,
            width: Int(pixelW),
            height: Int(pixelH),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cgBeautified.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return beautified }

        // Draw beautified image (CGContext origin is bottom-left)
        context.draw(cgBeautified, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        // Flip to SwiftUI coords (Y=0 at top)
        context.translateBy(x: 0, y: pixelH)
        context.scaleBy(x: 1, y: -1)

        // Map annotation coordinates from SwiftUI canvas space → image pixel space.
        // The image is displayed with .padding(20) + .aspectRatio(contentMode: .fit)
        // inside the canvas ZStack. We need to undo that offset and scale.
        if canvasSize.width > 0, canvasSize.height > 0 {
            let padding = EditorView.imagePadding
            let availW = canvasSize.width - padding * 2
            let availH = canvasSize.height - padding * 2
            guard availW > 0, availH > 0 else { return beautified }

            let imageAspect = pixelW / pixelH
            let areaAspect = availW / availH

            let displayedW: CGFloat
            let displayedH: CGFloat
            if imageAspect > areaAspect {
                displayedW = availW
                displayedH = availW / imageAspect
            } else {
                displayedH = availH
                displayedW = availH * imageAspect
            }

            let letterboxX = (availW - displayedW) / 2
            let letterboxY = (availH - displayedH) / 2
            let imageOriginX = padding + letterboxX
            let imageOriginY = padding + letterboxY

            let scale = pixelW / displayedW

            // Transform: first translate so image origin maps to (0,0),
            // then scale from view points to image pixels
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -imageOriginX, y: -imageOriginY)
        }

        for annotation in annotations {
            if case .blur(let viewRect) = annotation {
                // Handle blur annotations with actual pixelation using the pixel-space transform
                drawPixelatedBlur(
                    in: context, viewRect: viewRect,
                    sourceImage: cgBeautified, pixelW: pixelW, pixelH: pixelH
                )
            } else {
                annotation.draw(in: context, canvasSize: CGSize(width: pixelW, height: pixelH))
            }
        }

        guard let finalImage = context.makeImage() else { return beautified }
        return NSImage(cgImage: finalImage, size: beautified.size)
    }

    // MARK: - Pixelated Blur for Export

    /// Draws a pixelated blur region into the export CGContext.
    /// `viewRect` is in SwiftUI canvas coordinates; the context's CTM maps it to pixels.
    private func drawPixelatedBlur(
        in context: CGContext, viewRect: CGRect,
        sourceImage: CGImage, pixelW: CGFloat, pixelH: CGFloat
    ) {
        // Use the context's current CTM to map viewRect to pixel space
        let ctm = context.ctm
        let pixelRect = viewRect.applying(ctm).integral

        // Clamp to image bounds (in pixel space, Y=0 at bottom for CGImage)
        let imageBounds = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        let clampedPixelRect = pixelRect.intersection(imageBounds)
        guard !clampedPixelRect.isNull, clampedPixelRect.width > 0, clampedPixelRect.height > 0 else { return }

        guard let cropped = sourceImage.cropping(to: clampedPixelRect) else { return }

        let blockSize: CGFloat = 12
        let maxDim = max(clampedPixelRect.width, clampedPixelRect.height)
        let scaleDown = blockSize / maxDim
        let smallW = max(1, Int(CGFloat(cropped.width) * scaleDown))
        let smallH = max(1, Int(CGFloat(cropped.height) * scaleDown))

        guard let smallCtx = CGContext(
            data: nil, width: smallW, height: smallH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: sourceImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        smallCtx.interpolationQuality = .none
        smallCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))

        guard let pixelated = smallCtx.makeImage() else { return }

        // Draw the pixelated image back. We need to draw in the view coordinate system
        // since the context CTM is set up for that.
        context.saveGState()
        context.interpolationQuality = .none
        // context.draw draws in the current coordinate system (view coords)
        // but CGContext.draw expects unflipped coordinates. Since the context is flipped,
        // we need to use the viewRect directly.
        context.draw(pixelated, in: viewRect)
        context.restoreGState()
    }

    // MARK: - Pixelation for Blur Preview

    /// Creates a pixelated version of the region under `canvasRect` from the beautified preview.
    /// Returns an NSImage that can be drawn at the canvas rect position.
    func pixelatedRegion(for canvasRect: CGRect) -> NSImage? {
        guard let cgBeautified = cachedPreview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixelW = CGFloat(cgBeautified.width)
        let pixelH = CGFloat(cgBeautified.height)
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let padding = EditorView.imagePadding
        let availW = canvasSize.width - padding * 2
        let availH = canvasSize.height - padding * 2
        guard availW > 0, availH > 0 else { return nil }

        let imageAspect = pixelW / pixelH
        let areaAspect = availW / availH
        let displayedW: CGFloat
        let displayedH: CGFloat
        if imageAspect > areaAspect {
            displayedW = availW
            displayedH = availW / imageAspect
        } else {
            displayedH = availH
            displayedW = availH * imageAspect
        }

        let letterboxX = (availW - displayedW) / 2
        let letterboxY = (availH - displayedH) / 2
        let imageOriginX = padding + letterboxX
        let imageOriginY = padding + letterboxY
        let scale = pixelW / displayedW

        // Map canvas rect to image pixel rect
        let pixelRect = CGRect(
            x: (canvasRect.origin.x - imageOriginX) * scale,
            y: (canvasRect.origin.y - imageOriginY) * scale,
            width: canvasRect.width * scale,
            height: canvasRect.height * scale
        ).integral

        // Clamp to image bounds
        let clampedRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        guard !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0 else { return nil }

        // CGImage crop rect: Y is from bottom
        let cropRect = CGRect(
            x: clampedRect.origin.x,
            y: pixelH - clampedRect.origin.y - clampedRect.height,
            width: clampedRect.width,
            height: clampedRect.height
        ).integral

        guard cropRect.width > 0, cropRect.height > 0,
              let cropped = cgBeautified.cropping(to: cropRect) else { return nil }

        let blockSize: CGFloat = 12
        let maxDim = max(clampedRect.width, clampedRect.height)
        let scaleDown = blockSize / maxDim
        let smallW = max(1, Int(CGFloat(cropped.width) * scaleDown))
        let smallH = max(1, Int(CGFloat(cropped.height) * scaleDown))

        guard let smallCtx = CGContext(
            data: nil, width: smallW, height: smallH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cgBeautified.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        smallCtx.interpolationQuality = .none
        smallCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))

        guard let pixelated = smallCtx.makeImage() else { return nil }
        return NSImage(cgImage: pixelated, size: NSSize(width: canvasRect.width, height: canvasRect.height))
    }

    // MARK: - OCR

    private func runOCR() async {
        guard let cgImage = originalScreenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let observations = await ocrEngine.recognizeText(in: cgImage)
        ocrObservations = observations

        // Scan for sensitive content
        let sensitive = ocrEngine.detectSensitiveContent(in: observations)
        if !sensitive.isEmpty {
            sensitiveRegions = sensitive
            showSensitiveWarning = true
        }
    }

    func redactAllSensitive() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }

        let layout = BeautificationEngine.contentLayout(
            for: originalScreenshot,
            settings: beautificationSettings
        )

        let padding = EditorView.imagePadding
        let availW = canvasSize.width - padding * 2
        let availH = canvasSize.height - padding * 2
        guard availW > 0, availH > 0 else { return }

        let pixelW = layout.canvasSize.width
        let pixelH = layout.canvasSize.height
        let imageAspect = pixelW / pixelH
        let areaAspect = availW / availH

        let displayedW: CGFloat, displayedH: CGFloat
        if imageAspect > areaAspect {
            displayedW = availW
            displayedH = availW / imageAspect
        } else {
            displayedH = availH
            displayedW = availH * imageAspect
        }

        let letterboxX = (availW - displayedW) / 2
        let letterboxY = (availH - displayedH) / 2
        let imageOriginX = padding + letterboxX
        let imageOriginY = padding + letterboxY

        // Map content layout to displayed area
        let scaleToView = displayedW / pixelW
        let contentOriginX = imageOriginX + layout.contentRect.origin.x * scaleToView
        let contentOriginY = imageOriginY + layout.contentRect.origin.y * scaleToView
        let contentW = layout.contentRect.width * scaleToView
        let contentH = layout.contentRect.height * scaleToView

        pushUndoState()
        for region in sensitiveRegions {
            // Vision bounding boxes: normalized 0-1, origin at bottom-left
            let bbox = region.rect
            let canvasRect = CGRect(
                x: contentOriginX + bbox.origin.x * contentW,
                y: contentOriginY + (1 - bbox.origin.y - bbox.height) * contentH,
                width: bbox.width * contentW,
                height: bbox.height * contentH
            )
            annotations.append(.blur(rect: canvasRect))
        }
        showSensitiveWarning = false
    }

    // MARK: - File Size Estimation

    func updateEstimatedFileSize() {
        Task.detached(priority: .low) { [weak self] in
            guard let self else { return }
            let image = await self.composeFinalImage()
            let format = await self.settingsStore.defaultFormat
            let quality = await self.settingsStore.jpgQuality

            guard let cgImage = OutputEngine.cgImage(from: image) else { return }

            let data: Data?
            switch format {
            case .png:
                data = OutputEngine.encode(cgImage: cgImage, typeIdentifier: "public.png")
            case .jpg:
                data = OutputEngine.encode(cgImage: cgImage, typeIdentifier: "public.jpeg", quality: quality)
            case .webp:
                data = OutputEngine.encode(cgImage: cgImage, typeIdentifier: "public.webp", quality: quality)
                    ?? OutputEngine.encode(cgImage: cgImage, typeIdentifier: "public.png")
            }

            if let data {
                let bytes = data.count
                let formatted: String
                if bytes > 1_000_000 {
                    formatted = String(format: "%.1f MB", Double(bytes) / 1_000_000)
                } else if bytes > 1000 {
                    formatted = String(format: "%d KB", bytes / 1000)
                } else {
                    formatted = "\(bytes) B"
                }
                await MainActor.run {
                    self.estimatedFileSize = formatted
                }
            }
        }
    }
}
