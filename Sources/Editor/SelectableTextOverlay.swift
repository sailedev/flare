import SwiftUI
import Vision

/// Overlay for selecting and copying OCR text from a screenshot.
struct SelectableTextOverlay: View {
    let observations: [VNRecognizedTextObservation]
    /// Where the original image content sits in the rendered canvas (pixel coords).
    let contentRect: CGRect
    /// Total canvas size of the rendered image (pixel coords).
    let canvasSize: CGSize
    /// Binding to report selected text back to the parent.
    @Binding var selectedText: String

    @State private var selectedIndices: Set<Int> = []
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Draw selection highlights over selected observations
                for index in selectedIndices {
                    guard index < observations.count else { continue }
                    let rect = observationViewRect(observations[index], viewSize: size)
                    // macOS-style text selection highlight
                    context.fill(
                        Path(rect),
                        with: .color(Color.accentColor.opacity(0.3))
                    )
                }

                // Draw in-progress drag selection rectangle
                if let start = dragStart, let current = dragCurrent {
                    let selRect = rectFrom(start, current)
                    if selRect.width > 2 || selRect.height > 2 {
                        context.fill(
                            Path(selRect),
                            with: .color(Color.accentColor.opacity(0.08))
                        )
                        context.stroke(
                            Path(selRect),
                            with: .color(Color.accentColor.opacity(0.4)),
                            style: StrokeStyle(lineWidth: 1)
                        )
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.startLocation
                        }
                        dragCurrent = value.location
                        // Live-select text regions that intersect the drag rect
                        let selRect = rectFrom(value.startLocation, value.location)
                        updateSelection(in: selRect, viewSize: geo.size)
                    }
                    .onEnded { value in
                        let selRect = rectFrom(value.startLocation, value.location)
                        updateSelection(in: selRect, viewSize: geo.size)
                        dragStart = nil
                        dragCurrent = nil
                    }
            )
            .onTapGesture { location in
                // Tap on a text region toggles its selection; tap empty clears all
                tapSelect(at: location, viewSize: geo.size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let overText = observations.indices.contains(where: { index in
                        observationViewRect(observations[index], viewSize: geo.size).contains(location)
                    })
                    if overText {
                        NSCursor.iBeam.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                case .ended:
                    NSCursor.arrow.set()
                @unknown default:
                    break
                }
            }
            .contentShape(Rectangle())
            .onDisappear { NSCursor.arrow.set() }
        }
    }

    // MARK: - Coordinate Mapping

    /// Maps a Vision observation's bounding box to view coordinates.
    /// Vision bbox: normalized 0-1, origin bottom-left.
    /// Content rect: where the original content sits in the rendered canvas (pixels).
    /// View: the SwiftUI overlay frame matching the displayed image.
    private func observationViewRect(_ observation: VNRecognizedTextObservation, viewSize: CGSize) -> CGRect {
        let bbox = observation.boundingBox
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }

        // Map from Vision normalized coords to pixel position in the canvas
        let pixelX = contentRect.origin.x + bbox.origin.x * contentRect.width
        // Vision Y is bottom-up; canvas Y is top-down (for display)
        let pixelY = contentRect.origin.y + (1.0 - bbox.origin.y - bbox.height) * contentRect.height
        let pixelW = bbox.width * contentRect.width
        let pixelH = bbox.height * contentRect.height

        // Compute the actual fitted image rect within the overlay view
        // (the Image uses .aspectRatio(contentMode: .fit))
        let imageAspect = canvasSize.width / canvasSize.height
        let viewAspect = viewSize.width / viewSize.height
        let fittedSize: CGSize
        let fittedOrigin: CGPoint
        if imageAspect > viewAspect {
            fittedSize = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
            fittedOrigin = CGPoint(x: 0, y: (viewSize.height - fittedSize.height) / 2)
        } else {
            fittedSize = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
            fittedOrigin = CGPoint(x: (viewSize.width - fittedSize.width) / 2, y: 0)
        }

        let scaleX = fittedSize.width / canvasSize.width
        let scaleY = fittedSize.height / canvasSize.height

        return CGRect(
            x: fittedOrigin.x + pixelX * scaleX,
            y: fittedOrigin.y + pixelY * scaleY,
            width: pixelW * scaleX,
            height: pixelH * scaleY
        )
    }

    // MARK: - Selection Logic

    private func updateSelection(in selRect: CGRect, viewSize: CGSize) {
        var selected = Set<Int>()
        for (index, observation) in observations.enumerated() {
            let rect = observationViewRect(observation, viewSize: viewSize)
            if rect.intersects(selRect) {
                selected.insert(index)
            }
        }
        selectedIndices = selected
        rebuildSelectedText()
    }

    private func tapSelect(at point: CGPoint, viewSize: CGSize) {
        for (index, observation) in observations.enumerated() {
            let rect = observationViewRect(observation, viewSize: viewSize)
            if rect.contains(point) {
                if selectedIndices.contains(index) {
                    selectedIndices.remove(index)
                } else {
                    selectedIndices.insert(index)
                }
                rebuildSelectedText()
                return
            }
        }
        // Tapped empty space - clear selection
        selectedIndices.removeAll()
        rebuildSelectedText()
    }

    /// Rebuilds the selected text string from selected observations, sorted in reading order.
    private func rebuildSelectedText() {
        let text = selectedIndices
            .sorted { a, b in
                // Sort by vertical position (top to bottom), then horizontal (left to right)
                let bboxA = observations[a].boundingBox
                let bboxB = observations[b].boundingBox
                // Vision Y is bottom-up, so higher Y = higher on screen = should come first
                if abs(bboxA.origin.y - bboxB.origin.y) > 0.01 {
                    return bboxA.origin.y > bboxB.origin.y
                }
                return bboxA.origin.x < bboxB.origin.x
            }
            .compactMap { index -> String? in
                guard index < observations.count else { return nil }
                return observations[index].topCandidates(1).first?.string
            }
            .joined(separator: "\n")

        selectedText = text
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
