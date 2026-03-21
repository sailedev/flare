import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select = "Select"
    case arrow = "Arrow"
    case text = "Text"
    case rectangle = "Rectangle"
    case circle = "Circle"
    case highlight = "Highlight"
    case blur = "Blur"
    case callout = "Callout"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .highlight: return "highlighter"
        case .blur: return "eye.slash"
        case .callout: return "number.circle"
        }
    }
}

struct AnnotationStyle {
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var fontSize: CGFloat = 16
    var filled: Bool = false
}

enum AnnotationItem {
    case arrow(start: CGPoint, end: CGPoint, style: AnnotationStyle)
    case text(position: CGPoint, content: String, style: AnnotationStyle)
    case rectangle(rect: CGRect, style: AnnotationStyle)
    case circle(rect: CGRect, style: AnnotationStyle)
    case highlight(rect: CGRect, color: NSColor = .systemYellow, opacity: CGFloat = 0.35)
    case blur(rect: CGRect)
    case callout(position: CGPoint, number: Int, style: AnnotationStyle)

    var boundingRect: CGRect {
        switch self {
        case .arrow(let start, let end, let style):
            let pad = style.lineWidth + 8
            return CGRect(
                x: min(start.x, end.x) - pad,
                y: min(start.y, end.y) - pad,
                width: abs(end.x - start.x) + pad * 2,
                height: abs(end.y - start.y) + pad * 2
            )
        case .rectangle(let rect, _), .circle(let rect, _):
            return rect
        case .highlight(let rect, _, _), .blur(let rect):
            return rect
        case .text(let pos, let content, let style):
            let size = (content as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)]
            )
            return CGRect(origin: pos, size: size)
        case .callout(let pos, _, _):
            return CGRect(x: pos.x - 14, y: pos.y - 14, width: 28, height: 28)
        }
    }

    func translated(by delta: CGSize) -> AnnotationItem {
        switch self {
        case .arrow(let start, let end, let style):
            return .arrow(
                start: CGPoint(x: start.x + delta.width, y: start.y + delta.height),
                end: CGPoint(x: end.x + delta.width, y: end.y + delta.height),
                style: style
            )
        case .text(let pos, let content, let style):
            return .text(
                position: CGPoint(x: pos.x + delta.width, y: pos.y + delta.height),
                content: content, style: style
            )
        case .rectangle(let rect, let style):
            return .rectangle(rect: rect.offsetBy(dx: delta.width, dy: delta.height), style: style)
        case .circle(let rect, let style):
            return .circle(rect: rect.offsetBy(dx: delta.width, dy: delta.height), style: style)
        case .highlight(let rect, let color, let opacity):
            return .highlight(rect: rect.offsetBy(dx: delta.width, dy: delta.height), color: color, opacity: opacity)
        case .blur(let rect):
            return .blur(rect: rect.offsetBy(dx: delta.width, dy: delta.height))
        case .callout(let pos, let number, let style):
            return .callout(
                position: CGPoint(x: pos.x + delta.width, y: pos.y + delta.height),
                number: number, style: style
            )
        }
    }

    func resized(to newRect: CGRect) -> AnnotationItem {
        switch self {
        case .rectangle(_, let style): return .rectangle(rect: newRect, style: style)
        case .circle(_, let style): return .circle(rect: newRect, style: style)
        case .highlight(_, let color, let opacity): return .highlight(rect: newRect, color: color, opacity: opacity)
        case .blur: return .blur(rect: newRect)
        default: return self
        }
    }

    func withArrowStart(_ point: CGPoint) -> AnnotationItem {
        if case .arrow(_, let end, let style) = self {
            return .arrow(start: point, end: end, style: style)
        }
        return self
    }

    func withArrowEnd(_ point: CGPoint) -> AnnotationItem {
        if case .arrow(let start, _, let style) = self {
            return .arrow(start: start, end: point, style: style)
        }
        return self
    }

    func draw(in context: CGContext, canvasSize: CGSize) {
        switch self {
        case .arrow(let start, let end, let style):
            drawArrow(in: context, from: start, to: end, style: style)
        case .text(let position, let content, let style):
            drawText(in: context, at: position, content: content, style: style)
        case .rectangle(let rect, let style):
            drawRectangle(in: context, rect: rect, style: style)
        case .circle(let rect, let style):
            drawCircle(in: context, rect: rect, style: style)
        case .highlight(let rect, let color, let opacity):
            drawHighlight(in: context, rect: rect, color: color, opacity: opacity)
        case .blur(let rect):
            drawBlur(in: context, rect: rect)
        case .callout(let position, let number, let style):
            drawCallout(in: context, at: position, number: number, style: style)
        }
    }

    // MARK: - Drawing Implementations

    private func drawArrow(in context: CGContext, from start: CGPoint, to end: CGPoint, style: AnnotationStyle) {
        context.saveGState()
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)

        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 15
        let arrowAngle: CGFloat = .pi / 6

        let p1 = CGPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )

        context.setFillColor(style.color.cgColor)
        context.move(to: end)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.fillPath()

        context.restoreGState()
    }

    private func drawText(in context: CGContext, at position: CGPoint, content: String, style: AnnotationStyle) {
        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color,
        ]
        let nsString = content as NSString

        // Flip context for text drawing
        context.saveGState()

        let textSize = nsString.size(withAttributes: attributes)

        if style.filled {
            let bgRect = CGRect(
                x: position.x - 4,
                y: position.y - 2,
                width: textSize.width + 8,
                height: textSize.height + 4
            )
            context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.fill(bgRect)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        nsString.draw(at: position, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }

    private func drawRectangle(in context: CGContext, rect: CGRect, style: AnnotationStyle) {
        context.saveGState()
        if style.filled {
            context.setFillColor(style.color.withAlphaComponent(0.3).cgColor)
            context.fill(rect)
        }
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(style.lineWidth)
        context.stroke(rect)
        context.restoreGState()
    }

    private func drawCircle(in context: CGContext, rect: CGRect, style: AnnotationStyle) {
        context.saveGState()
        if style.filled {
            context.setFillColor(style.color.withAlphaComponent(0.3).cgColor)
            context.fillEllipse(in: rect)
        }
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(style.lineWidth)
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    private func drawHighlight(in context: CGContext, rect: CGRect, color: NSColor, opacity: CGFloat) {
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(opacity).cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    private func drawBlur(in context: CGContext, rect: CGRect) {
        // Deterministic mosaic pattern - matches preview and export
        context.saveGState()
        context.setFillColor(NSColor.gray.cgColor)
        context.fill(rect)

        let blockSize: CGFloat = 8
        var x = rect.origin.x
        while x < rect.maxX {
            var y = rect.origin.y
            while y < rect.maxY {
                // Seed relative to rect origin so pattern matches preview regardless of coordinate transform
                let seed = Int((x - rect.origin.x) / blockSize) &* 31 &+ Int((y - rect.origin.y) / blockSize) &* 17
                let brightness = 0.3 + CGFloat(abs(seed) % 40) / 100.0
                context.setFillColor(NSColor(white: brightness, alpha: 1).cgColor)
                let blockRect = CGRect(
                    x: x, y: y,
                    width: min(blockSize, rect.maxX - x),
                    height: min(blockSize, rect.maxY - y)
                )
                context.fill(blockRect)
                y += blockSize
            }
            x += blockSize
        }
        context.restoreGState()
    }

    private func drawCallout(in context: CGContext, at position: CGPoint, number: Int, style: AnnotationStyle) {
        let radius: CGFloat = 14
        let circleRect = CGRect(
            x: position.x - radius,
            y: position.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        context.saveGState()

        context.setFillColor(style.color.cgColor)
        context.fillEllipse(in: circleRect)

        let font = NSFont.systemFont(ofSize: 12, weight: .bold)
        let text = "\(number)" as NSString
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: textAttrs)
        let textPoint = NSPoint(
            x: position.x - textSize.width / 2,
            y: position.y - textSize.height / 2
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(at: textPoint, withAttributes: textAttrs)
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }
}
