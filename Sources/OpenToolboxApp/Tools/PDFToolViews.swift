import AppKit
import OpenToolboxCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Merge / Split / Organize

struct PDFOrganizeView: View {
    enum Mode: Hashable { case merge, extract, split, rotate }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var mode: Mode = .merge
    @State private var files: [URL] = []
    @State private var pageRange = ""
    @State private var pagesPerFile = 1
    @State private var degrees = 90
    @State private var isProcessing = false
    @State private var results: [FileResult] = []

    private var pageCount: Int? {
        guard mode != .merge, let url = files.first else { return nil }
        return PDFDocument(url: url)?.pageCount
    }

    var body: some View {
        let pageCount = self.pageCount
        ToolPage(tool: tool) {
            Picker(L("Action"), selection: $mode) {
                Text(L("Merge")).tag(Mode.merge)
                Text(L("Extract Pages")).tag(Mode.extract)
                Text(L("Split")).tag(Mode.split)
                Text(L("Rotate Pages")).tag(Mode.rotate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            FileDropList(
                files: $files, allowedTypes: [.pdf], allowsMultiple: mode == .merge,
                prompt: mode == .merge ? L("Drop PDFs to merge, in order") : L("Drop a PDF"))
            if mode == .merge, files.count > 1 {
                Text(L("Drag rows to change the order."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let pageCount {
                Text(L("\(pageCount) pages")).foregroundStyle(.secondary)
            }

            switch mode {
            case .merge:
                EmptyView()
            case .extract:
                TextField(L("Pages, for example 1-3, 5, 8-"), text: $pageRange)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            case .split:
                Stepper(value: $pagesPerFile, in: 1...500) {
                    Text(L("\(pagesPerFile) pages per file"))
                }
                .fixedSize()
            case .rotate:
                HStack {
                    TextField(L("Pages (empty = all)"), text: $pageRange)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Picker(L("Angle"), selection: $degrees) {
                        Text(L("90° clockwise")).tag(90)
                        Text(L("180°")).tag(180)
                        Text(L("90° counterclockwise")).tag(270)
                    }
                    .fixedSize()
                }
            }

            if let url = files.first, mode != .merge {
                PDFThumbnailStrip(url: url)
            }

            HStack {
                Button(actionTitle, action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || (mode == .merge && files.count < 2) || isProcessing)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
            }
            FileResultsView(results: results)
        }
        .onChange(of: mode) {
            results = []
            if mode != .merge, files.count > 1 { files = Array(files.prefix(1)) }
        }
    }

    private var actionTitle: String {
        switch mode {
        case .merge: L("Merge \(files.count) PDFs")
        case .extract: L("Extract Pages")
        case .split: L("Split PDF")
        case .rotate: L("Rotate and Save")
        }
    }

    private func run() {
        let files = self.files, mode = self.mode, range = self.pageRange
        let pagesPerFile = self.pagesPerFile, degrees = self.degrees
        let output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        Task {
            results = await Task.detached(priority: .userInitiated) { () -> [FileResult] in
                let scoped = files.map { ($0, $0.startAccessingSecurityScopedResource()) }
                defer { for (url, accessing) in scoped where accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    return try Self.perform(
                        mode, files: files, range: range, pagesPerFile: pagesPerFile, degrees: degrees,
                        output: output, tool: toolID
                    ).map { FileResult(source: files[0], output: $0, error: nil) }
                } catch {
                    return [FileResult(source: files[0], output: nil, error: error.localizedDescription)]
                }
            }.value
            isProcessing = false
        }
    }

    nonisolated static func perform(
        _ mode: Mode, files: [URL], range: String, pagesPerFile: Int, degrees: Int, output: OutputDirectory, tool: ToolID
    ) throws -> [URL] {
        func save(_ document: PDFDocument, _ name: String) throws -> URL {
            try output.writeNewFile(for: tool, preferredName: name + ".pdf") {
                try PDFTools.write(document, to: $0)
            }
        }
        let base = files[0].deletingPathExtension().lastPathComponent
        switch mode {
        case .merge:
            let merged = PDFTools.merge(try files.map(PDFTools.open))
            return [try save(merged, coreMergedName(base))]
        case .extract:
            let document = try PDFTools.open(files[0])
            let pages = try PageRange.parse(range, pageCount: document.pageCount)
            return [try save(PDFTools.extract(pages, from: document), base + " pages")]
        case .split:
            let document = try PDFTools.open(files[0])
            return try PDFTools.split(document, pagesPerFile: pagesPerFile).enumerated().map { index, part in
                try save(part, "\(base) part \(index + 1)")
            }
        case .rotate:
            let document = try PDFTools.open(files[0])
            let pages = try PageRange.parse(range, pageCount: document.pageCount)
            return [try save(PDFTools.rotate(Set(pages), by: degrees, in: document), base + " rotated")]
        }
    }

    nonisolated static func coreMergedName(_ base: String) -> String { base + " merged" }
}

/// Small read-only page previews.
struct PDFThumbnailStrip: View {
    let url: URL

    var body: some View {
        let thumbnails: [(Int, NSImage)] = {
            guard let document = PDFDocument(url: url) else { return [] }
            return (0..<min(document.pageCount, 40)).compactMap { index in
                document.page(at: index).map { (index, $0.thumbnail(of: CGSize(width: 90, height: 120), for: .mediaBox)) }
            }
        }()
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(thumbnails, id: \.0) { index, image in
                    VStack(spacing: 4) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 110)
                            .shadow(radius: 1)
                        Text(verbatim: "\(index + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
        .frame(height: 140)
    }
}

// MARK: - Images ↔ PDF

struct ImagesPDFView: View {
    enum Mode: Hashable { case imagesToPDF, pdfToImages }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var mode: Mode = .imagesToPDF
    @State private var images: [URL] = []
    @State private var pdfs: [URL] = []
    @State private var pageSize: PDFPageSize = .fitImage
    @State private var format: ImageFormat = .png
    @State private var dpi = 150
    @State private var pageRange = ""
    @State private var isProcessing = false
    @State private var results: [FileResult] = []

    var body: some View {
        ToolPage(tool: tool) {
            Picker(L("Direction"), selection: $mode) {
                Text(L("Images → PDF")).tag(Mode.imagesToPDF)
                Text(L("PDF → Images")).tag(Mode.pdfToImages)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch mode {
            case .imagesToPDF:
                FileDropList(files: $images, allowedTypes: [.image], prompt: L("Drop images, one per page"))
                Picker(L("Page size"), selection: $pageSize) {
                    Text(L("Match each image")).tag(PDFPageSize.fitImage)
                    Text(verbatim: "A4").tag(PDFPageSize.a4)
                    Text(L("US Letter")).tag(PDFPageSize.letter)
                }
                .fixedSize()
            case .pdfToImages:
                FileDropList(files: $pdfs, allowedTypes: [.pdf], allowsMultiple: false, prompt: L("Drop a PDF"))
                HStack(spacing: 16) {
                    Picker(L("Format"), selection: $format) {
                        ForEach(ImageFormat.writable.filter { $0 != .gif && $0 != .bmp }) { format in
                            Text(verbatim: format.displayName).tag(format)
                        }
                    }
                    .fixedSize()
                    Picker(L("Resolution"), selection: $dpi) {
                        Text(verbatim: "72 dpi").tag(72)
                        Text(verbatim: "150 dpi").tag(150)
                        Text(verbatim: "300 dpi").tag(300)
                    }
                    .fixedSize()
                    TextField(L("Pages (empty = all)"), text: $pageRange)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
            }

            HStack {
                Button(mode == .imagesToPDF ? L("Create PDF") : L("Export Pages"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled((mode == .imagesToPDF ? images.isEmpty : pdfs.isEmpty) || isProcessing)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
            }
            FileResultsView(results: results)
        }
    }

    private func run() {
        let mode = self.mode, images = self.images, pdfs = self.pdfs, pageSize = self.pageSize
        let format = self.format, dpi = self.dpi, range = self.pageRange
        let output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        Task {
            results = await Task.detached(priority: .userInitiated) { () -> [FileResult] in
                let inputs = mode == .imagesToPDF ? images : pdfs
                let scoped = inputs.map { ($0, $0.startAccessingSecurityScopedResource()) }
                defer { for (url, accessing) in scoped where accessing { url.stopAccessingSecurityScopedResource() } }
                guard let first = inputs.first else { return [] }
                do {
                    let base = first.deletingPathExtension().lastPathComponent
                    switch mode {
                    case .imagesToPDF:
                        let cgImages = try images.map { try ImageProcessor.loadImage(at: $0).image }
                        let document = PDFTools.makePDF(fromImages: cgImages, pageSize: pageSize)
                        let url = try output.writeNewFile(for: toolID, preferredName: base + ".pdf") {
                            try PDFTools.write(document, to: $0)
                        }
                        return [FileResult(source: first, output: url, error: nil)]
                    case .pdfToImages:
                        let document = try PDFTools.open(first)
                        let pages = try PageRange.parse(range, pageCount: document.pageCount)
                        return try pages.compactMap { index -> FileResult? in
                            guard let page = document.page(at: index) else { return nil }
                            let image = try PDFTools.render(page, dpi: CGFloat(dpi))
                            let url = try output.writeNewFile(
                                for: toolID, preferredName: "\(base) page \(index + 1).\(format.fileExtension)"
                            ) {
                                try ImageProcessor.write(image, to: $0, format: format, quality: 0.9)
                            }
                            return FileResult(source: first, output: url, error: nil)
                        }
                    }
                } catch {
                    return [FileResult(source: first, output: nil, error: error.localizedDescription)]
                }
            }.value
            isProcessing = false
        }
    }
}
