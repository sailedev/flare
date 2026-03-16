import SwiftUI

struct EditorView: View {
    static let imagePadding: CGFloat = 20

    @ObservedObject var viewModel: EditorViewModel

    @State private var showDiscardConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            annotationToolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            HStack(spacing: 0) {
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                beautificationSidebar
                    .frame(width: 220)
            }

            Divider()

            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 560)
        .onAppear {
            viewModel.updateEstimatedFileSize()
        }
        .focusable()
        .onKeyPress { keyPress in
            if keyPress.characters == "c" && keyPress.modifiers.contains(.command) {
                if !viewModel.selectedOCRText.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.selectedOCRText, forType: .string)
                    return .handled
                }
                viewModel.copyToClipboard()
                return .handled
            }
            if keyPress.key == .delete || keyPress.characters == "\u{7F}" {
                if viewModel.selectedAnnotationIndex != nil {
                    viewModel.deleteSelectedAnnotation()
                    return .handled
                }
            }
            return .ignored
        }
        .alert("Discard Changes?", isPresented: $showDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                viewModel.discard()
            }
        } message: {
            Text("You have unsaved annotations. Are you sure you want to discard?")
        }
    }

    // MARK: - Annotation Toolbar

    private var annotationToolbar: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    viewModel.activeTool = tool
                    if tool != .select { viewModel.selectedAnnotationIndex = nil }
                } label: {
                    Image(systemName: tool.systemImage)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                        .background(viewModel.activeTool == tool ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(tool.rawValue)
            }

            Spacer()

            ColorPicker("", selection: colorBinding)
                .labelsHidden()
                .frame(width: 28, height: 28)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            Button { viewModel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.undoStack.isEmpty)
            .keyboardShortcut("z", modifiers: .command)

            Button { viewModel.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.redoStack.isEmpty)
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: viewModel.annotationStyle.color) },
            set: { viewModel.annotationStyle.color = NSColor($0) }
        )
    }

    // MARK: - Preview Area

    private var previewArea: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            Image(nsImage: viewModel.renderedPreview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(Self.imagePadding)

            AnnotationCanvasView(viewModel: viewModel)

            // Sensitive content warning banner
            if viewModel.showSensitiveWarning {
                VStack {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Sensitive content detected")
                            .font(.callout.bold())
                        Button("Redact All") {
                            viewModel.redactAllSensitive()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        Button {
                            viewModel.showSensitiveWarning = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
                .padding(.top, 12)
            }
        }
    }

    // MARK: - Beautification Sidebar

    private var beautificationSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Padding").font(.headline)
                    Slider(value: $viewModel.beautificationSettings.padding,
                           in: 0...(viewModel.beautificationSettings.usePercentage ? 25 : 100), step: 1)
                    Text("\(Int(viewModel.beautificationSettings.padding))\(viewModel.beautificationSettings.usePercentage ? "%" : "px")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Background").font(.headline)
                    Picker("", selection: Binding(
                        get: { viewModel.beautificationSettings.backgroundType },
                        set: { newValue in
                            DispatchQueue.main.async { viewModel.beautificationSettings.backgroundType = newValue }
                        }
                    )) {
                        Text("Gradient").tag(SettingsStore.BackgroundType.gradient)
                        Text("Solid").tag(SettingsStore.BackgroundType.solid)
                        Text("None").tag(SettingsStore.BackgroundType.transparent)
                    }
                    .pickerStyle(.segmented)

                    if viewModel.beautificationSettings.backgroundType == .gradient {
                        GradientPickerView(
                            selectedIndex: $viewModel.beautificationSettings.gradientIndex,
                            isCustom: $viewModel.beautificationSettings.isCustomGradient,
                            customStart: $viewModel.beautificationSettings.customGradientStart,
                            customEnd: $viewModel.beautificationSettings.customGradientEnd
                        )
                    } else if viewModel.beautificationSettings.backgroundType == .solid {
                        ColorPicker("Color", selection: solidColorBinding)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Inset").font(.headline)
                        Spacer()
                        Toggle("Balance", isOn: $viewModel.beautificationSettings.autoBalance)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                    }
                    Slider(value: $viewModel.beautificationSettings.inset,
                           in: 0...(viewModel.beautificationSettings.usePercentage ? 25 : 100), step: 1)
                    Text("\(Int(viewModel.beautificationSettings.inset))\(viewModel.beautificationSettings.usePercentage ? "%" : "px")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Shadow").font(.headline)
                    Slider(value: $viewModel.beautificationSettings.shadowIntensity, in: 0...100, step: 1)
                    Text("\(Int(viewModel.beautificationSettings.shadowIntensity))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if viewModel.beautificationSettings.shadowEnabled {
                        Picker("Direction", selection: $viewModel.beautificationSettings.shadowDirection) {
                            ForEach(ShadowDirection.allCases) { dir in
                                Text(dir.rawValue).tag(dir)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Corner Radius").font(.headline)
                    Slider(value: $viewModel.beautificationSettings.cornerRadius,
                           in: 0...(viewModel.beautificationSettings.usePercentage ? 15 : 50), step: 1)
                    Text("\(Int(viewModel.beautificationSettings.cornerRadius))\(viewModel.beautificationSettings.usePercentage ? "%" : "px")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Aspect Ratio").font(.headline)
                    Picker("", selection: $viewModel.beautificationSettings.exportPreset) {
                        ForEach(ExportPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Export Scale").font(.headline)
                    Picker("", selection: $viewModel.beautificationSettings.exportScale) {
                        Text("1x").tag(1.0)
                        Text("2x (Retina)").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(16)
        }
    }

    private var solidColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: viewModel.beautificationSettings.solidColor) },
            set: { viewModel.beautificationSettings.solidColor = NSColor($0) }
        )
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Button("Discard") {
                if viewModel.annotations.isEmpty {
                    viewModel.discard()
                } else {
                    showDiscardConfirmation = true
                }
            }
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            if viewModel.settingsStore.defaultFormat == .jpg {
                HStack(spacing: 4) {
                    Text("Quality")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: Binding(
                        get: { viewModel.settingsStore.jpgQuality },
                        set: { viewModel.settingsStore.jpgQuality = $0; viewModel.updateEstimatedFileSize() }
                    ), in: 0.1...1.0, step: 0.05)
                    .frame(width: 80)
                    Text("\(Int(viewModel.settingsStore.jpgQuality * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 32)
                }
            }

            if !viewModel.estimatedFileSize.isEmpty {
                Text(viewModel.estimatedFileSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("Save As…") {
                viewModel.saveAs()
            }

            Button("Save") {
                viewModel.save()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Copy") {
                viewModel.copyToClipboard()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}



/// Grid of gradient preset swatches + a "Custom" option with two color pickers.
struct GradientPickerView: View {
    @Binding var selectedIndex: Int
    @Binding var isCustom: Bool
    @Binding var customStart: NSColor
    @Binding var customEnd: NSColor

    let columns = Array(repeating: GridItem(.fixed(36), spacing: 6), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<GradientPreset.presets.count, id: \.self) { index in
                    let preset = GradientPreset.presets[index]
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(
                            colors: [Color(nsColor: preset.startColor), Color(nsColor: preset.endColor)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(!isCustom && selectedIndex == index ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture {
                            isCustom = false
                            selectedIndex = index
                        }
                }

                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [Color(nsColor: customStart), Color(nsColor: customEnd)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isCustom ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .overlay(
                        Image(systemName: "paintbrush.pointed")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    )
                    .onTapGesture { isCustom = true }
            }

            if isCustom {
                HStack(spacing: 12) {
                    ColorPicker("Start", selection: customStartBinding)
                    ColorPicker("End", selection: customEndBinding)
                }
                .font(.caption)
            }
        }
    }

    private var customStartBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: customStart) },
            set: { customStart = NSColor($0) }
        )
    }

    private var customEndBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: customEnd) },
            set: { customEnd = NSColor($0) }
        )
    }
}
