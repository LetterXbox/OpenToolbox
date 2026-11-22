import AppKit
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Convert / Resize / Rotate

struct ImageConvertView: View {
    enum ResizeMode: Hashable { case none, percent, longEdge, fit }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var format: ImageFormat?
    @State private var quality = 0.85
    @State private var resizeMode: ResizeMode = .none
    @State private var percent = 50.0
    @State private var longEdge = 2048
    @State private var fitWidth = 1920
    @State private var fitHeight = 1080
    @State private var rotation: ImageEditOptions.Rotation = .none
    @State private var flip = false
    @State private var metadata: ImageEditOptions.Metadata = .keep
    @State private var isProcessing = false
    @State private var results: [FileResult] = []

    private var options: ImageEditOptions {
        let resize: ImageEditOptions.Resize =
            switch resizeMode {
            case .none: .none
            case .percent: .scale(percent / 100)
            case .longEdge: .longEdge(longEdge)
            case .fit: .fit(maxWidth: fitWidth, maxHeight: fitHeight)
            }
        return ImageEditOptions(
            format: format, quality: quality, resize: resize, rotation: rotation, flipHorizontal: flip,
            metadata: metadata)
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.image])
            Form {
                Picker(L("Format"), selection: $format) {
                    Text(L("Same as original")).tag(ImageFormat?.none)
                    ForEach(ImageFormat.writable) { format in
                        Text(verbatim: format.displayName).tag(Optional(format))
                    }
                }
                if format?.supportsQuality ?? true {
                    LabeledContent(L("Quality")) {
                        HStack {
                            Slider(value: $quality, in: 0.1...1)
                            Text(quality.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Picker(L("Resize"), selection: $resizeMode) {
                    Text(L("Original size")).tag(ResizeMode.none)
                    Text(L("Percentage")).tag(ResizeMode.percent)
                    Text(L("Longest edge")).tag(ResizeMode.longEdge)
                    Text(L("Fit inside")).tag(ResizeMode.fit)
                }
                switch resizeMode {
                case .none:
                    EmptyView()
                case .percent:
                    Stepper(value: $percent, in: 1...400, step: 5) {
                        Text(L("\(Int(percent))%")).monospacedDigit()
                    }
                case .longEdge:
                    TextField(L("Pixels"), value: $longEdge, format: .number)
                case .fit:
                    HStack {
                        TextField(L("Width"), value: $fitWidth, format: .number)
                        Text(verbatim: "×")
                        TextField(L("Height"), value: $fitHeight, format: .number)
                    }
                }
                Picker(L("Rotate"), selection: $rotation) {
                    Text(L("None")).tag(ImageEditOptions.Rotation.none)
                    Text(L("90° clockwise")).tag(ImageEditOptions.Rotation.clockwise90)
                    Text(L("180°")).tag(ImageEditOptions.Rotation.upsideDown)
                    Text(L("90° counterclockwise")).tag(ImageEditOptions.Rotation.counterclockwise90)
                }
                Toggle(L("Flip horizontally"), isOn: $flip)
                MetadataPicker(selection: $metadata)
            }
            .formStyle(.grouped)
            .frame(maxHeight: 360)

            HStack {
                Button(L("Convert \(files.count) Images"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || isProcessing)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Text(L("Saved to \(model.outputBaseDirectory.lastPathComponent) · originals are not changed"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FileResultsView(results: results)
        }
    }

    private func run() {
        let files = self.files, options = self.options, output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        Task {
            results = await processFiles(files) { url in
                try ImageProcessor.process(source: url, options: options, output: output, tool: toolID)
            }
            isProcessing = false
        }
    }
}

struct MetadataPicker: View {
    @Binding var selection: ImageEditOptions.Metadata

    var body: some View {
        Picker(L("Metadata"), selection: $selection) {
            Text(L("Keep")).tag(ImageEditOptions.Metadata.keep)
            Text(L("Remove location")).tag(ImageEditOptions.Metadata.removeLocation)
            Text(L("Remove all")).tag(ImageEditOptions.Metadata.removeAll)
        }
    }
}

// MARK: - Strip EXIF

struct StripMetadataView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var mode: ImageEditOptions.Metadata = .removeAll
    @State private var isProcessing = false
    @State private var results: [FileResult] = []

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.image])
            if let first = files.first {
                let rows = ImageProcessor.metadataSummary(ImageProcessor.properties(of: first))
                Pane(L("Metadata in \(first.lastPathComponent)")) {
                    if rows.isEmpty {
                        Text(L("No camera or location metadata found.")).foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(rows, id: \.label) { row in
                                GridRow {
                                    Text(row.label).foregroundStyle(.secondary)
                                    Text(row.value)
                                }
                            }
                        }
                    }
                }
            }
            Picker(L("Remove"), selection: $mode) {
                Text(L("Location only")).tag(ImageEditOptions.Metadata.removeLocation)
                Text(L("All metadata")).tag(ImageEditOptions.Metadata.removeAll)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            HStack {
                Button(L("Save Clean Copies"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || isProcessing)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text(L("Images are re-encoded without the selected metadata. Originals are not changed."))
                .font(.callout)
                .foregroundStyle(.secondary)
            FileResultsView(results: results)
        }
    }

    private func run() {
        let files = self.files, output = model.outputDirectory, toolID = tool.id
        let options = ImageEditOptions(quality: 0.95, metadata: mode)
        isProcessing = true
        Task {
            results = await processFiles(files) { url in
                try ImageProcessor.process(source: url, options: options, output: output, tool: toolID)
            }
            isProcessing = false
        }
    }
}

// MARK: - Remove Background

struct RemoveBackgroundView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var preview: ImageBox?
    @State private var isProcessing = false
    @State private var results: [FileResult] = []

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.image])
            HStack {
                Button(L("Remove Backgrounds"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || isProcessing)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Text(L("Runs on-device with Apple Vision. Saved as PNG with transparency."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let preview {
                ImagePreview(image: preview.cgImage)
                    .frame(maxHeight: 320)
            }
            FileResultsView(results: results)
        }
    }

    private func run() {
        let files = self.files, output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        Task {
            results = await processFiles(files) { url in
                let image = try ImageProcessor.loadImage(at: url).image
                let cutout = ImageBox(cgImage: try BackgroundRemover.removeBackground(from: image))
                let name = url.deletingPathExtension().lastPathComponent + " cutout"
                return try saveImage(cutout, named: name, output: output, tool: toolID)
            }
            if let first = results.compactMap(\.output).first, let image = try? ImageProcessor.loadImage(at: first).image {
                preview = ImageBox(cgImage: image)
            }
            isProcessing = false
        }
    }
}

// MARK: - Blur Faces

struct BlurFacesView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var style: FaceBlur.Style = .blur
    @State private var strength = 0.6
    @State private var preview: ImageBox?
    @State private var faceCount: Int?
    @State private var errorText: String?
    @State private var isProcessing = false
    @State private var isPreviewing = false
    /// Bumped whenever the preview's inputs change, so late results can be recognized.
    @State private var previewGeneration = 0
    @State private var results: [FileResult] = []

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.image])
            HStack(spacing: 16) {
                Picker(L("Style"), selection: $style) {
                    Text(L("Blur")).tag(FaceBlur.Style.blur)
                    Text(L("Pixelate")).tag(FaceBlur.Style.pixelate)
                    Text(L("Black box")).tag(FaceBlur.Style.solid)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if style != .solid {
                    Text(L("Strength"))
                    Slider(value: $strength, in: 0.1...1).frame(maxWidth: 200)
                }
                Spacer()
            }
            HStack {
                Button(L("Preview First Image"), action: makePreview)
                    .disabled(files.isEmpty || isProcessing || isPreviewing)
                Button(L("Blur Faces in \(files.count) Images"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || isProcessing)
                if isProcessing || isPreviewing { ProgressView().controlSize(.small) }
                Spacer()
                if let faceCount {
                    Text(L("\(faceCount) faces found")).foregroundStyle(.secondary)
                }
            }
            if let errorText { ErrorMessage(text: errorText) }
            if let preview {
                ImagePreview(image: preview.cgImage).frame(maxHeight: 320)
            }
            Text(L("Faces are detected on this Mac. Check the preview: detection can miss small or turned-away faces."))
                .font(.callout)
                .foregroundStyle(.secondary)
            FileResultsView(results: results)
        }
        // A preview always describes the current first file and settings, or nothing.
        .onChange(of: style) {
            let hadPreview = preview != nil || isPreviewing
            clearPreview()
            if hadPreview { makePreview() }
        }
        .onChange(of: files) { clearPreview() }
        .onChange(of: strength) { clearPreview() }
    }

    /// Drops the current preview and orphans any preview still computing.
    private func clearPreview() {
        previewGeneration += 1
        preview = nil
        faceCount = nil
        errorText = nil
        isPreviewing = false
    }

    private func makePreview() {
        guard let url = files.first else { return }
        let style = self.style, strength = self.strength
        clearPreview()
        let generation = previewGeneration
        isPreviewing = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(ImageBox, Int), any Error> in
                Result {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let image = try ImageProcessor.loadImage(at: url).image
                    let faces = try FaceBlur.detectFaces(in: image)
                    let output = try FaceBlur.anonymize(image, regions: faces, style: style, strength: strength)
                    return (ImageBox(cgImage: output), faces.count)
                }
            }.value
            // A newer preview or a change of input superseded this one: leave its state alone.
            guard generation == previewGeneration else { return }
            switch outcome {
            case .success(let (box, count)):
                preview = box
                faceCount = count
            case .failure(let error):
                errorText = error.localizedDescription
            }
            isPreviewing = false
        }
    }

    private func run() {
        let files = self.files, output = model.outputDirectory, toolID = tool.id
        let style = self.style, strength = self.strength
        isProcessing = true
        Task {
            results = await processFiles(files) { url in
                let loaded = try ImageProcessor.loadImage(at: url)
                let faces = try FaceBlur.detectFaces(in: loaded.image)
                // Saving an untouched copy named "blurred" would look like success.
                guard !faces.isEmpty else { throw VisionToolError.noFacesFound }
                let blurred = ImageBox(
                    cgImage: try FaceBlur.anonymize(loaded.image, regions: faces, style: style, strength: strength))
                let format = loaded.type.flatMap(ImageFormat.init(utType:))
                    .flatMap { ImageFormat.writable.contains($0) ? $0 : nil } ?? .png
                let name = url.deletingPathExtension().lastPathComponent + " blurred"
                return try saveImage(blurred, named: name, format: format, output: output, tool: toolID)
            }
            isProcessing = false
        }
    }
}

