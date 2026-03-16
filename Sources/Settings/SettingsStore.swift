import Foundation
import AppKit
import ServiceManagement

final class SettingsStore: ObservableObject {

    // MARK: - Hotkeys (keyCode + modifierFlags per mode)

    struct HotkeyBinding: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    @Published var fullScreenHotkey: HotkeyBinding {
        didSet { save("fullScreenHotkey", fullScreenHotkey) }
    }
    @Published var selectionHotkey: HotkeyBinding {
        didSet { save("selectionHotkey", selectionHotkey) }
    }


    // MARK: - Post-Capture Behavior

    enum QuickCaptureAction: String, CaseIterable, Codable {
        case clipboard = "Copy to clipboard"
        case saveToFile = "Save to file"
        case both = "Copy and save"
    }

    enum ToastPosition: String, CaseIterable, Codable {
        case topRight = "Top Right"
        case topLeft = "Top Left"
        case bottomRight = "Bottom Right"
        case bottomLeft = "Bottom Left"
    }

    @Published var showPreviewAfterCapture: Bool {
        didSet { UserDefaults.standard.set(showPreviewAfterCapture, forKey: "showPreviewAfterCapture") }
    }

    @Published var quickCaptureAction: QuickCaptureAction {
        didSet { UserDefaults.standard.set(quickCaptureAction.rawValue, forKey: "quickCaptureAction") }
    }

    @Published var toastPosition: ToastPosition {
        didSet { UserDefaults.standard.set(toastPosition.rawValue, forKey: "toastPosition") }
    }

    // MARK: - Output

    enum ImageFormat: String, CaseIterable, Codable {
        case png = "PNG"
        case jpg = "JPG"
        case webp = "WebP"
    }

    @Published var defaultFormat: ImageFormat {
        didSet { UserDefaults.standard.set(defaultFormat.rawValue, forKey: "defaultFormat") }
    }

    @Published var filenameTemplate: String {
        didSet { UserDefaults.standard.set(filenameTemplate, forKey: "filenameTemplate") }
    }

