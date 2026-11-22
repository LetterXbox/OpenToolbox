import OpenToolboxCore
import SwiftUI

struct PDFPasswordView: View {
    enum Mode: Hashable { case add, remove }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var mode: Mode = .add
    @State private var files: [URL] = []
    @State private var password = ""
    @State private var confirmation = ""
    @State private var ownerPassword = ""
    @State private var allowsPrinting = true
    @State private var allowsCopying = true
    @State private var allowsEditing = true
    @State private var isProcessing = false
    @State private var results: [FileResult] = []

    private var canRun: Bool {
        guard !files.isEmpty, !password.isEmpty, !isProcessing else { return false }
        return mode == .remove || password == confirmation
    }

    var body: some View {
        ToolPage(tool: tool) {
            Picker(L("Action"), selection: $mode) {
                Text(L("Add Password")).tag(Mode.add)
                Text(L("Remove Password")).tag(Mode.remove)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            FileDropList(files: $files, allowedTypes: [.pdf], prompt: L("Drop PDFs here"))
            Form {
                SecureField(mode == .add ? L("Password to open") : L("Password"), text: $password)
                if mode == .add {
                    SecureField(L("Confirm password"), text: $confirmation)
                    if !confirmation.isEmpty, password != confirmation {
                        Text(L("The passwords don't match.")).font(.callout).foregroundStyle(.red)
                    }
                    Section {
                        Toggle(L("Allow printing"), isOn: $allowsPrinting)
                        Toggle(L("Allow copying text and images"), isOn: $allowsCopying)
                        Toggle(L("Allow editing, comments, and form filling"), isOn: $allowsEditing)
                        SecureField(L("Owner password (optional)"), text: $ownerPassword)
                    } footer: {
                        Text(
                            L(
                                "Restrictions apply in apps that honor them. Without an owner password, the password to open also unlocks the restrictions."
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("Enter the password to open the PDF, or its owner password if it only restricts printing or copying."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: mode == .add ? 330 : 150)

            HStack {
                Button(mode == .add ? L("Protect \(files.count) PDFs") : L("Unlock \(files.count) PDFs"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Text(L("Saved to \(model.outputBaseDirectory.lastPathComponent) · originals are not changed"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FileResultsView(results: results)
        }
        .onChange(of: mode) {
            results = []
            password = ""
            confirmation = ""
        }
        .reportsActivity(isProcessing)
    }

    private func run() {
        let files = self.files, mode = self.mode, output = model.outputDirectory, toolID = tool.id
        let password = self.password
        let protection = PDFProtection(
            openPassword: password, ownerPassword: ownerPassword, allowsPrinting: allowsPrinting,
            allowsCopying: allowsCopying, allowsEditing: allowsEditing)
        isProcessing = true
        Task {
            results = await processFiles(files) { url in
                switch mode {
                case .add: try PDFSecurity.protect(url, with: protection, output: output, tool: toolID)
                case .remove: try PDFSecurity.removePassword(url, password: password, output: output, tool: toolID)
                }
            }
            isProcessing = false
        }
    }
}
