import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var coordinator: AppCoordinator!
    private var recentThumbnailCache: NSImage?
    private var recentItemTimestamp: Date?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Re-apply after a short delay to override any SwiftUI scene activation
        DispatchQueue.main.async {
            if self.coordinator?.openWindowCount == 0 {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        coordinator = AppCoordinator()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Flare")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        coordinator.statusItem = statusItem
        statusItem.isVisible = coordinator.settingsStore.showInMenuBar

        coordinator.settingsStore.$showInMenuBar
            .dropFirst()
            .sink { [weak self] visible in
                self?.statusItem.isVisible = visible
                if !visible {
                    // Open settings once so the user knows how to get back
                    self?.coordinator.showSettings()
                }
            }
            .store(in: &cancellables)

        coordinator.setup()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let store = coordinator.settingsStore

        let fullScreenItem = NSMenuItem(
            title: "Capture Full Screen",
            action: #selector(captureFullScreen), keyEquivalent: ""
        )
        fullScreenItem.target = self
        applyHotkey(store.fullScreenHotkey, to: fullScreenItem)
        menu.addItem(fullScreenItem)

        let selectionItem = NSMenuItem(
            title: "Capture Selection",
            action: #selector(captureSelection), keyEquivalent: ""
        )
        selectionItem.target = self
        applyHotkey(store.selectionHotkey, to: selectionItem)
        menu.addItem(selectionItem)

        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Flare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    private func applyHotkey(_ binding: SettingsStore.HotkeyBinding, to item: NSMenuItem) {
        let keyMap: [UInt32: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        ]
        guard let key = keyMap[binding.keyCode] else { return }
        item.keyEquivalent = key

        var mods: NSEvent.ModifierFlags = []
        if binding.modifiers & 0x0100 != 0 { mods.insert(.command) }
        if binding.modifiers & 0x0200 != 0 { mods.insert(.shift) }
        if binding.modifiers & 0x0800 != 0 { mods.insert(.option) }
        if binding.modifiers & 0x1000 != 0 { mods.insert(.control) }
        item.keyEquivalentModifierMask = mods
    }

    func rebuildMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let recentTag = 999
        // Remove old recent item if present
        if let existing = menu.item(withTag: recentTag) {
            menu.removeItem(existing)
        }
        // Remove the separator before it (tagged 998)
        if let sep = menu.item(withTag: 998) {
            menu.removeItem(sep)
        }

        guard let recent = coordinator.historyStore.items.first else { return }

        // Check if cached thumbnail is still valid
        if recentItemTimestamp != recent.timestamp {
            recentThumbnailCache = nil
            recentItemTimestamp = recent.timestamp
            if let fullImage = coordinator.historyStore.loadImage(for: recent) {
                let maxH: CGFloat = 36
                guard fullImage.size.width > 0, fullImage.size.height > 0 else { return }
                let aspect = fullImage.size.width / fullImage.size.height
                let thumbSize = NSSize(width: maxH * aspect, height: maxH)
                let thumb = NSImage(size: thumbSize, flipped: false) { rect in
                    fullImage.draw(in: rect, from: NSRect(origin: .zero, size: fullImage.size),
                                  operation: .copy, fraction: 1.0)
                    return true
                }
                recentThumbnailCache = thumb
            }
        }

        // Insert separator + recent item before the History item
        let historyIndex = menu.indexOfItem(withTitle: "History\u{2026}")
        guard historyIndex >= 0 else { return }

        let separator = NSMenuItem.separator()
        separator.tag = 998
        menu.insertItem(separator, at: historyIndex)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        let title = "Recent: \(formatter.string(from: recent.timestamp))"

        let recentItem = NSMenuItem(title: title, action: #selector(copyRecentCapture), keyEquivalent: "")
        recentItem.target = self
        recentItem.tag = recentTag
        recentItem.image = recentThumbnailCache
        menu.insertItem(recentItem, at: historyIndex + 1)
    }

    @objc private func copyRecentCapture() {
        guard let recent = coordinator.historyStore.items.first,
              let image = coordinator.historyStore.loadImage(for: recent) else { return }
        coordinator.outputEngine.copyToClipboard(image)
        coordinator.showToast(thumbnail: image, originalImage: image)
    }

    // MARK: - Menu Actions

    @objc private func captureFullScreen() {
        coordinator.startCapture(mode: .fullScreen)
    }

    @objc private func captureSelection() {
        coordinator.startCapture(mode: .selection)
    }

    @objc private func showHistory() {
        coordinator.showHistory()
    }

    @objc private func showSettings() {
        coordinator.showSettings()
    }
}
