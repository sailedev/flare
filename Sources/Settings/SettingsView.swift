import SwiftUI
import Carbon.HIToolbox

// MARK: - Settings Navigation

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case overlay = "Overlay"
    case output = "Output"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .appearance: return "paintbrush"
        case .overlay: return "rectangle.dashed"
        case .output: return "square.and.arrow.down"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    weak var coordinator: AppCoordinator?

    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            Divider()

            ScrollView {
                detailContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .frame(minWidth: 600, minHeight: 440)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .general:
            GeneralPane(settingsStore: settingsStore, coordinator: coordinator)
        case .appearance:
            AppearancePane(settingsStore: settingsStore)
        case .overlay:
            OverlayPane(settingsStore: settingsStore)
        case .output:
            OutputPane(settingsStore: settingsStore, coordinator: coordinator)
        }
    }
}

// MARK: - General Pane

private struct GeneralPane: View {
    @ObservedObject var settingsStore: SettingsStore
    weak var coordinator: AppCoordinator?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Shortcuts
            SectionHeader("Capture Shortcuts")

            VStack(spacing: 12) {
                HotkeyRecorderRow(
                    label: "Full Screen",
                    binding: $settingsStore.fullScreenHotkey,
                    hasConflict: settingsStore.hotkeyConflicts.contains(CaptureMode.fullScreen.rawValue)
                )
                HotkeyRecorderRow(
                    label: "Selection",
                    binding: $settingsStore.selectionHotkey,
                    hasConflict: settingsStore.hotkeyConflicts.contains(CaptureMode.selection.rawValue)
                )
            }
            .onChange(of: settingsStore.fullScreenHotkey) { coordinator?.reloadHotkeys() }
            .onChange(of: settingsStore.selectionHotkey) { coordinator?.reloadHotkeys() }

            Divider()

            // After Capture
            SectionHeader("After Capture")

            Toggle("Show preview window after capture", isOn: $settingsStore.showPreviewAfterCapture)

            if !settingsStore.showPreviewAfterCapture {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Captures will use your default appearance settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Action", selection: $settingsStore.quickCaptureAction) {
                        ForEach(SettingsStore.QuickCaptureAction.allCases, id: \.self) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if settingsStore.quickCaptureAction == .saveToFile || settingsStore.quickCaptureAction == .both {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundColor(.secondary)
                            Text(settingsStore.saveFolderURL?.lastPathComponent ?? "Not set")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                    }

                    Picker("Toast position", selection: $settingsStore.toastPosition) {
                        ForEach(SettingsStore.ToastPosition.allCases, id: \.self) { pos in
                            Text(pos.rawValue).tag(pos)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }
                .padding(.leading, 20)
            }

            Divider()

            // Startup
            SectionHeader("Startup")

            Toggle("Launch at Login", isOn: $settingsStore.launchAtLogin)

            Toggle("Show in menu bar", isOn: $settingsStore.showInMenuBar)

            if !settingsStore.showInMenuBar {
                Text("You can still access Settings via the gear icon on the preview popup or via hotkeys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            Divider()

            // Reset
            HStack {
                Spacer()
                Button("Reset All Settings to Defaults", role: .destructive) {
                    settingsStore.resetToDefaults()
                    coordinator?.reloadHotkeys()
                }
                .foregroundColor(.red)
            }
        }
    }
}

// MARK: - Overlay Pane

private struct OverlayPane: View {
    @ObservedObject var settingsStore: SettingsStore

