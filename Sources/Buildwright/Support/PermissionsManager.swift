import AppKit
import ApplicationServices

/// macOS won't let an app approve its own privacy (TCC) prompts — that's the
/// sandbox's whole point. What it CAN do is check the current grant and
/// *trigger the prompt on demand*, so you authorize on your terms (e.g.
/// before going AFK) instead of being interrupted mid-run by something a
/// Claude pane or the CVR docker kicked off.
///
/// Persistence across app updates is the other half: TCC keys grants to the
/// app's code signature, so a stable signing identity (see
/// Scripts/make-signing-cert.sh) is what makes a one-time "Allow" stick. An
/// ad-hoc signature changes every rebuild and silently resets every grant.
enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
    case unknown   // target not running / couldn't tell

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied — open Settings"
        case .notDetermined: return "Not yet asked"
        case .unknown: return "Unknown"
        }
    }

    var ok: Bool { self == .granted }
}

@MainActor
final class PermissionsManager: ObservableObject {
    /// Apple Events → System Events: the "access data from other apps" prompt.
    @Published var automation: PermissionState = .unknown
    @Published var accessibility: PermissionState = .unknown

    static let systemEventsBundleID = "com.apple.systemevents"

    func refresh() {
        automation = Self.automationState(bundleID: Self.systemEventsBundleID)
        // Accessibility has no "not determined" — it's trusted or it isn't.
        accessibility = AXIsProcessTrusted() ? .granted : .denied
    }

    // MARK: Automation (Apple Events)

    /// Query without prompting (`askUserIfNeeded` = false).
    static func automationState(bundleID: String) -> PermissionState {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown // procNotFound (-600): System Events not running yet
        }
    }

    /// Fire the actual consent prompt (`askUserIfNeeded` = true). Runs off the
    /// main thread because the call blocks until the user answers.
    func primeAutomation() {
        let bundleID = Self.systemEventsBundleID
        DispatchQueue.global(qos: .userInitiated).async {
            if let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc {
                _ = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, true)
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    // MARK: Accessibility

    /// Show the system prompt pointing at Settings → Accessibility.
    func primeAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // The toggle happens in Settings; re-check shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    // MARK: Notifications

    func sendTestNotification() {
        ShellExec.notify(title: "Buildwright", body: "Notifications are working — you'll get AFK pings here.")
    }

    // MARK: Open the right Settings pane

    func openAutomationSettings() { open("Privacy_Automation") }
    func openAccessibilitySettings() { open("Privacy_Accessibility") }
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