// MARK: - OCR

struct OCRView: View {
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var accurate = true
    @State private var text = ""
    @State private var errorText: String?
    @State private var isProcessing = false

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.image, .pdf], prompt: L("Drop images or PDFs here"))
            HStack {
                Button(L("Extract Text"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || isProcessing)
                Button(L("From Clipboard Image"), action: runClipboard)
                    .disabled(isProcessing)
                Toggle(L("Accurate"), isOn: $accurate)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                CopyButton(text: text)
            }
            if let errorText { ErrorMessage(text: errorText) }
            CodeOutput(text: text, placeholder: L("Recognized text appears here. Everything runs on this Mac."))
        }
    }

    private func run() {
        let files = self.files, accurate = self.accurate
        isProcessing = true
        errorText = nil
        Task {
            do {
                text = try await Task.detached(priority: .userInitiated) {
                    try files.map { url in
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        return try Self.recognize(url, accurate: accurate)
                    }.joined(separator: "\n\n")
                }.value
            } catch {
                errorText = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func runClipboard() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            errorText = L("The clipboard does not contain an image.")
            return
        }
        let box = ImageBox(cgImage: cgImage), accurate = self.accurate
        isProcessing = true
        errorText = nil
        Task {
            do {
                text = try await Task.detached(priority: .userInitiated) {
                    try TextRecognizer.recognize(in: box.cgImage, accurate: accurate).map(\.text).joined(separator: "\n")
                }.value
            } catch {
                errorText = error.localizedDescription
            }
            isProcessing = false
        }
    }

    nonisolated static func recognize(_ url: URL, accurate: Bool) throws -> String {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            return try PDFTools.recognizeText(in: try PDFTools.open(url), accurate: accurate)
        }
        let image = try ImageProcessor.loadImage(at: url).image
        return try TextRecognizer.recognize(in: image, accurate: accurate).map(\.text).joined(separator: "\n")
    }
}

