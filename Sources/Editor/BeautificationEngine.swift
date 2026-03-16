import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Direction the shadow falls (opposite of light source).
enum ShadowDirection: String, CaseIterable, Identifiable, Codable {
    case bottom = "Bottom"
    case bottomRight = "Bottom Right"
    case bottomLeft = "Bottom Left"
    case right = "Right"
    case left = "Left"
    case center = "Center"

    var id: String { rawValue }

    /// Returns a unit offset (dx, dy) in CG coordinates (y-up).
    var offset: CGSize {
        switch self {
        case .bottom:      return CGSize(width: 0, height: -1)
        case .bottomRight:  return CGSize(width: 1, height: -1)
        case .bottomLeft:   return CGSize(width: -1, height: -1)
        case .right:        return CGSize(width: 1, height: 0)
        case .left:         return CGSize(width: -1, height: 0)
        case .center:       return CGSize(width: 0, height: 0)
        }
    }
}

struct BeautificationSettings {
    var padding: CGFloat = 40
    var backgroundType: SettingsStore.BackgroundType = .gradient
    var gradientIndex: Int = 0
    var solidColor: NSColor = .white
    var shadowIntensity: CGFloat = 50
    var shadowDirection: ShadowDirection = .bottomRight
    var cornerRadius: CGFloat = 10
    var inset: CGFloat = 0
    var autoBalance: Bool = false

    var isCustomGradient: Bool = false
    var customGradientStart: NSColor = NSColor(red: 0.5, green: 0.0, blue: 1.0, alpha: 1)
    var customGradientEnd: NSColor = NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1)

    var exportScale: Double = 1.0
    var exportPreset: ExportPreset = .original

    /// When true, padding/cornerRadius/inset are percentages of the image's shorter dimension.
    var usePercentage: Bool = true

    var shadowEnabled: Bool { shadowIntensity > 0 }
}

enum ExportPreset: String, CaseIterable, Identifiable {
    case original = "Original"
    case square1x1 = "1:1"
    case widescreen16x9 = "16:9"
    case twitterX = "Twitter/X"
    case linkedin = "LinkedIn"

    var id: String { rawValue }

    /// Returns target aspect ratio (width/height), or nil for original.
    var aspectRatio: CGFloat? {
        switch self {
        case .original: return nil
        case .square1x1: return 1.0
        case .widescreen16x9: return 16.0 / 9.0
        case .twitterX: return 16.0 / 9.0 // 1200x675 recommended
        case .linkedin: return 1.91 // 1200x627 recommended
        }
    }
}

struct GradientPreset {
    let name: String
    let startColor: NSColor
    let endColor: NSColor

    static let presets: [GradientPreset] = [
        GradientPreset(name: "Ocean", startColor: NSColor(red: 0.16, green: 0.50, blue: 0.73, alpha: 1), endColor: NSColor(red: 0.38, green: 0.76, blue: 0.89, alpha: 1)),
        GradientPreset(name: "Sunset", startColor: NSColor(red: 0.95, green: 0.44, blue: 0.32, alpha: 1), endColor: NSColor(red: 0.97, green: 0.73, blue: 0.38, alpha: 1)),
        GradientPreset(name: "Twilight", startColor: NSColor(red: 0.53, green: 0.30, blue: 0.76, alpha: 1), endColor: NSColor(red: 0.84, green: 0.44, blue: 0.66, alpha: 1)),
        GradientPreset(name: "Forest", startColor: NSColor(red: 0.15, green: 0.60, blue: 0.45, alpha: 1), endColor: NSColor(red: 0.42, green: 0.80, blue: 0.55, alpha: 1)),
        GradientPreset(name: "Midnight", startColor: NSColor(red: 0.12, green: 0.12, blue: 0.27, alpha: 1), endColor: NSColor(red: 0.27, green: 0.27, blue: 0.52, alpha: 1)),
        GradientPreset(name: "Rose", startColor: NSColor(red: 0.93, green: 0.42, blue: 0.55, alpha: 1), endColor: NSColor(red: 0.97, green: 0.67, blue: 0.60, alpha: 1)),
        GradientPreset(name: "Sky", startColor: NSColor(red: 0.40, green: 0.73, blue: 0.96, alpha: 1), endColor: NSColor(red: 0.62, green: 0.90, blue: 0.98, alpha: 1)),
        GradientPreset(name: "Ember", startColor: NSColor(red: 0.98, green: 0.35, blue: 0.13, alpha: 1), endColor: NSColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1)),
        GradientPreset(name: "Charcoal", startColor: NSColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1), endColor: NSColor(red: 0.40, green: 0.40, blue: 0.42, alpha: 1)),
        GradientPreset(name: "Mint", startColor: NSColor(red: 0.24, green: 0.87, blue: 0.75, alpha: 1), endColor: NSColor(red: 0.53, green: 0.95, blue: 0.85, alpha: 1)),
    ]
}