    @Published var saveFolderURL: URL? {
        didSet {
            if let url = saveFolderURL {
                UserDefaults.standard.set(url.path, forKey: "saveFolderPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "saveFolderPath")
            }
        }
    }

    @Published var autoSaveEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: "autoSaveEnabled") }
    }

    @Published var jpgQuality: Double {
        didSet { UserDefaults.standard.set(jpgQuality, forKey: "jpgQuality") }
    }

    // MARK: - Beautification Defaults

    @Published var defaultPadding: CGFloat {
        didSet { UserDefaults.standard.set(Double(defaultPadding), forKey: "defaultPadding") }
    }

    @Published var defaultShadowIntensity: CGFloat {
        didSet { UserDefaults.standard.set(Double(defaultShadowIntensity), forKey: "defaultShadowIntensity") }
    }

    @Published var defaultShadowDirection: ShadowDirection {
        didSet { UserDefaults.standard.set(defaultShadowDirection.rawValue, forKey: "defaultShadowDirection") }
    }

    @Published var defaultInset: CGFloat {
        didSet { UserDefaults.standard.set(Double(defaultInset), forKey: "defaultInset") }
    }

    @Published var defaultAutoBalance: Bool {
        didSet { UserDefaults.standard.set(defaultAutoBalance, forKey: "defaultAutoBalance") }
    }

    @Published var defaultCornerRadius: CGFloat {
        didSet { UserDefaults.standard.set(Double(defaultCornerRadius), forKey: "defaultCornerRadius") }
    }

    @Published var usePercentageScaling: Bool {
        didSet {
            UserDefaults.standard.set(usePercentageScaling, forKey: "usePercentageScaling")
        }
    }

    enum BackgroundType: String, CaseIterable, Codable {
        case gradient
        case solid
        case transparent
    }

    @Published var defaultBackgroundType: BackgroundType {
        didSet { UserDefaults.standard.set(defaultBackgroundType.rawValue, forKey: "defaultBackgroundType") }
    }

    @Published var defaultGradientIndex: Int {
        didSet { UserDefaults.standard.set(defaultGradientIndex, forKey: "defaultGradientIndex") }
    }

    @Published var defaultSolidColor: NSColor {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: defaultSolidColor, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "defaultSolidColor")
            }
        }
    }

    @Published var defaultIsCustomGradient: Bool {
        didSet { UserDefaults.standard.set(defaultIsCustomGradient, forKey: "defaultIsCustomGradient") }
    }

    @Published var defaultCustomGradientStart: NSColor {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: defaultCustomGradientStart, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "defaultCustomGradientStart")
            }
        }
    }

    @Published var defaultCustomGradientEnd: NSColor {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: defaultCustomGradientEnd, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "defaultCustomGradientEnd")
            }
        }
    }

    // MARK: - Selection Overlay

    @Published var overlayDimOpacity: Double {
        didSet { UserDefaults.standard.set(overlayDimOpacity, forKey: "overlayDimOpacity") }
    }

    @Published var overlayHighlightColor: NSColor {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: overlayHighlightColor, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "overlayHighlightColor")
            }
        }
    }

    @Published var overlayHighlightOpacity: Double {
        didSet { UserDefaults.standard.set(overlayHighlightOpacity, forKey: "overlayHighlightOpacity") }
    }

    // MARK: - History

    @Published var historyLimit: Int {
        didSet { UserDefaults.standard.set(historyLimit, forKey: "historyLimit") }
    }

    // MARK: - Hotkey Conflicts (set by HotkeyManager on registration failure)

    @Published var hotkeyConflicts: Set<String> = []

    // MARK: - General

    @Published var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }

    // MARK: - Defaults

    static let defaultFullScreenHotkey = HotkeyBinding(keyCode: 18, modifiers: 0x001200) // Ctrl+Shift+1
    static let defaultSelectionHotkey = HotkeyBinding(keyCode: 19, modifiers: 0x001200) // Ctrl+Shift+2


    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        self.fullScreenHotkey = Self.load("fullScreenHotkey") ?? Self.defaultFullScreenHotkey
        self.selectionHotkey = Self.load("selectionHotkey") ?? Self.defaultSelectionHotkey

        // Post-capture behavior (default: show preview)
        self.showPreviewAfterCapture = defaults.object(forKey: "showPreviewAfterCapture") != nil
            ? defaults.bool(forKey: "showPreviewAfterCapture") : true
        self.quickCaptureAction = QuickCaptureAction(rawValue: defaults.string(forKey: "quickCaptureAction") ?? "") ?? .clipboard
        self.toastPosition = ToastPosition(rawValue: defaults.string(forKey: "toastPosition") ?? "") ?? .topRight

        self.defaultFormat = ImageFormat(rawValue: defaults.string(forKey: "defaultFormat") ?? "") ?? .png
        self.filenameTemplate = defaults.string(forKey: "filenameTemplate") ?? "Flare {date} at {time}"
        self.autoSaveEnabled = defaults.bool(forKey: "autoSaveEnabled")
        self.jpgQuality = defaults.object(forKey: "jpgQuality") != nil ? defaults.double(forKey: "jpgQuality") : 0.9

        if let path = defaults.string(forKey: "saveFolderPath") {
            self.saveFolderURL = URL(fileURLWithPath: path)
        } else {
            self.saveFolderURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }

        self.defaultPadding = CGFloat(defaults.object(forKey: "defaultPadding") != nil ? defaults.double(forKey: "defaultPadding") : 40.0)
        // Migration: old shadowEnabled/shadowRadius → new shadowIntensity (0-100)
        if defaults.object(forKey: "defaultShadowIntensity") != nil {
            self.defaultShadowIntensity = CGFloat(defaults.double(forKey: "defaultShadowIntensity"))
        } else if defaults.object(forKey: "defaultShadowEnabled") != nil && !defaults.bool(forKey: "defaultShadowEnabled") {
            self.defaultShadowIntensity = 0
        } else {
            self.defaultShadowIntensity = 50.0 // default: moderate shadow
        }
        self.defaultShadowDirection = ShadowDirection(rawValue: defaults.string(forKey: "defaultShadowDirection") ?? "") ?? .bottomRight
        self.defaultInset = CGFloat(defaults.object(forKey: "defaultInset") != nil ? defaults.double(forKey: "defaultInset") : 0.0)
        self.defaultAutoBalance = defaults.bool(forKey: "defaultAutoBalance")
        self.defaultCornerRadius = CGFloat(defaults.object(forKey: "defaultCornerRadius") != nil ? defaults.double(forKey: "defaultCornerRadius") : 10.0)
        self.usePercentageScaling = defaults.object(forKey: "usePercentageScaling") != nil ? defaults.bool(forKey: "usePercentageScaling") : true
        self.defaultBackgroundType = BackgroundType(rawValue: defaults.string(forKey: "defaultBackgroundType") ?? "") ?? .gradient
        self.defaultGradientIndex = defaults.object(forKey: "defaultGradientIndex") != nil ? defaults.integer(forKey: "defaultGradientIndex") : 0

        if let colorData = defaults.data(forKey: "defaultSolidColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            self.defaultSolidColor = color
        } else {
            self.defaultSolidColor = .white
        }

        self.defaultIsCustomGradient = defaults.bool(forKey: "defaultIsCustomGradient")

        if let data = defaults.data(forKey: "defaultCustomGradientStart"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            self.defaultCustomGradientStart = color
        } else {
            self.defaultCustomGradientStart = NSColor(red: 0.5, green: 0.0, blue: 1.0, alpha: 1)
        }

        if let data = defaults.data(forKey: "defaultCustomGradientEnd"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            self.defaultCustomGradientEnd = color
        } else {
            self.defaultCustomGradientEnd = NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1)
        }

        self.overlayDimOpacity = defaults.object(forKey: "overlayDimOpacity") != nil ? defaults.double(forKey: "overlayDimOpacity") : 35.0
        if let colorData = defaults.data(forKey: "overlayHighlightColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            self.overlayHighlightColor = color
        } else {
            self.overlayHighlightColor = .systemBlue
        }
        self.overlayHighlightOpacity = defaults.object(forKey: "overlayHighlightOpacity") != nil ? defaults.double(forKey: "overlayHighlightOpacity") : 22.0

        self.historyLimit = defaults.object(forKey: "historyLimit") != nil ? defaults.integer(forKey: "historyLimit") : 500
        self.showInMenuBar = defaults.object(forKey: "showInMenuBar") != nil ? defaults.bool(forKey: "showInMenuBar") : true
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
    }

    // MARK: - Hotkey Serialization

    private func save(_ key: String, _ binding: HotkeyBinding) {
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(_ key: String) -> HotkeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    // MARK: - Beautification Convenience

    func defaultBeautificationSettings() -> BeautificationSettings {
        BeautificationSettings(
            padding: defaultPadding,
            backgroundType: defaultBackgroundType,
            gradientIndex: defaultGradientIndex,
            solidColor: defaultSolidColor,
            shadowIntensity: defaultShadowIntensity,
            shadowDirection: defaultShadowDirection,
            cornerRadius: defaultCornerRadius,
            inset: defaultInset,
            autoBalance: defaultAutoBalance,
            isCustomGradient: defaultIsCustomGradient,
            customGradientStart: defaultCustomGradientStart,
            customGradientEnd: defaultCustomGradientEnd,
            usePercentage: usePercentageScaling
        )
    }

    // MARK: - Login Item

    private func updateLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
            }
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        fullScreenHotkey = Self.defaultFullScreenHotkey
        selectionHotkey = Self.defaultSelectionHotkey

        showPreviewAfterCapture = true
        quickCaptureAction = .clipboard
        toastPosition = .topRight

        defaultFormat = .png
        filenameTemplate = "Flare {date} at {time}"
        autoSaveEnabled = false
        jpgQuality = 0.9
        saveFolderURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        defaultPadding = 40.0
        defaultShadowIntensity = 50.0
        defaultShadowDirection = .bottomRight
        defaultInset = 0.0
        defaultAutoBalance = false
        defaultCornerRadius = 10.0
        usePercentageScaling = true
        defaultBackgroundType = .gradient
        defaultGradientIndex = 0
        defaultSolidColor = .white
        defaultIsCustomGradient = false
        defaultCustomGradientStart = NSColor(red: 0.5, green: 0.0, blue: 1.0, alpha: 1)
        defaultCustomGradientEnd = NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1)
        overlayDimOpacity = 35.0
        overlayHighlightColor = .systemBlue
        overlayHighlightOpacity = 22.0
        historyLimit = 500
        showInMenuBar = true
        launchAtLogin = false
    }
}
