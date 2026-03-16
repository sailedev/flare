import AppKit
import SwiftUI
import Vision

@MainActor
final class PostCapturePreviewViewModel: ObservableObject {
    @Published var originalScreenshot: NSImage {
        didSet { renderPreview() }
    }
    private let originalWithBackground: NSImage

    let ocrEngine: OCREngine

    @Published var settings: BeautificationSettings {
        didSet { renderPreview() }
    }

    // OCR
    @Published var ocrObservations: [VNRecognizedTextObservation] = []
    @Published var selectedOCRText: String = ""

    // Background removal
    @Published var backgroundRemoved: Bool = false
    @Published var isRemovingBackground: Bool = false
    @Published var backgroundRemovalError: String?

    @Published private(set) var cachedPreview: NSImage
    var renderedPreview: NSImage { cachedPreview }

    private func renderPreview() {
        cachedPreview = BeautificationEngine.render(screenshot: originalScreenshot, settings: settings)
    }

    // MARK: - Action Callbacks (set by AppCoordinator)

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    init(originalScreenshot: NSImage, defaultSettings: BeautificationSettings, ocrEngine: OCREngine) {
        self.originalScreenshot = originalScreenshot
        self.originalWithBackground = originalScreenshot
        self.settings = defaultSettings
        self.ocrEngine = ocrEngine
        self.cachedPreview = BeautificationEngine.render(screenshot: originalScreenshot, settings: defaultSettings)

        Task {
            await runOCR()
        }
    }

    // MARK: - OCR

    private func runOCR() async {
        guard let cgImage = originalScreenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let observations = await ocrEngine.recognizeText(in: cgImage)
        ocrObservations = observations
    }

    // MARK: - Actions

    func copyToClipboard() {
        onCopy?()
    }

    func save() {
        onSave?()
    }

    func openEditor() {
        onEdit?()
    }

    func dismiss() {
        onDismiss?()
    }

    // MARK: - Background Removal

    func toggleBackgroundRemoval() {
        if backgroundRemoved {
            originalScreenshot = originalWithBackground
            backgroundRemoved = false
            backgroundRemovalError = nil
        } else {
            guard let cgImage = originalScreenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            isRemovingBackground = true
            backgroundRemovalError = nil

            Task {
                do {
                    let result = try await BeautificationEngine.removeBackground(from: cgImage)
                    let size = originalScreenshot.size
                    originalScreenshot = NSImage(cgImage: result, size: size)
                    backgroundRemoved = true
                } catch {
                    backgroundRemovalError = error.localizedDescription
                }
                isRemovingBackground = false
            }
        }
    }
}
