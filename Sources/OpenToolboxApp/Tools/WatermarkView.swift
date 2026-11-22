import AppKit
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

struct WatermarkView: View {
    enum Kind: Hashable { case text, image }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var kind: Kind = .text
    @State private var text = ""
    @State private var markImage: URL?
    @State private var position: WatermarkOptions.Position = .center
    @State private var opacity = 0.4
    @State private var relativeWidth = 0.4
    @State private var isDiagonal = false
    @State private var textColor: WatermarkOptions.TextColor = .gray
    @State private var isProcessing = false
    @State private var results: [FileResult] = []

    private var content: WatermarkOptions.Content? {
        switch kind {
        case .text:
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(text)
        case .image:
            markImage.map { .image($0) }
        }
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.image, .pdf], prompt: L("Drop images or PDFs here"))
            Form {
                Picker(L("Watermark"), selection: $kind) {
                    Text(L("Text")).tag(Kind.text)
                    Text(L("Image")).tag(Kind.image)
                }
                .pickerStyle(.segmented)
                switch kind {
                case .text:
                    TextField(L("Text"), text: $text, prompt: Text(L("For example, Draft")))
                    Picker(L("Color"), selection: $textColor) {
                        Text(L("White")).tag(WatermarkOptions.TextColor.white)
                        Text(L("Gray")).tag(WatermarkOptions.TextColor.gray)
                        Text(L("Black")).tag(WatermarkOptions.TextColor.black)
                    }
                case .image:
                    LabeledContent(L("Image")) {
                        HStack {
                            Text(markImage?.lastPathComponent ?? L("None"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(markImage == nil ? .secondary : .primary)
                            Button(L("Choose…"), action: chooseImage)
                        }
                    }
                }
                Picker(L("Position"), selection: $position) {
                    ForEach(WatermarkOptions.Position.allCases) { position in
                        Text(title(for: position)).tag(position)
                    }
                }
                LabeledContent(L("Opacity")) {
                    HStack {
                        Slider(value: $opacity, in: 0.05...1)
                        Text(opacity.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent(L("Size")) {
                    HStack {
                        Slider(value: $relativeWidth, in: 0.05...1)
                        Text(relativeWidth.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(L("Diagonal"), isOn: $isDiagonal)
            }
            .formStyle(.grouped)
            .frame(maxHeight: 360)

            HStack {
                Button(L("Watermark \(files.count) Files"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || content == nil || isProcessing)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Text(L("Saved to \(model.outputBaseDirectory.lastPathComponent) · originals are not changed"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FileResultsView(results: results)
        }
        .reportsActivity(isProcessing)
    }

    private func title(for position: WatermarkOptions.Position) -> String {
        switch position {
        case .topLeft: L("Top left")
        case .top: L("Top")
        case .topRight: L("Top right")
        case .left: L("Left")
        case .center: L("Center")
        case .right: L("Right")
        case .bottomLeft: L("Bottom left")
        case .bottom: L("Bottom")
        case .bottomRight: L("Bottom right")
        case .tiled: L("Tiled across the page")
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url {
            markImage = url
        }
    }

    private func run() {
        guard let content else { return }
        let options = WatermarkOptions(
            content: content, position: position, opacity: opacity, relativeWidth: relativeWidth,
            isDiagonal: isDiagonal, textColor: textColor)
        let files = self.files, output = model.outputDirectory, toolID = tool.id
        let markImage = self.markImage
        isProcessing = true
        Task {
            let accessing = markImage?.startAccessingSecurityScopedResource() ?? false
            defer { if accessing { markImage?.stopAccessingSecurityScopedResource() } }
            results = await processFiles(files) { url in
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                    return try Watermark.apply(toPDF: url, options: options, output: output, tool: toolID)
                }
                return try Watermark.apply(toImage: url, options: options, output: output, tool: toolID)
            }
            isProcessing = false
        }
    }
}