    private var highlightColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: settingsStore.overlayHighlightColor) },
            set: { settingsStore.overlayHighlightColor = NSColor($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader("Selection Overlay")

            Text("These settings control how the screen looks when selecting a region or window to capture.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 16) {
                SettingsRow("Dimming") {
                    Slider(value: $settingsStore.overlayDimOpacity, in: 0...80, step: 1)
                    Text("\(Int(settingsStore.overlayDimOpacity))%")
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                }

                SettingsRow("Color") {
                    ColorPicker("", selection: highlightColorBinding)
                        .labelsHidden()
                    Spacer()
                }

                SettingsRow("Highlight") {
                    Slider(value: $settingsStore.overlayHighlightOpacity, in: 0...60, step: 1)
                    Text("\(Int(settingsStore.overlayHighlightOpacity))%")
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Appearance Pane

private struct AppearancePane: View {
    @ObservedObject var settingsStore: SettingsStore

    /// Sample image for live preview — generated once.
    private let sampleImage: NSImage = Self.generateSampleImage()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Live preview
            SectionHeader("Preview")

            livePreview
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Divider()

            // Settings
            SectionHeader("Default Beautification")

            VStack(spacing: 16) {
                SettingsRow("Units") {
                    Picker("", selection: Binding(
                        get: { settingsStore.usePercentageScaling },
                        set: { newValue in
                            DispatchQueue.main.async {
                                settingsStore.usePercentageScaling = newValue
                                if newValue {
                                    settingsStore.defaultPadding = min(settingsStore.defaultPadding, 25)
                                    settingsStore.defaultInset = min(settingsStore.defaultInset, 25)
                                    settingsStore.defaultCornerRadius = min(settingsStore.defaultCornerRadius, 15)
                                }
                            }
                        }
                    )) {
                        Text("px").tag(false)
                        Text("%").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                    Spacer()
                }

                SettingsRow("Padding") {
                    Slider(value: $settingsStore.defaultPadding,
                           in: 0...(settingsStore.usePercentageScaling ? 25 : 100), step: 1)
                    Text("\(Int(settingsStore.defaultPadding))\(settingsStore.usePercentageScaling ? "%" : "px")")
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                }

                // Background
                SettingsRow("Background") {
                    Picker("", selection: Binding(
                        get: { settingsStore.defaultBackgroundType },
                        set: { newValue in
                            DispatchQueue.main.async { settingsStore.defaultBackgroundType = newValue }
                        }
                    )) {
                        Text("Gradient").tag(SettingsStore.BackgroundType.gradient)
                        Text("Solid").tag(SettingsStore.BackgroundType.solid)
                        Text("None").tag(SettingsStore.BackgroundType.transparent)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Gradient picker
                if settingsStore.defaultBackgroundType == .gradient {
                    GradientPickerView(
                        selectedIndex: $settingsStore.defaultGradientIndex,
                        isCustom: $settingsStore.defaultIsCustomGradient,
                        customStart: $settingsStore.defaultCustomGradientStart,
                        customEnd: $settingsStore.defaultCustomGradientEnd
                    )
                    .padding(.leading, 88)
                }

                // Solid color picker
                if settingsStore.defaultBackgroundType == .solid {
                    SettingsRow("Color") {
                        ColorPicker("", selection: solidColorBinding)
                            .labelsHidden()
                        Spacer()
                    }
                }

                // Inset
                SettingsRow("Inset") {
                    Slider(value: $settingsStore.defaultInset,
                           in: 0...(settingsStore.usePercentageScaling ? 25 : 100), step: 1)
                    Text("\(Int(settingsStore.defaultInset))\(settingsStore.usePercentageScaling ? "%" : "px")")
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                    Toggle("Balance", isOn: $settingsStore.defaultAutoBalance)
                        .toggleStyle(.checkbox)
                }

                // Shadow
                SettingsRow("Shadow") {
                    Slider(value: $settingsStore.defaultShadowIntensity, in: 0...100, step: 1)
                    Text("\(Int(settingsStore.defaultShadowIntensity))%")
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                }

                if settingsStore.defaultShadowIntensity > 0 {
                    SettingsRow("Direction") {
                        Picker("", selection: $settingsStore.defaultShadowDirection) {
                            ForEach(ShadowDirection.allCases) { dir in
                                Text(dir.rawValue).tag(dir)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }

                // Corner Radius
                SettingsRow("Corners") {
                    Slider(value: $settingsStore.defaultCornerRadius,
                           in: 0...(settingsStore.usePercentageScaling ? 15 : 50), step: 1)
                    Text("\(Int(settingsStore.defaultCornerRadius))\(settingsStore.usePercentageScaling ? "%" : "px")")
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
    }

    private var solidColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: settingsStore.defaultSolidColor) },
            set: { settingsStore.defaultSolidColor = NSColor($0) }
        )
    }

    private var livePreview: some View {
        let settings = settingsStore.defaultBeautificationSettings()
        let rendered = BeautificationEngine.render(screenshot: sampleImage, settings: settings)
        return Image(nsImage: rendered)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(12)
    }

    /// Generates a simple sample screenshot for the live preview.
    private static func generateSampleImage() -> NSImage {
        let size = NSSize(width: 640, height: 400)
        let image = NSImage(size: size)
        image.lockFocus()

        // Window-like appearance
        let bgColor = NSColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)
        bgColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Title bar
        let titleBarColor = NSColor(red: 0.22, green: 0.22, blue: 0.25, alpha: 1)
        titleBarColor.setFill()
        NSRect(x: 0, y: size.height - 32, width: size.width, height: 32).fill()

        // Traffic lights
        let dotY = size.height - 20
        NSColor(red: 1.0, green: 0.38, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: dotY, width: 10, height: 10)).fill()
        NSColor(red: 1.0, green: 0.74, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 28, y: dotY, width: 10, height: 10)).fill()
        NSColor(red: 0.35, green: 0.78, blue: 0.29, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 44, y: dotY, width: 10, height: 10)).fill()

        // Some fake content lines
        let lineColor = NSColor(red: 0.35, green: 0.35, blue: 0.40, alpha: 1)
        lineColor.setFill()
        for i in 0..<8 {
            let y = size.height - 60 - CGFloat(i) * 28
            let width: CGFloat = [400, 300, 520, 280, 460, 350, 420, 240][i]
            NSRect(x: 20, y: y, width: width, height: 8).fill()
        }

        // Accent content
        NSColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1).setFill()
        NSRect(x: 20, y: size.height - 144, width: 200, height: 8).fill()

        image.unlockFocus()
        return image
    }
}

// MARK: - Output Pane

private struct OutputPane: View {
    @ObservedObject var settingsStore: SettingsStore
    weak var coordinator: AppCoordinator?
    @State private var showClearConfirmation = false

    private var filenamePreview: String {
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH.mm.ss"
        let datetimeFmt = DateFormatter()
        datetimeFmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return settingsStore.filenameTemplate
            .replacingOccurrences(of: "{date}", with: dateFmt.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeFmt.string(from: now))
            .replacingOccurrences(of: "{datetime}", with: datetimeFmt.string(from: now))
            .replacingOccurrences(of: "{timestamp}", with: "\(Int(now.timeIntervalSince1970))")
            .replacingOccurrences(of: "{app}", with: "Safari")
            .replacingOccurrences(of: "{mode}", with: "Selection")
        + ".\(settingsStore.defaultFormat.rawValue.lowercased())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Format
            SectionHeader("Format")

            VStack(spacing: 12) {
                SettingsRow("Format") {
                    Picker("", selection: $settingsStore.defaultFormat) {
                        ForEach(SettingsStore.ImageFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if settingsStore.defaultFormat == .jpg {
                    SettingsRow("Quality") {
                        Slider(value: $settingsStore.jpgQuality, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(settingsStore.jpgQuality * 100))%")
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
            }

            Divider()

            SectionHeader("Filename")

            VStack(alignment: .leading, spacing: 8) {
                TextField("Template", text: $settingsStore.filenameTemplate)
                    .textFieldStyle(.roundedBorder)

                Text("Tokens: {date} {time} {datetime} {timestamp} {app} {mode}")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(filenamePreview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            SectionHeader("Auto-Save")

            VStack(spacing: 12) {
                Toggle("Save screenshots to folder automatically", isOn: $settingsStore.autoSaveEnabled)

                if settingsStore.autoSaveEnabled {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundColor(.secondary)
                        Text(settingsStore.saveFolderURL?.lastPathComponent ?? "Not set")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Change...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK {
                                settingsStore.saveFolderURL = panel.url
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }

            Divider()

            // History
            SectionHeader("History")

            VStack(alignment: .leading, spacing: 12) {
                Stepper("Keep up to \(settingsStore.historyLimit) screenshots",
                        value: $settingsStore.historyLimit, in: 10...5000, step: 50)

                Button("Clear All History...", role: .destructive) {
                    showClearConfirmation = true
                }
                .foregroundColor(.red)
            }
        }
        .alert("Clear All History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                coordinator?.historyStore.clearAll()
            }
        } message: {
            Text("This will permanently delete all saved screenshots from history.")
        }
    }
}

// MARK: - Reusable Components

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.callout)
            HStack(spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Hotkey Recorder Row

struct HotkeyRecorderRow: View {
    let label: String
    @Binding var binding: SettingsStore.HotkeyBinding
    var hasConflict: Bool = false
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .frame(width: 80, alignment: .trailing)
                    .foregroundColor(.secondary)
                    .font(.callout)
                Button(isRecording ? "Press shortcut..." : hotkeyDisplayString) {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                .buttonStyle(.bordered)
                .foregroundColor(isRecording ? .accentColor : (hasConflict ? .red : .primary))
                .frame(minWidth: 100)
                Spacer()
            }
            if hasConflict {
                Text("Shortcut conflicts with another app")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 88)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = UInt32(event.keyCode)
            var carbonMods: UInt32 = 0
            let flags = event.modifierFlags

            if flags.contains(.command) { carbonMods |= 0x0100 }
            if flags.contains(.shift) { carbonMods |= 0x0200 }
            if flags.contains(.option) { carbonMods |= 0x0800 }
            if flags.contains(.control) { carbonMods |= 0x1000 }

            // Require at least one modifier (except Escape to cancel)
            if keyCode == 53 { // Escape — cancel recording
                stopRecording()
                return nil
            }

            guard carbonMods != 0 else { return nil } // Ignore bare keys

            binding = SettingsStore.HotkeyBinding(keyCode: keyCode, modifiers: carbonMods)
            stopRecording()
            return nil // Consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private var hotkeyDisplayString: String {
        var parts: [String] = []
        let mods = binding.modifiers
        if mods & 0x1000 != 0 { parts.append("\u{2303}") }  // Control
        if mods & 0x0800 != 0 { parts.append("\u{2325}") }  // Option
        if mods & 0x0200 != 0 { parts.append("\u{21E7}") }  // Shift
        if mods & 0x0100 != 0 { parts.append("\u{2318}") }  // Command
        let keyName = keyCodeToString(binding.keyCode)
        parts.append(keyName)
        return parts.joined()
    }

    private func keyCodeToString(_ keyCode: UInt32) -> String {
        let keyMap: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
            27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
            46: "M", 47: ".",
            49: "Space", 50: "`",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 118: "F4", 120: "F2", 122: "F1",
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        ]
        return keyMap[keyCode] ?? "Key\(keyCode)"
    }
}
