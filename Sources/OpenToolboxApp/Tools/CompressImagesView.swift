import AppKit
import OpenToolboxCore
import SwiftUI

struct CompressImagesView: View {
    enum Target: Hashable { case keep, heic, jpeg }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var target: Target = .keep
    @State private var quality = 0.7
    @State private var limitsSize = false
    @State private var longEdge = 2560
    @State private var metadata: ImageEditOptions.Metadata = .removeLocation
    @State private var isProcessing = false
    @State private var results: [Row] = []

    struct Row: Identifiable {
        let id = UUID()
        let source: URL
        let result: ImageCompressionResult?
        let error: String?
    }

    private var options: ImageCompressionOptions {
        let target: ImageCompressionOptions.Target =
            switch self.target {
            case .keep: .keepFormat(fallback: .heic)
            case .heic: .convert(.heic)
            case .jpeg: .convert(.jpeg)
            }
        return ImageCompressionOptions(
            target: target, quality: quality, longEdge: limitsSize ? max(longEdge, 16) : nil, metadata: metadata)
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.image], prompt: L("Drop images here"))
            Form {
                Picker(L("Format"), selection: $target) {
                    Text(L("Keep JPEG and HEIC, others to HEIC")).tag(Target.keep)
                    Text(verbatim: "HEIC").tag(Target.heic)
                    Text(verbatim: "JPEG").tag(Target.jpeg)
                }
                LabeledContent(L("Quality")) {
                    HStack {
                        Slider(value: $quality, in: 0.1...0.95)
                        Text(quality.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(L("Limit the longest edge"), isOn: $limitsSize)
                if limitsSize {
                    TextField(L("Pixels"), value: $longEdge, format: .number)
                }
                MetadataPicker(selection: $metadata)
            }
            .formStyle(.grouped)
            .frame(maxHeight: 300)

            HStack {
                Button(L("Compress \(files.count) Images"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || isProcessing)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Text(L("Saved to \(model.outputBaseDirectory.lastPathComponent) · originals are not changed"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            summary(results)
        }
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
        let files = self.files, options = self.options, output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        Task {
            results = await Task.detached(priority: .userInitiated) {
                files.map { url in
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let result = try ImageCompressor.compress(url, options: options, output: output, tool: toolID)
                        return Row(source: url, result: result, error: nil)
                    } catch {
                        return Row(source: url, result: nil, error: error.localizedDescription)
                    }
                }
            }.value
            isProcessing = false
        }
    }
}
