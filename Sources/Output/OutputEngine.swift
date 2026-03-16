import AppKit
import UserNotifications
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.saile.flare", category: "output")

final class OutputEngine {
    let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        requestNotificationPermission()
    }

    // MARK: - Notifications

    /// Whether UNUserNotificationCenter is available (requires a valid bundle identifier).
    private var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func requestNotificationPermission() {
        guard canUseNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Shows a notification after capture. When called from the preview flow
    /// (no action parameter), it infers the message from `autoSaveEnabled`.
    /// When called from quick-capture, the explicit action determines the message.
    func showCaptureNotification(action: SettingsStore.QuickCaptureAction? = nil) {
        let body: String
        if let action {
            switch action {
            case .clipboard: body = "Copied to clipboard."
            case .saveToFile: body = "Saved to folder."
            case .both: body = "Copied to clipboard and saved to folder."
            }
        } else {
            body = settingsStore.autoSaveEnabled
                ? "Copied to clipboard and saved to folder."
                : "Copied to clipboard."
        }

        guard canUseNotifications else {
            NSSound(named: "Pop")?.play()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Flare — Captured"
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Clipboard

    func copyToClipboard(_ image: NSImage) {
        guard let pngData = Self.encodePNG(from: image) else {
            logger.error("Failed to encode image for clipboard")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    // MARK: - Auto-save to Folder

    func autoSaveIfEnabled(_ image: NSImage, appName: String? = nil, captureMode: String? = nil) {
        guard settingsStore.autoSaveEnabled, let folder = settingsStore.saveFolderURL else { return }
        let filename = generateFilename(format: settingsStore.defaultFormat, appName: appName, captureMode: captureMode)
        let url = folder.appendingPathComponent(filename)
        saveImage(image, to: url, format: settingsStore.defaultFormat, quality: settingsStore.jpgQuality)
    }

    // MARK: - Save to Default Folder

    func saveToDefaultFolder(_ image: NSImage, format: SettingsStore.ImageFormat, quality: Double, appName: String? = nil, captureMode: String? = nil) {
        guard let folder = settingsStore.saveFolderURL else {
            logger.warning("Save folder not configured — skipping save")
            return
        }
        let filename = generateFilename(format: format, appName: appName, captureMode: captureMode)
        let url = folder.appendingPathComponent(filename)
        saveImage(image, to: url, format: format, quality: quality)
    }

    // MARK: - Save As (with NSSavePanel)

    @MainActor
    func saveAs(_ image: NSImage, format: SettingsStore.ImageFormat, quality: Double, appName: String? = nil, captureMode: String? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = generateFilename(format: format, appName: appName, captureMode: captureMode)
        panel.allowedContentTypes = allowedTypes(for: format)
        panel.canCreateDirectories = true

        if let folder = settingsStore.saveFolderURL {
            panel.directoryURL = folder
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveImage(image, to: url, format: format, quality: quality)
        }
    }

    // MARK: - Format Encoding

    private func saveImage(_ image: NSImage, to url: URL, format: SettingsStore.ImageFormat, quality: Double) {
        guard let cgImage = Self.cgImage(from: image) else {
            logger.error("Failed to extract CGImage for save")
            return
        }
        let data: Data?
        switch format {
        case .png:
            data = Self.encode(cgImage: cgImage, type: .png)
        case .jpg:
            data = Self.encode(cgImage: cgImage, type: .jpeg, quality: quality)
        case .webp:
            data = Self.encode(cgImage: cgImage, typeIdentifier: "public.webp", quality: quality)
                ?? Self.encode(cgImage: cgImage, type: .png)
        }
        if let data {
            do {
                try data.write(to: url)
                logger.debug("Saved image to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Failed to save image: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Direct CGImage Encoding (avoids TIFF intermediates)

    /// Extracts a CGImage from an NSImage without going through TIFF.
    static func cgImage(from image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Encodes a CGImage to PNG or JPEG Data using CGImageDestination.
    static func encode(cgImage: CGImage, type: UTType, quality: Double? = nil) -> Data? {
        encode(cgImage: cgImage, typeIdentifier: type.identifier, quality: quality)
    }

    /// Encodes a CGImage to Data using a type identifier string (supports WebP, etc.).
    static func encode(cgImage: CGImage, typeIdentifier: String, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            typeIdentifier as CFString,
            1, nil
        ) else { return nil }

        var options: [CFString: Any] = [:]
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, cgImage, options.isEmpty ? nil : options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Convenience: encode NSImage to PNG Data.
    static func encodePNG(from image: NSImage) -> Data? {
        guard let cgImage = cgImage(from: image) else { return nil }
        return encode(cgImage: cgImage, type: .png)
    }

    // MARK: - Filename Generation

    func generateFilename(format: SettingsStore.ImageFormat, appName: String? = nil, captureMode: String? = nil) -> String {
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH.mm.ss"
        let datetimeFmt = DateFormatter()
        datetimeFmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

        let template = settingsStore.filenameTemplate
        var name = template
            .replacingOccurrences(of: "{date}", with: dateFmt.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeFmt.string(from: now))
            .replacingOccurrences(of: "{datetime}", with: datetimeFmt.string(from: now))
            .replacingOccurrences(of: "{timestamp}", with: "\(Int(now.timeIntervalSince1970))")
            .replacingOccurrences(of: "{app}", with: appName ?? "Unknown")
            .replacingOccurrences(of: "{mode}", with: captureMode ?? "capture")

        if name.isEmpty { name = "Flare" }
        // Sanitize: remove characters invalid in filenames or that enable path traversal
        let invalidChars = CharacterSet(charactersIn: "/\\:\0\"<>|?*")
        name = name.components(separatedBy: invalidChars).joined(separator: "_")
            .replacingOccurrences(of: "..", with: "_")

        let ext: String
        switch format {
        case .png: ext = "png"
        case .jpg: ext = "jpg"
        case .webp: ext = "webp"
        }
        return "\(name).\(ext)"
    }

    private func allowedTypes(for format: SettingsStore.ImageFormat) -> [UTType] {
        switch format {
        case .png: return [.png]
        case .jpg: return [.jpeg]
        case .webp: return [UTType(filenameExtension: "webp") ?? .png]
        }
    }
}
