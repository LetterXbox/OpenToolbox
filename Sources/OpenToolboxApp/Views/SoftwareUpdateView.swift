import AppKit
import OpenToolboxCore
import SwiftUI

enum SoftwareUpdateWindow {
    static let id = "software-update"
}

struct SoftwareUpdateView: View {
    @Environment(UpdateCenter.self) private var updates
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch updates.phase {
        case .idle:
            Text(L("Software Update")).font(.headline)
            currentVersionText
            buttons { Button(L("Check for Updates")) { updates.checkNow(userInitiated: true) }.disabled(!updates.canCheck) }
            if !updates.canCheck {
                Text(L("Updates are available only in the packaged OpenToolbox app."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .checking:
            Text(L("Checking GitHub for updates…")).font(.headline)
            ProgressView().controlSize(.small)
        case .upToDate(let latest):
            Text(L("OpenToolbox is up to date.")).font(.headline)
            Text(updates.upToDateDetail(latest: latest)).foregroundStyle(.secondary)
            buttons { Button(L("OK")) { dismissWindow(id: SoftwareUpdateWindow.id) }.keyboardShortcut(.defaultAction) }
        case .available(let update):
            Text(L("OpenToolbox \(update.version.description) is available.")).font(.headline)
            currentVersionText
            if update.version.isPrerelease {
                Text(L("This is a test build. It may have more bugs than a stable release."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let reason = updates.unsupportedReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            buttons {
                Button(L("Release Notes")) { updates.openReleasePage(for: update) }
                Button(L("Later")) { dismissWindow(id: SoftwareUpdateWindow.id) }
                if updates.canInstall {
                    Button(L("Install Update")) { updates.install(update) }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Download from GitHub")) { updates.openReleasePage(for: update) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .downloading(let update, let fraction):
            Text(L("Downloading OpenToolbox \(update.version.description)…")).font(.headline)
            ProgressView(value: fraction)
            Text(L("The download is checked against its published SHA-256 checksum and code signature."))
                .font(.callout).foregroundStyle(.secondary)
            buttons { Button(L("Cancel")) { updates.cancel() } }
        case .ready(let prepared):
            Text(L("OpenToolbox \(prepared.version.description) is ready to install.")).font(.headline)
            Text(L("Restart now, or it will be installed the next time you quit OpenToolbox."))
                .foregroundStyle(.secondary)
            buttons {
                Button(L("Later")) { dismissWindow(id: SoftwareUpdateWindow.id) }
                Button(L("Restart Now")) { updates.restartNow() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            Text(L("The update check didn't finish.")).font(.headline)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            failureButtons
        case .notInstalled(let message):
            Text(L("The update wasn't installed.")).font(.headline)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            failureButtons
        }
    }

    private var failureButtons: some View {
        buttons {
            Button(L("Open Releases Page")) { updates.openReleasePage(for: nil) }
            Button(L("Try Again")) { updates.checkNow(userInitiated: true) }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var currentVersionText: some View {
        if let current = updates.currentVersion {
            Text(L("You have version \(current.description)."))
                .foregroundStyle(.secondary)
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.top, 4)
    }
}

struct CheckForUpdatesButton: View {
    let updates: UpdateCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Check for Updates…")) {
            openWindow(id: SoftwareUpdateWindow.id)
            updates.checkNow(userInitiated: true)
        }
        .disabled(updates.isBusy)
    }
}