// MARK: - QR Code

struct QRCodeView: View {
    enum Mode: Hashable { case generate, read }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var mode: Mode = .generate
    @State private var text = "https://"
    @State private var correction: QRCode.Correction = .medium
    @State private var savedURL: URL?
    @State private var readFiles: [URL] = []
    @State private var payloads: [String] = []
    @State private var errorText: String?

    private var code: ImageBox? {
        guard !text.isEmpty, let image = try? QRCode.generate(text, correction: correction, moduleSize: 12) else {
            return nil
        }
        return ImageBox(cgImage: image)
    }

    var body: some View {
        ToolPage(tool: tool) {
            Picker(L("Mode"), selection: $mode) {
                Text(L("Generate")).tag(Mode.generate)
                Text(L("Read")).tag(Mode.read)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch mode {
            case .generate: generator
            case .read: reader
            }
            if let errorText { ErrorMessage(text: errorText) }
        }
        .onChange(of: readFiles) { readCodes() }
    }

    @ViewBuilder private var generator: some View {
        let code = self.code
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Pane(L("Content")) {
                    CodeEditor(text: $text).frame(minHeight: 100, maxHeight: 200)
                }
                Picker(L("Error correction"), selection: $correction) {
                    Text(L("Low (7%)")).tag(QRCode.Correction.low)
                    Text(L("Medium (15%)")).tag(QRCode.Correction.medium)
                    Text(L("Quartile (25%)")).tag(QRCode.Correction.quartile)
                    Text(L("High (30%)")).tag(QRCode.Correction.high)
                }
                .fixedSize()
                HStack {
                    Button(L("Copy Image")) {
                        guard let code else { return }
                        let image = NSImage(cgImage: code.cgImage, size: .zero)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                    Button(L("Save PNG")) {
                        guard let code else { return }
                        do {
                            savedURL = try saveImage(code, named: "QR Code", output: model.outputDirectory, tool: tool.id)
                            errorText = nil
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    if let savedURL {
                        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                    }
                }
                .disabled(code == nil)
            }
            if let code {
                Image(decorative: code.cgImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .background(Color.white)
            }
        }
    }

    @ViewBuilder private var reader: some View {
        FileDropList(files: $readFiles, allowedTypes: [.image], allowsMultiple: false, prompt: L("Drop an image with a QR code"))
        Button(L("Read from Clipboard Image")) {
            guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                errorText = L("The clipboard does not contain an image.")
                return
            }
            decode(ImageBox(cgImage: cgImage))
        }
        ForEach(payloads, id: \.self) { payload in
            HStack {
                Text(payload).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                InlineCopyButton(text: payload)
                if let url = URL(string: payload), url.scheme == "https" || url.scheme == "http" {
                    Link(L("Open"), destination: url)
                }
            }
        }
    }

    private func readCodes() {
        guard let url = readFiles.first else { return }
        do {
            decode(ImageBox(cgImage: try ImageProcessor.loadImage(at: url).image))
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func decode(_ box: ImageBox) {
        do {
            payloads = try QRCode.read(from: box.cgImage)
            errorText = payloads.isEmpty ? VisionToolError.noCodeFound.localizedDescription : nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
