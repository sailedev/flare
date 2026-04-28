import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.saile.flare", category: "app")

/// NSPanel subclass that can become key window despite .nonactivatingPanel style.
/// Required for SwiftUI .onKeyPress to receive keyboard events (Cmd+C, etc.).
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum CaptureMode: String {
    case fullScreen
    case selection   // Unified: click = window, drag = region
}

enum AppState: Equatable {
    case idle
    case capturing(CaptureMode)
    case postCapture
    case editing
    case showingHistory
    case showingSettings
}

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var state: AppState = .idle

    var statusItem: NSStatusItem?
    let settingsStore = SettingsStore()
    lazy var captureEngine = CaptureEngine()
    lazy var hotkeyManager = HotkeyManager()
    lazy var outputEngine = OutputEngine(settingsStore: settingsStore)
    lazy var historyStore = HistoryStore(settingsStore: settingsStore)
    lazy var ocrEngine = OCREngine()

    private var postCapturePanel: NSPanel?
    private var editorWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var toastPanel: NSPanel?
    private var toastTimer: Timer?
    private var pendingOriginalImage: NSImage?
    private var previewGeneration = 0
    private var lastCapturedAppName: String?
    private var lastCaptureMode: String?
    private(set) var openWindowCount = 0

    init() {
        // Setup deferred to applicationDidFinishLaunching
    }

    func setup() {
        logger.info("App setup started")
        setupHotkeys()
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        showOnboardingIfNeeded()
    }

    private func setupHotkeys() {
        hotkeyManager.register(settingsStore: settingsStore) { [weak self] mode in
            Task { @MainActor in
                self?.startCapture(mode: mode)
            }
        }
    }

    func reloadHotkeys() {
        hotkeyManager.unregisterAll()
        setupHotkeys()
        (NSApp.delegate as? AppDelegate)?.rebuildMenu()
    }

    // MARK: - Dock Visibility

    private func windowDidOpen() {
        openWindowCount += 1
        if openWindowCount == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func windowDidClose() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            // Defer to next run loop to avoid race with window animations
            DispatchQueue.main.async {
                if self.openWindowCount == 0 {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    private func observeClose(of window: NSWindow, clearRef: @escaping @MainActor (AppCoordinator) -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                clearRef(self)
                self.windowDidClose()
            }
        }
    }

    // MARK: - Capture

    func startCapture(mode: CaptureMode) {
        logger.info("Starting capture: \(mode.rawValue, privacy: .public)")
        if case .postCapture = state {
            closePostCapturePreview()
        }
        guard state == .idle else {
            logger.warning("Cannot capture: state is not idle (current: \(String(describing: self.state), privacy: .public))")
            return
        }
        guard checkPermission() else { return }

        // Capture frontmost app before our overlay takes focus
        lastCapturedAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        lastCaptureMode = mode == .fullScreen ? "Full Screen" : "Selection"

        state = .capturing(mode)

        Task {
            let result: NSImage?
            do {
                switch mode {
                case .fullScreen:
                    result = try await captureEngine.captureFullScreen()
                case .selection:
                    result = try await captureEngine.captureUnifiedSelection()
                }
            } catch {
                result = nil
            }
            DispatchQueue.main.async { [weak self] in
                self?.handlePostCapture(image: result)
            }
        }
    }

    private func handlePostCapture(image: NSImage?) {
        guard let image else {
            state = .idle
            return
        }

        if settingsStore.showPreviewAfterCapture {
            logger.info("Showing post-capture preview")
            state = .postCapture
            showPostCapturePreview(image: image)
        } else {
            logger.info("Quick capture mode: \(self.settingsStore.quickCaptureAction.rawValue, privacy: .public)")
            quickCapture(image: image)
        }
    }

    /// Immediately beautify, output, and return to idle - no preview window.
    private func quickCapture(image: NSImage) {
        let settings = settingsStore.defaultBeautificationSettings()
        let beautified = BeautificationEngine.render(screenshot: image, settings: settings)
        let appName = lastCapturedAppName
        let mode = lastCaptureMode

        switch settingsStore.quickCaptureAction {
        case .clipboard:
            outputEngine.copyToClipboard(beautified)
        case .saveToFile:
            outputEngine.saveToDefaultFolder(beautified, format: settingsStore.defaultFormat, quality: settingsStore.jpgQuality, appName: appName, captureMode: mode)
        case .both:
            outputEngine.copyToClipboard(beautified)
            outputEngine.saveToDefaultFolder(beautified, format: settingsStore.defaultFormat, quality: settingsStore.jpgQuality, appName: appName, captureMode: mode)
        }

        historyStore.save(image: beautified, captureMode: mode ?? "capture", appName: appName ?? "")
        showToast(thumbnail: beautified, originalImage: image)
        state = .idle
    }

    // MARK: - Post-Capture Preview

    private func showPostCapturePreview(image: NSImage) {
        previewGeneration += 1
        let thisGeneration = previewGeneration

        let defaultSettings = settingsStore.defaultBeautificationSettings()
        let viewModel = PostCapturePreviewViewModel(
            originalScreenshot: image,
            defaultSettings: defaultSettings,
            ocrEngine: ocrEngine
        )

        let appName = lastCapturedAppName
        let captureMode = lastCaptureMode

        viewModel.onCopy = { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            let beautified = BeautificationEngine.render(screenshot: viewModel.originalScreenshot, settings: viewModel.settings)
            self.outputEngine.copyToClipboard(beautified)
            self.outputEngine.autoSaveIfEnabled(beautified, appName: appName, captureMode: captureMode)
            self.historyStore.save(image: beautified, captureMode: captureMode ?? "capture", appName: appName ?? "")
            self.outputEngine.showCaptureNotification()
            self.closePostCapturePreview()
        }

        viewModel.onSave = { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            let beautified = BeautificationEngine.render(screenshot: viewModel.originalScreenshot, settings: viewModel.settings)
            self.outputEngine.saveToDefaultFolder(beautified, format: self.settingsStore.defaultFormat, quality: self.settingsStore.jpgQuality, appName: appName, captureMode: captureMode)
            self.historyStore.save(image: beautified, captureMode: captureMode ?? "capture", appName: appName ?? "")
            self.outputEngine.showCaptureNotification(action: .saveToFile)
            self.closePostCapturePreview()
        }

        viewModel.onEdit = { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            let image = viewModel.originalScreenshot
            let currentSettings = viewModel.settings
            self.closePostCapturePreview()
            self.openEditor(with: image, settings: currentSettings)
        }

        viewModel.onSettings = { [weak self] in
            self?.showSettings()
        }

        viewModel.onDismiss = { [weak self] in
            self?.closePostCapturePreview()
        }

        // Next run loop to avoid autorelease crash from Task context
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  case .postCapture = self.state,
                  thisGeneration == self.previewGeneration
            else { return }
            autoreleasepool {
                let chromeHeight: CGFloat = 320
                let previewPadding: CGFloat = 32
                let screenMargin: CGFloat = 80
                let minWidth: CGFloat = 480
                let minHeight: CGFloat = 400
                let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let maxWidth = screen.width * 0.7
                let maxHeight = screen.height * 0.85

                let imageSize = image.size
                let availableWidth = maxWidth - previewPadding
                let availableHeight = maxHeight - chromeHeight - previewPadding

                var previewWidth = availableWidth
                var previewHeight = availableWidth / (imageSize.width / imageSize.height)
                if previewHeight > availableHeight {
                    previewHeight = availableHeight
                    previewWidth = availableHeight * (imageSize.width / imageSize.height)
                }

                let windowWidth = max(minWidth, min(maxWidth, previewWidth + previewPadding))
                let windowHeight = max(minHeight, min(maxHeight, previewHeight + chromeHeight + previewPadding))

                let previewView = PostCapturePreviewView(viewModel: viewModel)
                let panel = KeyablePanel(
                    contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                    styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.isReleasedWhenClosed = false
                panel.level = .floating
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.title = "Flare Preview"
                panel.contentView = NSHostingView(rootView: previewView)
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)

                self.postCapturePanel = panel
                self.windowDidOpen()

                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: panel,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.postCapturePanel != nil else { return }
                        self.postCapturePanel = nil
                        self.windowDidClose()
                        if case .postCapture = self.state { self.state = .idle }
                    }
                }
            }
        }
    }

    func closePostCapturePreview() {
        previewGeneration += 1
        if let panel = postCapturePanel {
            postCapturePanel = nil  // nil before close so notification guard catches it
            panel.close()
            windowDidClose()
        }
        if case .postCapture = state {
            state = .idle
        }
    }

    // MARK: - Toast Notification

    func showToast(thumbnail: NSImage, originalImage: NSImage) {
        dismissToast()
        pendingOriginalImage = originalImage

        let toastView = ToastView(
            thumbnail: thumbnail,
            onClick: { [weak self] in
                guard let self,
                      self.state == .idle,
                      let image = self.pendingOriginalImage else { return }
                self.dismissToast()
                self.state = .postCapture
                self.showPostCapturePreview(image: image)
            },
            onDismiss: { [weak self] in
                self?.dismissToast()
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: toastView)
        panel.contentView?.wantsLayer = true

        if let hostingView = panel.contentView as? NSHostingView<ToastView> {
            let size = hostingView.fittingSize
            panel.setContentSize(size)
        }

        positionToast(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        toastPanel = panel

        toastTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismissToast()
            }
        }
    }

    private func dismissToast() {
        toastTimer?.invalidate()
        toastTimer = nil

        guard let panel = toastPanel else {
            pendingOriginalImage = nil
            return
        }

        // Clear references immediately so a new toast can safely replace this one
        toastPanel = nil
        pendingOriginalImage = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func positionToast(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let margin: CGFloat = 16

        let origin: NSPoint
        switch settingsStore.toastPosition {
        case .topRight:
            origin = NSPoint(
                x: screenFrame.maxX - panelSize.width - margin,
                y: screenFrame.maxY - panelSize.height - margin
            )
        case .topLeft:
            origin = NSPoint(
                x: screenFrame.minX + margin,
                y: screenFrame.maxY - panelSize.height - margin
            )
        case .bottomRight:
            origin = NSPoint(
                x: screenFrame.maxX - panelSize.width - margin,
                y: screenFrame.minY + margin
            )
        case .bottomLeft:
            origin = NSPoint(
                x: screenFrame.minX + margin,
                y: screenFrame.minY + margin
            )
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Editor

    func openEditor(with image: NSImage, settings: BeautificationSettings? = nil) {
        state = .editing
        updateMenubarIcon(capturing: false)

        let viewModel = EditorViewModel(
            originalScreenshot: image,
            settingsStore: settingsStore,
            outputEngine: outputEngine,
            historyStore: historyStore,
            ocrEngine: ocrEngine,
            initialSettings: settings
        )
        viewModel.onDismiss = { [weak self] in
            self?.closeEditor()
        }

        let editorView = EditorView(viewModel: viewModel)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.title = "Flare Editor"
        panel.contentView = NSHostingView(rootView: editorView)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        editorWindow = panel
        windowDidOpen()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.editorWindow != nil else { return }
                self.editorWindow = nil
                self.windowDidClose()
                if case .editing = self.state { self.state = .idle }
            }
        }
    }

    func closeEditor() {
        if let window = editorWindow {
            editorWindow = nil
            window.close()
            windowDidClose()
        }
        if case .editing = state { state = .idle }
    }

    // MARK: - History

    func showHistory() {
        if let existing = historyWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let historyView = HistoryPanelView(
            historyStore: historyStore,
            onEdit: { [weak self] image in
                guard let self else { return }
                self.closePostCapturePreview()
                self.openEditor(with: image)
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Flare History"
        window.contentView = NSHostingView(rootView: historyView)
        window.center()
        historyWindow = window
        windowDidOpen()
        observeClose(of: window) { $0.historyWindow = nil }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Settings

    func showSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView(settingsStore: settingsStore, coordinator: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()

        settingsWindow = window
        windowDidOpen()
        observeClose(of: window) { $0.settingsWindow = nil }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
        showOnboarding()
    }

    func showOnboarding() {
        if let existing = onboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let onboardingView = OnboardingView { [weak self] in
            guard let self else { return }
            if let w = self.onboardingWindow {
                self.onboardingWindow = nil
                w.close()
                self.windowDidClose()
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Welcome"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()

        onboardingWindow = window
        windowDidOpen()
        observeClose(of: window) { $0.onboardingWindow = nil }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Permission Check

    /// Returns true if Screen Recording permission is granted.
    /// If not, requests access and shows an alert guiding the user.
    private func checkPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        logger.warning("Screen Recording permission denied - requesting access")
        // CGRequestScreenCaptureAccess registers the app in System Settings
        // and opens the Screen Recording pane on first call.
        CGRequestScreenCaptureAccess()

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Please enable \"Flare\" in System Settings > Privacy & Security > Screen Recording, then try again.\n\nIf \"Flare\" is not listed, click the + button and add it from:\n~/Library/Developer/Xcode/DerivedData/.../Flare.app"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }

    // MARK: - Menubar Icon State

    private func updateMenubarIcon(capturing: Bool) {
        let symbolName = capturing ? "camera.viewfinder.fill" : "camera.viewfinder"
        guard let button = statusItem?.button else { return }
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Flare"
        )
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
    }
}
