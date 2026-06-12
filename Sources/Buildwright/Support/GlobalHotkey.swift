import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted when the system-wide summon hotkey fires.
    static let bwSummon = Notification.Name("bwSummon")
    /// Posted by the system-wide quick-capture hotkey (⌥⌘I).
    static let bwCapture = Notification.Name("bwCapture")
}

/// System-wide ⌥⌘B: bring Buildwright forward and open Mission Control —
/// the glance gesture from anywhere. Carbon RegisterEventHotKey needs no
/// accessibility permission (unlike CGEventTap / NSEvent global monitors).
enum GlobalHotkey {
    private static var summonRef: EventHotKeyRef?
    private static var captureRef: EventHotKeyRef?

    static func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let which = hkID.id
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: which == 2 ? .bwCapture : .bwSummon, object: nil)
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let sig = OSType(0x42_57_48_4B) /* "BWHK" */
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey),
                            EventHotKeyID(signature: sig, id: 1),
                            GetEventDispatcherTarget(), 0, &summonRef)
        // ⌥⌘I — capture a thought from anywhere into the board's inbox.
        RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(cmdKey | optionKey),
                            EventHotKeyID(signature: sig, id: 2),
                            GetEventDispatcherTarget(), 0, &captureRef)
    }
}
