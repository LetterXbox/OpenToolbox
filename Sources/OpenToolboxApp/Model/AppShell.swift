import AppKit
import Carbon.HIToolbox
import Observation
import OpenToolboxCore
import ServiceManagement
import UserNotifications

/// Whether the app runs from an `.app` bundle. Notifications and login items need one,
/// and a bare `swift run` executable has none.
@MainActor
let isRunningFromAppBundle = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static let quickOpenLabel = "⌃⌥K"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    var isRegistered: Bool { hotKey != nil }

    /// Registers ⌃⌥K. Returns `false` when another app already holds it.
    func register() -> Bool {
        guard hotKey == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &eventType, context, &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: OSType(0x4F54_424B), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            hotKey = nil
            unregister()
            return false
        }
        return true
    }

    fileprivate func fire() {
        action()
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}

private func hotKeyPressed(_: EventHandlerCallRef?, _: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}

/// Opening OpenToolbox when you log in, through the system's login items.
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = false
    private(set) var needsApproval = false
    private(set) var error: String?
    let isSupported = isRunningFromAppBundle

    func refresh() {
        guard isSupported else { return }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported else { return }
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Posts a notification when a tool finishes work the user isn't looking at.
@MainActor
final class ToolNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((ToolID) -> Void)?

    private var center: UNUserNotificationCenter? {
        isRunningFromAppBundle ? .current() : nil
    }

    func start() {
        center?.delegate = self
    }

    func announce(_ tool: ToolDescriptor) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L("\(tool.localizedTitle) finished")
        content.body = L("Open OpenToolbox to see the result.")
        content.userInfo = ["tool": tool.id]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tool = response.notification.request.content.userInfo["tool"] as? String
        Task { @MainActor in
            if let tool { self.onOpen?(tool) }
        }
        completionHandler()
    }
}
