import SwiftUI

struct PostCapturePreviewView: View {
    @ObservedObject var viewModel: PostCapturePreviewViewModel

    private var solidColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: viewModel.settings.solidColor) },
            set: { viewModel.settings.solidColor = NSColor($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea

            Divider()

            quickSettings
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            Button("") { viewModel.dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
        .focusable()
        .onKeyPress { keyPress in
            if keyPress.characters == "c" && keyPress.modifiers.contains(.command) {
                if !viewModel.selectedOCRText.isEmpty {
                    // Copy selected text to clipboard (don't dismiss)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.selectedOCRText, forType: .string)
                    return .handled
                }
                // No text selected - copy image
                viewModel.copyToClipboard()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Preview Area

    private var previewArea: some View {
        let layout = BeautificationEngine.contentLayout(
            for: viewModel.originalScreenshot,
            settings: viewModel.settings
        )

        return ZStack {
            Color(nsColor: .controlBackgroundColor)

            Image(nsImage: viewModel.renderedPreview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onDrag {
                    NSItemProvider(object: viewModel.renderedPreview)
                }
                .overlay {
                    SelectableTextOverlay(
                        observations: viewModel.ocrObservations,
                        contentRect: layout.contentRect,
                        canvasSize: layout.canvasSize,
                        selectedText: $viewModel.selectedOCRText
                    )
                }
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Quick Settings

    private var quickSettings: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Padding")
                    .frame(width: 80, alignment: .leading)
                    .font(.callout)
                Slider(value: $viewModel.settings.padding,
                       in: 0...(viewModel.settings.usePercentage ? 25 : 100), step: 1)
                Text("\(Int(viewModel.settings.padding))\(viewModel.settings.usePercentage ? "%" : "px")")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            HStack {
                Text("Background")
                    .frame(width: 80, alignment: .leading)
                    .font(.callout)
                Picker("", selection: Binding(
                    get: { viewModel.settings.backgroundType },
                    set: { newValue in
                        DispatchQueue.main.async { viewModel.settings.backgroundType = newValue }
                    }
                )) {
                    Text("Gradient").tag(SettingsStore.BackgroundType.gradient)
                    Text("Solid").tag(SettingsStore.BackgroundType.solid)
                    Text("None").tag(SettingsStore.BackgroundType.transparent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if viewModel.settings.backgroundType == .gradient {
                HStack {
                    Text("")
                        .frame(width: 80, alignment: .leading)
                    GradientPickerView(
                        selectedIndex: $viewModel.settings.gradientIndex,
                        isCustom: $viewModel.settings.isCustomGradient,
                        customStart: $viewModel.settings.customGradientStart,
                        customEnd: $viewModel.settings.customGradientEnd
                    )
                }
            }

            if viewModel.settings.backgroundType == .solid {
                HStack {
                    Text("")
                        .frame(width: 80, alignment: .leading)
                    ColorPicker("", selection: solidColorBinding)
                        .labelsHidden()
                }
            }

            HStack {
                Text("Aspect")
                    .frame(width: 80, alignment: .leading)
                    .font(.callout)
                HStack(spacing: 6) {
                    ForEach(ExportPreset.allCases) { preset in
                        Button(action: {
                            viewModel.settings.exportPreset = preset
                        }) {
                            Text(preset.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    viewModel.settings.exportPreset == preset
                                        ? Color.accentColor
                                        : Color(nsColor: .controlBackgroundColor)
                                )
                                .foregroundColor(
                                    viewModel.settings.exportPreset == preset
                                        ? .white
                                        : .primary
                                )
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            viewModel.settings.exportPreset == preset
                                                ? Color.clear
                                                : Color(nsColor: .separatorColor),
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Text("Inset")
                    .frame(width: 80, alignment: .leading)
                    .font(.callout)
                Slider(value: $viewModel.settings.inset,
                       in: 0...(viewModel.settings.usePercentage ? 25 : 100), step: 1)
                Text("\(Int(viewModel.settings.inset))\(viewModel.settings.usePercentage ? "%" : "px")")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)

                Toggle("Balance", isOn: $viewModel.settings.autoBalance)
                    .font(.callout)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Text("")
                    .frame(width: 80, alignment: .leading)

                Button {
                    viewModel.toggleBackgroundRemoval()
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isRemovingBackground {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(viewModel.backgroundRemoved ? "Restore Background" : "Remove Background")
                    }
                }
                .disabled(viewModel.isRemovingBackground)

                if let error = viewModel.backgroundRemovalError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            HStack {
                Text("Shadow")
                    .frame(width: 80, alignment: .leading)
                    .font(.callout)
                Slider(value: $viewModel.settings.shadowIntensity, in: 0...100, step: 1)
                Text("\(Int(viewModel.settings.shadowIntensity))%")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            if viewModel.settings.shadowEnabled {
                HStack {
                    Text("")
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $viewModel.settings.shadowDirection) {
                        ForEach(ShadowDirection.allCases) { dir in
                            Text(dir.rawValue).tag(dir)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            HStack {
                Text("Corners")
                    .frame(width: 80, alignment: .leading)
                    .font(.callout)
                Slider(value: $viewModel.settings.cornerRadius,
                       in: 0...(viewModel.settings.usePercentage ? 15 : 50), step: 1)
                Text("\(Int(viewModel.settings.cornerRadius))\(viewModel.settings.usePercentage ? "%" : "px")")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Button("Edit...") {
                viewModel.openEditor()
            }

            Button {
                viewModel.onSettings?()
            } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.borderless)

            Spacer()

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
