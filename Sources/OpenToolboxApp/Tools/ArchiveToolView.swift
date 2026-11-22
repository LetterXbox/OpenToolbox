import AppKit
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveToolView: View {
    enum Mode: Hashable { case extract, compress }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var mode: Mode = .extract
    @State private var files: [URL] = []
    @State private var format: ArchiveFormat = .zip
    @State private var level: ArchiveCompressionLevel = .balanced
    @State private var archiveName = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var savedURLs: [URL] = []
    @State private var summaryMessage: String?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    private var archiveTypes: [UTType] {
        var types: [UTType] = [.archive, .zip, .gzip, .bz2]
        for ext in ["7z", "rar", "tar", "xz", "tgz", "txz", "iso"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    var body: some View {
        ToolPage(tool: tool) {
            Picker(L("Action"), selection: $mode) {
                Text(L("Extract")).tag(Mode.extract)
                Text(L("Compress")).tag(Mode.compress)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .onChange(of: mode) {
                files = []
                savedURLs = []
                summaryMessage = nil
                failure = nil
            }

            if mode == .extract {
                FileDropList(
                    files: $files,
                    allowedTypes: archiveTypes,
                    prompt: L("Drop ZIP, 7z, RAR, or TAR archives here")
                )
                Form {
                    SecureField(L("Password (if encrypted)"), text: $password)
                }
                .formStyle(.grouped)
                .frame(maxWidth: 480, maxHeight: 80)
            } else {
                FileDropList(
                    files: $files,
                    allowedTypes: [.item],
                    prompt: L("Drop files or folders to archive")
                )
                Form {
                    TextField(L("Archive name"), text: $archiveName, prompt: Text(L("Archive")))
                    Picker(L("Format"), selection: $format) {
                        Text(verbatim: "ZIP (.zip)").tag(ArchiveFormat.zip)
                        Text(verbatim: "7-Zip (.7z)").tag(ArchiveFormat.sevenZip)
                        Text(verbatim: "TAR (.tar)").tag(ArchiveFormat.tar)
                    }
                    Picker(L("Compression"), selection: $level) {
                        Text(L("Store (no compression)")).tag(ArchiveCompressionLevel.store)
                        Text(L("Fast")).tag(ArchiveCompressionLevel.fast)
                        Text(L("Balanced")).tag(ArchiveCompressionLevel.balanced)
                        Text(L("Maximum")).tag(ArchiveCompressionLevel.maximum)
                    }
                    if format.supportsPassword {
                        SecureField(L("Password (optional)"), text: $password)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 480, maxHeight: 200)
            }

            HStack {
                if isWorking {
                    Button(L("Stop")) { task?.cancel() }
                    ProgressView().controlSize(.small)
                } else {
                    Button(
                        mode == .extract ? L("Extract \(files.count) Archives") : L("Create Archive"),
                        action: run
                    )
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty)
                }
                Spacer()
                if !savedURLs.isEmpty {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(savedURLs) }
                }
            }

            if let summaryMessage {
                Label(summaryMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let failure { ErrorMessage(text: failure) }
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard let sevenZip = model.engines.executableURL(for: EngineCatalog.sevenZipID) else { return }
        let mode = self.mode, files = self.files, format = self.format, level = self.level
        let archiveName = self.archiveName, password = self.password
        let output = model.outputDirectory, toolID = tool.id

        isWorking = true
        savedURLs = []
        summaryMessage = nil
        failure = nil

        task = Task {
            defer { isWorking = false }
            let accessed = files.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer {
                for (url, ok) in accessed where ok { url.stopAccessingSecurityScopedResource() }
            }
            do {
                if mode == .extract {
                    var outputs: [URL] = []
                    var totalFiles = 0
                    for archive in files {
                        if Task.isCancelled { break }
                        let res = try await ArchiveTool.extract(
                            archive,
                            password: password.isEmpty ? nil : password,
                            executable: sevenZip,
                            output: output,
                            tool: toolID
                        )
                        outputs.append(res.output)
                        totalFiles += res.extractedFileCount
                    }
                    savedURLs = outputs
                    if !outputs.isEmpty {
                        summaryMessage = L("Extracted \(totalFiles) files into \(outputs.count) item(s).")
                    }
                } else {
                    let saved = try await ArchiveTool.compress(
                        files,
                        archiveName: archiveName,
                        format: format,
                        level: level,
                        password: format.supportsPassword && !password.isEmpty ? password : nil,
                        executable: sevenZip,
                        output: output,
                        tool: toolID
                    )
                    savedURLs = [saved]
                    summaryMessage = L("Saved \(saved.lastPathComponent)")
                }
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
