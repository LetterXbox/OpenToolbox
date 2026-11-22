import AppKit
import OpenToolboxCore
import SwiftUI

/// The menu shown from OpenToolbox's menu bar icon.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateCenter.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(L("Open OpenToolbox")) { model.showWindow() }
        Button(L("Quick Open…")) { model.showQuickOpen() }
            .keyboardShortcut("k", modifiers: .command)

        Divider()

        ForEach(model.sidebarSections) { section in
            Menu(section.category.localizedTitle) {
                ForEach(section.tools) { tool in
                    Button {
                        model.show(.tool(tool.id))
                    } label: {
                        Label(tool.localizedTitle, systemImage: tool.symbolName)
                    }
                }
            }
        }

        Divider()

        if case .ready(let prepared) = updates.phase {
            Button(L("Restart to Update to \(prepared.version.description)")) { updates.restartNow() }
        }
        Button(L("Check for Updates…")) {
            NSApp.activate()
            openWindow(id: SoftwareUpdateWindow.id)
            updates.checkNow(userInitiated: true)
        }
        .disabled(updates.isBusy)
        Button(L("Settings…")) {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(L("Quit OpenToolbox")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
