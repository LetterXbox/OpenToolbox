import AppKit
import OpenToolboxCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateCenter.self) private var updates

    var body: some View {
        Form {
            GeneralSettingsSection(model: model, loginItem: model.loginItem)
            Section(L("Output")) {
                LabeledContent(L("Save results to")) {
                    Text(model.outputBaseDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(L("File tools never overwrite originals. Each run is saved in a dated subfolder."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L("Choose…"), action: chooseOutputDirectory)
                    Button(L("Use Default")) { model.setOutputBaseDirectory(nil) }
                }
            }
            Section(L("Engines")) {
                if let root = model.engines.rootDirectory {
                    LabeledContent(L("Location")) {
                        Text(root.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Text(L("OpenToolbox stays offline unless you start a download or another network action yourself, or turn on automatic update checks."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            UpdateSettingsSection(updates: updates)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url {
            model.setOutputBaseDirectory(url)
        }
    }
}

private struct GeneralSettingsSection: View {
    @Bindable var model: AppModel
    let loginItem: LoginItem

    var body: some View {
        Section(L("General")) {
            Toggle(L("Show OpenToolbox in the menu bar"), isOn: $model.showsMenuBarExtra)
            Text(L("While the menu bar icon is shown, closing the last window keeps OpenToolbox running there."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle(L("Open Quick Open from any app with \(GlobalHotKey.quickOpenLabel)"), isOn: $model.usesQuickOpenHotKey)
            if model.hotKeyUnavailable {
                Text(L("\(GlobalHotKey.quickOpenLabel) is already used by another app."))
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Toggle(
                L("Open OpenToolbox when you log in"),
                isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
            )
            .disabled(!loginItem.isSupported)
            if !loginItem.isSupported {
                Text(L("Available when OpenToolbox runs from its app bundle."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if loginItem.needsApproval {
                HStack {
                    Text(L("Allow OpenToolbox in System Settings → General → Login Items."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(L("Open Login Items")) { loginItem.openSystemSettings() }
                }
            }
            if let error = loginItem.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .onAppear { loginItem.refresh() }
    }
}

private struct UpdateSettingsSection: View {
    @Bindable var updates: UpdateCenter

    var body: some View {
        Section(L("Updates")) {
            Toggle(L("Check for updates automatically"), isOn: $updates.checksAutomatically)
                .disabled(!updates.canCheck)
            Toggle(L("Download and install updates automatically"), isOn: $updates.installsAutomatically)
                .disabled(!updates.checksAutomatically || !updates.canInstall)
            Text(L("When on, OpenToolbox asks GitHub once a day for the latest release. Nothing about you or your files is sent. Downloaded updates are checked against their published SHA-256 checksum and code signature, and install when you restart or quit."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle(L("Include test builds"), isOn: $updates.receivesTestBuilds)
                .disabled(!updates.canCheck)
            Text(L("Test builds are pre-releases for trying new features early, and may have more bugs. When the stable release they lead to comes out, OpenToolbox updates to it. Turning this off doesn't return you to an older stable version."))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let reason = updates.unsupportedReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L("Last checked")) {
                if let lastChecked = updates.lastChecked {
                    Text(lastChecked, format: .dateTime)
                } else {
                    Text(L("Never"))
                }
            }
            HStack {
                Spacer()
                CheckForUpdatesButton(updates: updates)
                    .disabled(!updates.canCheck || updates.isBusy)
            }
        }
    }
}