enum BeautificationEngine {

    /// Maps the original image rect into the beautified canvas (pixel coordinates).
    static func contentLayout(for screenshot: NSImage, settings: BeautificationSettings) -> (contentRect: CGRect, canvasSize: CGSize) {
        guard let rawImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            let s = screenshot.size
            return (CGRect(origin: .zero, size: s), s)
        }

        let origW = CGFloat(rawImage.width)
        let origH = CGFloat(rawImage.height)
        let scale = screenshot.size.width > 0 ? origW / screenshot.size.width : 1

        var cropX: CGFloat = 0
        var cropY: CGFloat = 0
        var balancedW = origW
        var balancedH = origH
        if settings.autoBalance, let cropRect = balanceCropRect(of: rawImage) {
            cropX = cropRect.origin.x
            cropY = cropRect.origin.y
            balancedW = cropRect.width
            balancedH = cropRect.height
        }

        let refDim = CGFloat(min(balancedW, balancedH))
        let insetPx: CGFloat
        let padding: CGFloat
        if settings.usePercentage {
            insetPx = settings.inset > 0 ? settings.inset / 100.0 * refDim : 0
            padding = settings.padding / 100.0 * refDim
        } else {
            insetPx = settings.inset > 0 ? settings.inset * scale : 0
            padding = settings.padding * scale
        }
        let processedWidth = balancedW + insetPx * 2
        let processedHeight = balancedH + insetPx * 2
        var canvasWidth = processedWidth + padding * 2
        var canvasHeight = processedHeight + padding * 2

        if let ratio = settings.exportPreset.aspectRatio {
            let currentRatio = canvasWidth / canvasHeight
            if currentRatio < ratio {
                canvasWidth = canvasHeight * ratio
            } else {
                canvasHeight = canvasWidth / ratio
            }
        }

        let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

        let processedX = (canvasWidth - processedWidth) / 2
        let processedY = (canvasHeight - processedHeight) / 2

        // Origin of original in canvas = (processedX + insetPx - cropX, processedY + insetPx - cropY)
        let ocrRect = CGRect(
            x: processedX + insetPx - cropX,
            y: processedY + insetPx - cropY,
            width: origW,
            height: origH
        )

