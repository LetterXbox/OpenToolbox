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
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
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

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) so the
        // app gets a Dock icon, a menu bar, and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
