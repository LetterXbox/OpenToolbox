import AppKit
import OpenToolboxCore
import SwiftUI

@main
struct OpenToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(L("OpenToolbox")) {
            RootView()
                .environment(model)
                .environment(appDelegate.updates)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updates: appDelegate.updates)
            }
            SidebarCommands()
            CommandMenu(L("Tools")) {
                Button(L("Quick Open…")) {
                    model.isCommandPaletteVisible.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button(L("Tool Catalog")) { model.selection = .catalog }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button(L("Engines")) { model.selection = .engines }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
            }
        }

        Window(L("Software Update"), id: SoftwareUpdateWindow.id) {
            SoftwareUpdateView()
                .environment(appDelegate.updates)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
                .environment(appDelegate.updates)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updates = UpdateCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) so the
        // app gets a Dock icon, a menu bar, and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.installOnQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
