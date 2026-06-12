import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted when the system-wide summon hotkey fires.
    static let bwSummon = Notification.Name("bwSummon")
}

/// System-wide ⌥⌘B: bring Buildwright forward and open Mission Control —
/// the glance gesture from anywhere. Carbon RegisterEventHotKey needs no
/// accessibility permission (unlike CGEventTap / NSEvent global monitors).
enum GlobalHotkey {
    private static var hotKeyRef: EventHotKeyRef?

    static func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .bwSummon, object: nil)
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x42_57_48_4B) /* "BWHK" */, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef)
    }
}
