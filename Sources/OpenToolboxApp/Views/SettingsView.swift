import AppKit
import OpenToolboxCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateCenter.self) private var updates

    var body: some View {
        Form {
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