        return (ocrRect, canvasSize)
    }

    /// Renders a beautified screenshot: balance → inset → background + shadow + rounded corners + padding.
    static func render(screenshot: NSImage, settings: BeautificationSettings) -> NSImage {
        guard let rawImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return screenshot
        }

        // Step 0: Auto-balance (crop excess background to center content)
        let balanced: CGImage
        if settings.autoBalance {
            balanced = balanceContent(of: rawImage)
        } else {
            balanced = rawImage
        }

        // Compute pixel values from settings (handles both px and % modes)
        let scale = screenshot.size.width > 0 ? CGFloat(rawImage.width) / screenshot.size.width : 1
        let refDim = CGFloat(min(balanced.width, balanced.height))

        let insetPx: CGFloat
        let paddingPx: CGFloat
        let cornerRadiusPx: CGFloat

        if settings.usePercentage {
            insetPx = settings.inset / 100.0 * refDim
            paddingPx = settings.padding / 100.0 * refDim
            cornerRadiusPx = settings.cornerRadius / 100.0 * refDim
        } else {
            insetPx = settings.inset * scale
            paddingPx = settings.padding * scale
            cornerRadiusPx = settings.cornerRadius * scale
        }

        let cgImage: CGImage
        if insetPx > 0 {
            cgImage = extendEdges(of: balanced, by: insetPx)
        } else {
            cgImage = balanced
        }

        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)
        let padding = paddingPx

        // Determine canvas size (accounting for export preset)
        var canvasWidth = imgWidth + padding * 2
        var canvasHeight = imgHeight + padding * 2

        if let ratio = settings.exportPreset.aspectRatio {
            let currentRatio = canvasWidth / canvasHeight
            if currentRatio < ratio {
                canvasWidth = canvasHeight * ratio
            } else {
                canvasHeight = canvasWidth / ratio
            }
        }

        let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return screenshot
        }

        let fullRect = CGRect(origin: .zero, size: canvasSize)

        // 1. Draw background
        drawBackground(in: context, rect: fullRect, settings: settings)

        // Center the screenshot on the canvas
        let imgRect = CGRect(
            x: (canvasSize.width - imgWidth) / 2,
            y: (canvasSize.height - imgHeight) / 2,
            width: imgWidth,
            height: imgHeight
        )

        let cr = cornerRadiusPx

        // 2. Draw screenshot (with shadow if enabled).
        //    Shadow is generated from the drawn content's alpha, so it follows
        //    the rounded rect for normal screenshots and the subject outline
        //    for background-removed images.
        context.saveGState()
        if settings.shadowEnabled {
            let t = settings.shadowIntensity / 100.0
            let shadowScale = settings.usePercentage ? refDim / 1000.0 : 1.0
            let blur = (8.0 + t * 32.0) * shadowScale
            let opacity = min(t * 1.2, 1.0)
            let dist = (4.0 + t * 16.0) * shadowScale
            let dir = settings.shadowDirection.offset
            let offset = CGSize(width: dir.width * dist, height: dir.height * dist)
            context.setShadow(
                offset: offset,
                blur: blur,
                color: NSColor.black.withAlphaComponent(opacity).cgColor
            )
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let clipPath = CGPath(roundedRect: imgRect, cornerWidth: cr, cornerHeight: cr, transform: nil)
        context.addPath(clipPath)
        context.clip()
        context.draw(cgImage, in: imgRect)
        context.endTransparencyLayer()
        context.restoreGState()

        guard let finalImage = context.makeImage() else { return screenshot }

        // Apply export scale
        let outputSize: NSSize
        if settings.exportScale != 1.0 {
            outputSize = NSSize(
                width: canvasSize.width * settings.exportScale,
                height: canvasSize.height * settings.exportScale
            )
        } else {
            outputSize = NSSize(width: canvasSize.width, height: canvasSize.height)
        }

        return NSImage(cgImage: finalImage, size: outputSize)
    }

    /// Computes the crop rect that balanceContent would apply.
    /// Returns nil if no crop is needed (no significant imbalance).
    private static func balanceCropRect(of image: CGImage) -> CGRect? {
        let w = image.width
        let h = image.height
        guard w > 2, h > 2 else { return nil }

        let minMargin = 4

        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * h)

        guard let ctx = CGContext(
            data: &pixelData,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let off = y * bytesPerRow + x * bytesPerPixel
            return (pixelData[off], pixelData[off + 1], pixelData[off + 2])
        }

        let corners = [pixel(0, 0), pixel(w - 1, 0), pixel(0, h - 1), pixel(w - 1, h - 1)]
        let bgR = Int(corners.map { Int($0.0) }.reduce(0, +)) / 4
        let bgG = Int(corners.map { Int($0.1) }.reduce(0, +)) / 4
        let bgB = Int(corners.map { Int($0.2) }.reduce(0, +)) / 4

        let threshold = 26

        func isContent(_ x: Int, _ y: Int) -> Bool {
            let off = y * bytesPerRow + x * bytesPerPixel
            let dr = abs(Int(pixelData[off]) - bgR)
            let dg = abs(Int(pixelData[off + 1]) - bgG)
            let db = abs(Int(pixelData[off + 2]) - bgB)
            return dr + dg + db > threshold
        }

        var topMargin = 0
        topScan: for y in 0..<h {
            for x in 0..<w { if isContent(x, y) { break topScan } }
            topMargin += 1
        }

        var bottomMargin = 0
        bottomScan: for y in stride(from: h - 1, through: 0, by: -1) {
            for x in 0..<w { if isContent(x, y) { break bottomScan } }
            bottomMargin += 1
        }

        var leftMargin = 0
        leftScan: for x in 0..<w {
            for y in 0..<h { if isContent(x, y) { break leftScan } }
            leftMargin += 1
        }

        var rightMargin = 0
        rightScan: for x in stride(from: w - 1, through: 0, by: -1) {
            for y in 0..<h { if isContent(x, y) { break rightScan } }
            rightMargin += 1
        }

        guard topMargin + bottomMargin < h, leftMargin + rightMargin < w else { return nil }

        let equalH = max(min(leftMargin, rightMargin), minMargin)
        let equalV = max(min(topMargin, bottomMargin), minMargin)

        let hDiff = abs(leftMargin - rightMargin)
        let vDiff = abs(topMargin - bottomMargin)
        guard hDiff > 4 || vDiff > 4 else { return nil }

        let contentWidth = w - leftMargin - rightMargin
        let contentHeight = h - topMargin - bottomMargin
        let cropX = leftMargin - equalH
        // CGContext y=0 is bottom; CGImage.cropping y=0 is top.
        // bottomMargin (scanned from high y in context) = visual top margin.
        let cropY = bottomMargin - equalV
        let cropW = contentWidth + equalH * 2
        let cropH = contentHeight + equalV * 2

        let finalX = max(0, cropX)
        let finalY = max(0, cropY)
        let finalW = max(1, min(cropW, w - finalX))
        let finalH = max(1, min(cropH, h - finalY))

        return CGRect(x: finalX, y: finalY, width: finalW, height: finalH)
    }

    private static func balanceContent(of image: CGImage) -> CGImage {
        guard let cropRect = balanceCropRect(of: image) else { return image }
        return image.cropping(to: cropRect) ?? image
    }

    // MARK: - Background Removal

    enum BackgroundRemovalError: Error, LocalizedError {
        case noSubjectFound
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .noSubjectFound: return "No subject detected in the image."
            case .renderFailed: return "Failed to render the result."
            }
        }
    }

    /// Removes the background from an image using Vision's subject isolation.
    /// Returns a CGImage with transparent background where the background was.
    static func removeBackground(from image: CGImage) async throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        try await Task.detached(priority: .userInitiated) {
            try handler.perform([request])
        }.value

        guard let observation = request.results?.first else {
            throw BackgroundRemovalError.noSubjectFound
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )

        let ciImage = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)

        let filter = CIFilter.blendWithMask()
        filter.inputImage = ciImage
        filter.maskImage = maskImage
        filter.backgroundImage = CIImage.empty()

        guard let output = filter.outputImage else {
            throw BackgroundRemovalError.renderFailed
        }

        let context = CIContext()
        guard let result = context.createCGImage(output, from: output.extent) else {
            throw BackgroundRemovalError.renderFailed
        }

        return result
    }

    // MARK: - Edge Extension

    private static func extendEdges(of image: CGImage, by insetPx: CGFloat) -> CGImage {
        let origW = image.width
        let origH = image.height
        let inset = Int(round(insetPx))
        guard inset > 0 else { return image }

        let newW = origW + inset * 2
        let newH = origH + inset * 2

        // Use the image's color space but normalize to a known-good bitmap format.
        // Source images may have non-standard bitmapInfo (16-bit, float) that CGContext
        // doesn't support for all operations.
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let safeBitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let edgeColor = averageEdgeColor(of: image, colorSpace: colorSpace, bitmapInfo: safeBitmapInfo)

        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: safeBitmapInfo
        ) else { return image }

        // Fill entire canvas with the edge color
        ctx.setFillColor(edgeColor)
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))

        // Draw the original image centered
        ctx.draw(image, in: CGRect(x: inset, y: inset, width: origW, height: origH))

        return ctx.makeImage() ?? image
    }

    /// Samples the 1px border strip of a CGImage and returns the average color
    /// in the image's native color space.
    private static func averageEdgeColor(of image: CGImage, colorSpace: CGColorSpace, bitmapInfo: UInt32) -> CGColor {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return NSColor.white.cgColor }

        // Force RGBA byte order for sampling so offset+0=R, +1=G, +2=B, +3=A
        // regardless of the source image's native pixel format (often BGRA).
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * h)

        guard let ctx = CGContext(
            data: &pixelData,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSColor.white.cgColor }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var totalR: Double = 0, totalG: Double = 0, totalB: Double = 0, totalA: Double = 0
        var count: Double = 0

        func addPixel(_ x: Int, _ y: Int) {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            totalR += Double(pixelData[offset])
            totalG += Double(pixelData[offset + 1])
            totalB += Double(pixelData[offset + 2])
            totalA += Double(pixelData[offset + 3])
            count += 1
        }

        // Sample a 3px strip at 2px inward from each edge to avoid window chrome.
        let inwardOffset = w > 10 && h > 10 ? 2 : 0
        let stripDepth = w > 10 && h > 10 ? 3 : 1

        for dy in inwardOffset..<min(inwardOffset + stripDepth, h) {
            let bottomY = h - 1 - dy
            for x in 0..<w {
                addPixel(x, dy)
                if bottomY > dy { addPixel(x, bottomY) }
            }
        }
        let stripEnd = min(inwardOffset + stripDepth, h)
        let yStart = stripEnd
        let yEnd = max(yStart, h - stripEnd)
        for dx in inwardOffset..<min(inwardOffset + stripDepth, w) {
            let rightX = w - 1 - dx
            for y in yStart..<yEnd {
                addPixel(dx, y)
                if rightX > dx { addPixel(rightX, y) }
            }
        }

        guard count > 0 else { return NSColor.white.cgColor }

        let r = CGFloat(totalR / count / 255.0)
        let g = CGFloat(totalG / count / 255.0)
        let b = CGFloat(totalB / count / 255.0)
        let a = CGFloat(totalA / count / 255.0)

        if let color = CGColor(colorSpace: colorSpace, components: [r, g, b, a]) {
            return color
        }
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func drawBackground(in context: CGContext, rect: CGRect, settings: BeautificationSettings) {
        switch settings.backgroundType {
        case .gradient:
            let startColor: NSColor
            let endColor: NSColor
            if settings.isCustomGradient {
                startColor = settings.customGradientStart
                endColor = settings.customGradientEnd
            } else {
                let preset = GradientPreset.presets[safe: settings.gradientIndex] ?? GradientPreset.presets[0]
                startColor = preset.startColor
                endColor = preset.endColor
            }
            let colors = [startColor.cgColor, endColor.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.height), end: CGPoint(x: rect.width, y: 0), options: [])

        case .solid:
            context.setFillColor(settings.solidColor.cgColor)
            context.fill(rect)

        case .transparent:
            context.clear(rect)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
