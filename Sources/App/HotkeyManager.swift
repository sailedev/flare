import Carbon
import AppKit

final class HotkeyManager {
    private var registeredHotkeys: [EventHotKeyRef] = []
    private static var handler: ((CaptureMode) -> Void)?
    private static var hotKeyEventHandler: EventHandlerRef?

    func register(settingsStore: SettingsStore, handler: @escaping (CaptureMode) -> Void) {
        Self.handler = handler
        installCarbonHandler()

        var conflicts = Set<String>()

        let bindings: [(SettingsStore.HotkeyBinding, UInt32, CaptureMode)] = [
            (settingsStore.fullScreenHotkey, 1, .fullScreen),
            (settingsStore.selectionHotkey, 2, .selection),
        ]

        for (binding, id, mode) in bindings {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: fourCharCode("SCRN"), id: id)
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let ref = hotKeyRef {
                registeredHotkeys.append(ref)
            } else {
                conflicts.insert(mode.rawValue)
            }
        }

        settingsStore.hotkeyConflicts = conflicts
    }

    func unregisterAll() {
        for ref in registeredHotkeys {
            UnregisterEventHotKey(ref)
        }
        registeredHotkeys.removeAll()
    }

    private func installCarbonHandler() {
        guard Self.hotKeyEventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
                autoreleasepool {
                    guard let event = event else { return }

                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )

                    let mode: CaptureMode
                    switch hotKeyID.id {
                    case 1: mode = .fullScreen
                    case 2: mode = .selection
                    default: return
                    }

                    HotkeyManager.handler?(mode)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &Self.hotKeyEventHandler
        )
    }

    private func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + OSType(char)
        }
        return result
    }

    deinit {
        unregisterAll()
    }
}
