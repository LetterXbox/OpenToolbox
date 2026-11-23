import AppKit
import OpenToolboxCore
import SwiftUI

@main
struct OpenToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model
        WindowGroup(L("OpenToolbox"), id: MainWindow.id) {
            RootView()
                .environment(model)
                .environment(appDelegate.updates)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updates: appDelegate.updates)
            }
            CommandGroup(replacing: .appSettings) {
                SettingsButton()
            }
            SidebarCommands()
            ImportFromDevicesCommands()
            ToolsCommands(model: model)
        }

        Window(L("Software Update"), id: SoftwareUpdateWindow.id) {
            SoftwareUpdateView()
                .environment(appDelegate.updates)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window(L("OpenToolbox Settings"), id: SettingsWindow.id) {
            SettingsView()
                .environment(model)
                .environment(appDelegate.updates)
        }
        .defaultSize(width: 600, height: 640)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        MenuBarExtra(
            isInserted: Binding(get: { model.showsMenuBarExtra }, set: { model.showsMenuBarExtra = $0 })
        ) {
            MenuBarMenu()
                .environment(model)
                .environment(appDelegate.updates)
        } label: {
            MenuBarLabel(updates: appDelegate.updates)
        }
    }
}

enum MainWindow {
    static let id = "main"
}

struct ToolsCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowModel) private var window

    var body: some Commands {
        CommandMenu(L("Tools")) {
            Button(L("Quick Open…")) {
                if let window {
                    window.isCommandPaletteVisible.toggle()
                } else {
                    model.showQuickOpen()
                }
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button(L("Tool Catalog")) { model.show(.catalog) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button(L("Engines")) { model.show(.engines) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updates = UpdateCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) so the
        // app gets a Dock icon, a menu bar, and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        model.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RecordingSessions.isRecording else { return .terminateNow }
        Task {
            let finished = await RecordingSessions.stopAll()
            if !finished { updates.cancelRelaunch() }
            sender.reply(toApplicationShouldTerminate: finished)
            if !finished {
                let alert = NSAlert()
                alert.messageText = L("A recording is still being saved")
                alert.informativeText = L("OpenToolbox didn't quit so the recording isn't lost. Try quitting again in a moment.")
                alert.runModal()
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.installOnQuit()
        updates.relaunchAfterQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.showsMenuBarExtra
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, model.hasOpenWindow {
            model.showWindow()
            return false
        }
        return true
    }
}
