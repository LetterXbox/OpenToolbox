import AppKit
import OpenToolboxCore
import SwiftUI

struct CompressPDFView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var preset: PDFCompressionPreset = .ebook
    @State private var isProcessing = false
    @State private var results: [Row] = []
    @State private var task: Task<Void, Never>?

    struct Row: Identifiable {
        let id = UUID()
        let source: URL
        let result: PDFCompressionResult?
        let error: String?
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.pdf], prompt: L("Drop PDFs here"))
            Form {
                Picker(L("Quality"), selection: $preset) {
                    Text(L("Smallest (72 dpi, screen)")).tag(PDFCompressionPreset.screen)
                    Text(L("Balanced (150 dpi, ebook)")).tag(PDFCompressionPreset.ebook)
                    Text(L("High quality (300 dpi, printer)")).tag(PDFCompressionPreset.printer)
                    Text(L("Maximum (300 dpi, prepress)")).tag(PDFCompressionPreset.prepress)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 80)

            HStack {
                if isProcessing {
                    Button(L("Stop")) { task?.cancel() }
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("Compress \(files.count) PDFs"), action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(files.isEmpty)
                }
                Spacer()
                Text(L("Saved to \(model.outputBaseDirectory.lastPathComponent) · originals are not changed"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            summary(results)
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isProcessing)
    }

    @ViewBuilder
    private func summary(_ rows: [Row]) -> some View {
        if !rows.isEmpty {
            let outputs = rows.compactMap { $0.result?.output }
            let before = rows.compactMap { $0.result?.output == nil ? nil : $0.result?.originalBytes }.reduce(0, +)
            let after = rows.compactMap { $0.result?.output == nil ? nil : $0.result?.compressedBytes }.reduce(0, +)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if !outputs.isEmpty {
                        Label(
                            L("Saved \(outputs.count) files: \(byteText(before)) → \(byteText(after))"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                    Spacer()
                    if !outputs.isEmpty {
                        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row in
                            if let error = row.error {
                                ErrorMessage(text: "\(row.source.lastPathComponent): \(error)").font(.callout)
                            } else if let result = row.result {
                                if result.output == nil {
                                    Text(L("\(row.source.lastPathComponent): already as small as these settings allow, not saved"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(
                                        L(
                                            "\(row.source.lastPathComponent): \(byteText(result.originalBytes)) → \(byteText(result.compressedBytes)), \(result.savedFraction.formatted(.percent.precision(.fractionLength(0)))) smaller"
                                        )
                                    )
                                    .font(.callout)
                                    .monospacedDigit()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private func run() {
        guard let gs = model.engines.executableURL(for: EngineCatalog.ghostscriptID) else { return }
        let files = self.files, preset = self.preset, output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        results = []
        task = Task {
            defer { isProcessing = false }
            var rows: [Row] = []
            for url in files {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let result = try await PDFCompressor.compress(
                        url,
                        preset: preset,
                        executable: gs,
                        output: output,
                        tool: toolID
                    )
                    rows.append(Row(source: url, result: result, error: nil))
                } catch is CancellationError {
                    break
                } catch {
                    rows.append(Row(source: url, result: nil, error: error.localizedDescription))
                }
            }
            results = rows
        }
    }
}
