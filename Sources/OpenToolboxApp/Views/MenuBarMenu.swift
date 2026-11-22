import AppKit
import OpenToolboxCore
import SwiftUI

/// The menu shown from OpenToolbox's menu bar icon.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateCenter.self) private var updates
    @Environment(\.openWindow) private var openWindow

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

        switch updates.phase {
        case .ready(let prepared):
            Button(L("Restart to Update to \(prepared.version.description)")) { updates.restartNow() }
        case .available(let update):
            Button(L("OpenToolbox \(update.version.description) Is Available…")) {
                NSApp.activate()
                openWindow(id: SoftwareUpdateWindow.id)
            }
        default:
            EmptyView()
        }
        Button(L("Check for Updates…")) {
            NSApp.activate()
            openWindow(id: SoftwareUpdateWindow.id)
            updates.checkNow(userInitiated: true)
        }
        .disabled(updates.isBusy)
        Button(L("Settings…")) {
            NSApp.activate()
            openWindow(id: SettingsWindow.id)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(L("Quit OpenToolbox")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

struct MenuBarLabel: View {
    let updates: UpdateCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "wrench.and.screwdriver")
            .accessibilityLabel(L("OpenToolbox"))
            .onChange(of: updates.windowRequest) {
                if updates.takeWindowRequest() { openWindow(id: SoftwareUpdateWindow.id) }
            }
    }
}
