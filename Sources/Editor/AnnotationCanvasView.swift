import SwiftUI

struct AnnotationCanvasView: View {
    @ObservedObject var viewModel: EditorViewModel

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    // Selection interaction state
    @State private var isDraggingAnnotation = false
    @State private var dragLastPoint: CGPoint?
    @State private var activeHandle: AnnotationHandle?
    @State private var didPushUndoForDrag = false

    // Text editing state
    @State private var pendingTextPosition: CGPoint?
    @State private var pendingTextContent: String = ""
    @FocusState private var isTextFieldFocused: Bool

    enum AnnotationHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case arrowStart, arrowEnd
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                for (index, annotation) in viewModel.annotations.enumerated() {
                    drawAnnotation(annotation, in: &context, size: size)

                    if viewModel.activeTool == .select && viewModel.selectedAnnotationIndex == index {
                        drawSelectionIndicator(for: annotation, in: &context)
                    }
                }

                if let inProgress = inProgressAnnotation(in: size) {
                    drawAnnotation(inProgress, in: &context, size: size)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if viewModel.activeTool == .select {
                            handleSelectDrag(value, in: geo.size)
                        } else {
                            if dragStart == nil { dragStart = value.startLocation }
                            dragCurrent = value.location
                        }
                    }
                    .onEnded { value in
                        if viewModel.activeTool == .select {
                            finishSelectDrag()
                        } else {
                            commitAnnotation(in: geo.size)
                            dragStart = nil
                            dragCurrent = nil
                        }
                    }
            )
            .onTapGesture { location in
                if viewModel.activeTool == .select {
                    handleSelectTap(at: location)
                } else if viewModel.activeTool == .text {
                    pendingTextContent = ""
                    pendingTextPosition = location
                    isTextFieldFocused = true
                } else if viewModel.activeTool == .callout {
                    viewModel.pushUndoState()
                    viewModel.annotations.append(.callout(position: location, number: viewModel.nextCalloutNumber, style: viewModel.annotationStyle))
                    viewModel.nextCalloutNumber += 1
                }
            }
            .contentShape(Rectangle())
            .overlay {
                if let pos = pendingTextPosition {
                    textInputOverlay(at: pos)
                }
            }
            .onAppear { viewModel.canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in viewModel.canvasSize = newSize }
        }
    }

    // MARK: - Text Input Overlay

    private func textInputOverlay(at position: CGPoint) -> some View {
        TextField("Type text...", text: $pendingTextContent)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .focused($isTextFieldFocused)
            .position(x: position.x + 100, y: position.y)
            .onSubmit {
                commitTextAnnotation()
            }
            .onExitCommand {
                pendingTextPosition = nil
                pendingTextContent = ""
            }
    }

    private func commitTextAnnotation() {
        guard let pos = pendingTextPosition else { return }
        let content = pendingTextContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            pendingTextPosition = nil
            pendingTextContent = ""
            return
        }
        viewModel.pushUndoState()
        viewModel.annotations.append(.text(position: pos, content: content, style: viewModel.annotationStyle))
        pendingTextPosition = nil
        pendingTextContent = ""
    }

    // MARK: - Selection Gestures

    private func handleSelectTap(at point: CGPoint) {
        if let index = viewModel.hitTest(at: point) {
            viewModel.selectedAnnotationIndex = index
        } else {
            viewModel.selectedAnnotationIndex = nil
        }
    }

    private func handleSelectDrag(_ value: DragGesture.Value, in size: CGSize) {
        let current = value.location

        // First drag event — determine what we're dragging
        if !isDraggingAnnotation {
            let start = value.startLocation

            // Check if dragging a handle on the selected annotation
            if let selIdx = viewModel.selectedAnnotationIndex,
               viewModel.annotations.indices.contains(selIdx) {
                if let handle = hitTestHandle(at: start, for: viewModel.annotations[selIdx]) {
                    activeHandle = handle
                    isDraggingAnnotation = true
                    dragLastPoint = start
                    if !didPushUndoForDrag {
                        viewModel.pushUndoState()
                        didPushUndoForDrag = true
                    }
                    return
                }
            }

            // Check if dragging an annotation body
            if let index = viewModel.hitTest(at: start) {
                viewModel.selectedAnnotationIndex = index
                isDraggingAnnotation = true
                activeHandle = nil
                dragLastPoint = start
                if !didPushUndoForDrag {
                    viewModel.pushUndoState()
                    didPushUndoForDrag = true
                }
                return
            }

            // Nothing hit — deselect
            viewModel.selectedAnnotationIndex = nil
            return
        }

        // Ongoing drag
        guard let lastPoint = dragLastPoint,
              let selIdx = viewModel.selectedAnnotationIndex,
              viewModel.annotations.indices.contains(selIdx) else { return }

        if let handle = activeHandle {
            // Handle drag — resize or move endpoint
            switch handle {
            case .arrowStart:
                viewModel.moveArrowEndpoint(at: selIdx, isStart: true, to: current)
            case .arrowEnd:
                viewModel.moveArrowEndpoint(at: selIdx, isStart: false, to: current)
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                let oldRect = viewModel.annotations[selIdx].boundingRect
                let newRect = resizedRect(oldRect, handle: handle, to: current)
                viewModel.resizeAnnotation(at: selIdx, to: newRect)
            }
        } else {
            // Body drag — move
            let delta = CGSize(width: current.x - lastPoint.x, height: current.y - lastPoint.y)
            viewModel.moveAnnotation(at: selIdx, by: delta)
        }

        dragLastPoint = current
    }

    private func finishSelectDrag() {
        isDraggingAnnotation = false
        dragLastPoint = nil
        activeHandle = nil
        didPushUndoForDrag = false
    }

    // MARK: - Handle Hit-Testing

    private func hitTestHandle(at point: CGPoint, for annotation: AnnotationItem) -> AnnotationHandle? {
        let handleRadius: CGFloat = 8

        if case .arrow(let start, let end, _) = annotation {
            if hypot(point.x - start.x, point.y - start.y) < handleRadius * 2 {
                return .arrowStart
            }
            if hypot(point.x - end.x, point.y - end.y) < handleRadius * 2 {
                return .arrowEnd
            }
            return nil
        }

        let rect = annotation.boundingRect
        let corners: [(CGPoint, AnnotationHandle)] = [
            (CGPoint(x: rect.minX, y: rect.minY), .topLeft),
            (CGPoint(x: rect.maxX, y: rect.minY), .topRight),
            (CGPoint(x: rect.minX, y: rect.maxY), .bottomLeft),
            (CGPoint(x: rect.maxX, y: rect.maxY), .bottomRight),
        ]

        for (corner, handle) in corners {
            if hypot(point.x - corner.x, point.y - corner.y) < handleRadius * 2 {
                return handle
            }
        }
        return nil
    }

    private func resizedRect(_ rect: CGRect, handle: AnnotationHandle, to point: CGPoint) -> CGRect {
        let newRect: CGRect
        switch handle {
        case .topLeft:
            newRect = CGRect(x: point.x, y: point.y,
                             width: rect.maxX - point.x, height: rect.maxY - point.y)
        case .topRight:
            newRect = CGRect(x: rect.minX, y: point.y,
                             width: point.x - rect.minX, height: rect.maxY - point.y)
        case .bottomLeft:
            newRect = CGRect(x: point.x, y: rect.minY,
                             width: rect.maxX - point.x, height: point.y - rect.minY)
        case .bottomRight:
            newRect = CGRect(x: rect.minX, y: rect.minY,
                             width: point.x - rect.minX, height: point.y - rect.minY)
        default:
            return rect
        }
        // Normalize: prevent negative width/height from dragging past opposite corner
        return CGRect(
            x: min(newRect.origin.x, newRect.origin.x + newRect.width),
            y: min(newRect.origin.y, newRect.origin.y + newRect.height),
            width: abs(newRect.width),
            height: abs(newRect.height)
        )
    }

    // MARK: - Selection Drawing

    private func drawSelectionIndicator(for annotation: AnnotationItem, in context: inout GraphicsContext) {
        let rect = annotation.boundingRect
        let handleSize: CGFloat = 8

        // Dashed blue border
        let borderPath = Path(rect.insetBy(dx: -3, dy: -3))
        context.stroke(
            borderPath,
            with: .color(.blue.opacity(0.6)),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        )

        if case .arrow(let start, let end, _) = annotation {
            // Arrow endpoint handles
            drawHandle(at: start, in: &context, size: handleSize)
            drawHandle(at: end, in: &context, size: handleSize)
        } else if case .text = annotation {
            // Text: no resize handles, just the border
        } else if case .callout = annotation {
            // Callout: no resize handles, just the border
        } else {
            // Corner handles for rect-based annotations
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
            ]
            for corner in corners {
                drawHandle(at: corner, in: &context, size: handleSize)
            }
        }
    }

    private func drawHandle(at point: CGPoint, in context: inout GraphicsContext, size: CGFloat) {
        let handleRect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        context.fill(Path(handleRect), with: .color(.white))
        context.stroke(Path(handleRect), with: .color(.blue), lineWidth: 1.5)
    }

    // MARK: - In-progress Annotation

    private func inProgressAnnotation(in size: CGSize) -> AnnotationItem? {
        guard viewModel.activeTool != .select else { return nil }
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let style = viewModel.annotationStyle

        switch viewModel.activeTool {
        case .arrow:
            return .arrow(start: start, end: current, style: style)
        case .rectangle:
            return .rectangle(rect: rectFrom(start, current), style: style)
        case .circle:
            return .circle(rect: rectFrom(start, current), style: style)
        case .highlight:
            return .highlight(rect: rectFrom(start, current), color: style.color, opacity: 0.35)
        case .blur:
            return .blur(rect: rectFrom(start, current))
        default:
            return nil
        }
    }

    private func commitAnnotation(in size: CGSize) {
        guard let start = dragStart, let current = dragCurrent else { return }
        let style = viewModel.annotationStyle
        let rect = rectFrom(start, current)

        switch viewModel.activeTool {
        case .arrow:
            let dist = hypot(current.x - start.x, current.y - start.y)
            guard dist > 5 else { return }
            viewModel.pushUndoState()
            viewModel.annotations.append(.arrow(start: start, end: current, style: style))
        case .rectangle:
            guard rect.width > 3 || rect.height > 3 else { return }
            viewModel.pushUndoState()
            viewModel.annotations.append(.rectangle(rect: rect, style: style))
        case .circle:
            guard rect.width > 3 || rect.height > 3 else { return }
            viewModel.pushUndoState()
            viewModel.annotations.append(.circle(rect: rect, style: style))
        case .highlight:
            guard rect.width > 3 || rect.height > 3 else { return }
            viewModel.pushUndoState()
            viewModel.annotations.append(.highlight(rect: rect, color: style.color, opacity: 0.35))
        case .blur:
            guard rect.width > 3 || rect.height > 3 else { return }
            viewModel.pushUndoState()
            viewModel.annotations.append(.blur(rect: rect))
        default:
            break
        }
    }

    // MARK: - Canvas Drawing

    private func drawAnnotation(_ item: AnnotationItem, in context: inout GraphicsContext, size: CGSize) {
        switch item {
        case .arrow(let start, let end, let style):
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(Color(nsColor: style.color)), lineWidth: style.lineWidth)

            let angle = atan2(end.y - start.y, end.x - start.x)
            let arrowLen: CGFloat = 15
            let arrowAngle: CGFloat = .pi / 6
            var arrowPath = Path()
            arrowPath.move(to: end)
            arrowPath.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle - arrowAngle), y: end.y - arrowLen * sin(angle - arrowAngle)))
            arrowPath.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle + arrowAngle), y: end.y - arrowLen * sin(angle + arrowAngle)))
            arrowPath.closeSubpath()
            context.fill(arrowPath, with: .color(Color(nsColor: style.color)))

        case .text(let position, let content, let style):
            context.draw(
                Text(content).font(.system(size: style.fontSize, weight: .semibold)).foregroundColor(Color(nsColor: style.color)),
                at: position, anchor: .topLeading
            )

        case .rectangle(let rect, let style):
            if style.filled {
                context.fill(Path(rect), with: .color(Color(nsColor: style.color).opacity(0.3)))
            }
            context.stroke(Path(rect), with: .color(Color(nsColor: style.color)), lineWidth: style.lineWidth)

        case .circle(let rect, let style):
            let ellipse = Path(ellipseIn: rect)
            if style.filled {
                context.fill(ellipse, with: .color(Color(nsColor: style.color).opacity(0.3)))
            }
            context.stroke(ellipse, with: .color(Color(nsColor: style.color)), lineWidth: style.lineWidth)

        case .highlight(let rect, let color, let opacity):
            context.fill(Path(rect), with: .color(Color(nsColor: color).opacity(opacity)))

        case .blur(let rect):
            context.fill(Path(rect), with: .color(.gray))
            let blockSize: CGFloat = 8
            var bx = rect.origin.x
            while bx < rect.maxX {
                var by = rect.origin.y
                while by < rect.maxY {
                    let seed = Int((bx - rect.origin.x) / blockSize) &* 31 &+ Int((by - rect.origin.y) / blockSize) &* 17
                    let brightness = 0.3 + Double(abs(seed) % 40) / 100.0
                    let blockRect = CGRect(
                        x: bx, y: by,
                        width: min(blockSize, rect.maxX - bx),
                        height: min(blockSize, rect.maxY - by)
                    )
                    context.fill(Path(blockRect), with: .color(Color(white: brightness)))
                    by += blockSize
                }
                bx += blockSize
            }

        case .callout(let position, let number, let style):
            let r: CGFloat = 14
            let circle = Path(ellipseIn: CGRect(x: position.x - r, y: position.y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(Color(nsColor: style.color)))
            context.draw(
                Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundColor(.white),
                at: position
            )
        }
    }

    // MARK: - Utility

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
