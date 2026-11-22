import AppKit
import OpenToolboxCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

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
                Text(L("OpenToolbox stays offline unless you start a download or another network action yourself."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
