import SwiftUI
import UniformTypeIdentifiers

struct HistoryPanelView: View {
    @ObservedObject var historyStore: HistoryStore
    var onEdit: ((NSImage) -> Void)?

    let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button("Clear All") {
                    showClearConfirmation = true
                }
                .foregroundColor(.red)
            }
            .padding(16)

            Divider()

            if historyStore.items.isEmpty {
                Spacer()
                Text("No screenshots yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(historyStore.items) { item in
                            HistoryThumbnailView(item: item, historyStore: historyStore, onEdit: onEdit)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .alert("Clear All History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                historyStore.clearAll()
            }
        } message: {
            Text("This will permanently delete all screenshots from history. This cannot be undone.")
        }
    }

    @State private var showClearConfirmation = false
}

struct HistoryThumbnailView: View {
    let item: HistoryItem
    @ObservedObject var historyStore: HistoryStore
    var onEdit: ((NSImage) -> Void)?

    @State private var thumbnailImage: NSImage?

    /// Max thumbnail dimension (2x for Retina at 160pt display)
    private static let thumbnailMaxSize: CGFloat = 320

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image = thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(item.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption)
                .foregroundColor(.secondary)

            Text(item.captureMode)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contextMenu {
            Button("Copy") {
                if let image = historyStore.loadImage(for: item) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if let pngData = OutputEngine.encodePNG(from: image) {
                        pasteboard.setData(pngData, forType: .png)
                    }
                }
            }
            Button("Edit...") {
                if let image = historyStore.loadImage(for: item) {
                    onEdit?(image)
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                historyStore.delete(item: item)
            }
        }
        .onDrag {
            let provider = NSItemProvider()
            let itemCopy = item
            let store = historyStore
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                Task.detached {
                    if let image = store.loadImage(for: itemCopy),
                       let data = OutputEngine.encodePNG(from: image) {
                        completion(data, nil)
                    } else {
                        completion(nil, nil)
                    }
                }
                return nil
            }
            return provider
        }
        .onTapGesture(count: 2) {
            if let image = historyStore.loadImage(for: item) {
                onEdit?(image)
            }
        }
        .task(id: item.id) {
            // Load and downscale on a background thread
            guard thumbnailImage == nil else { return }
            let itemCopy = item
            let store = historyStore
            let maxSize = Self.thumbnailMaxSize
            let thumb = await Task.detached(priority: .medium) {
                guard let fullImage = store.loadImage(for: itemCopy) else { return nil as NSImage? }
                return downsampleImage(fullImage, maxDimension: maxSize)
            }.value
            if let thumb {
                thumbnailImage = thumb
            }
        }
    }

}

/// Thread-safe downsampling using CGContext instead of NSImage.lockFocus
/// (which is main-thread-only and crashes from background tasks).
private func downsampleImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
    let size = image.size
    guard size.width > maxDimension || size.height > maxDimension else { return image }

    let scale: CGFloat
    if size.width > size.height {
        scale = maxDimension / size.width
    } else {
        scale = maxDimension / size.height
    }
    let newW = Int(size.width * scale)
    let newH = Int(size.height * scale)
    guard newW > 0, newH > 0,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(
              data: nil, width: newW, height: newH,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ) else { return image }

    ctx.interpolationQuality = .high
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
    guard let scaled = ctx.makeImage() else { return image }
    return NSImage(cgImage: scaled, size: NSSize(width: newW, height: newH))
}
