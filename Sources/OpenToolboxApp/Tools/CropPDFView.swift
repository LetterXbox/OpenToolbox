import OpenToolboxCore
import PDFKit
import SwiftUI

struct CropPDFView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var sameOnAllSides = true
    @State private var top = 10.0
    @State private var left = 10.0
    @State private var bottom = 10.0
    @State private var right = 10.0
    @State private var pageRange = ""
    @State private var isProcessing = false
    @State private var results: [FileResult] = []

    private var margins: PDFMargins {
        sameOnAllSides
            ? .millimeters(top: top, left: top, bottom: top, right: top)
            : .millimeters(top: top, left: left, bottom: bottom, right: right)
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.pdf], allowsMultiple: false, prompt: L("Drop a PDF"))
            HStack(alignment: .top, spacing: 20) {
                Form {
                    Toggle(L("Same margin on every side"), isOn: $sameOnAllSides)
                    if sameOnAllSides {
                        marginField(L("Margin"), value: $top)
                    } else {
                        marginField(L("Top"), value: $top)
                        marginField(L("Left"), value: $left)
                        marginField(L("Bottom"), value: $bottom)
                        marginField(L("Right"), value: $right)
                    }
                    TextField(L("Pages (empty = all)"), text: $pageRange)
                }
                .formStyle(.grouped)
                .frame(maxWidth: 380, maxHeight: 300)

                if let url = files.first {
                    CropPreview(url: url, margins: margins)
                        .frame(width: 220, height: 280)
                }
            }

            HStack {
                Button(L("Crop and Save"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || margins.isZero || isProcessing)
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

    private func marginField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .frame(width: 70)
                Stepper(title, value: value, in: 0...500, step: 1).labelsHidden()
                Text(verbatim: "mm").foregroundStyle(.secondary)
            }
        }
    }

    private func run() {
        let files = self.files, margins = self.margins, range = self.pageRange
        let output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        Task {
            results = await processFiles(files) { url in
                let document = try PDFTools.open(url)
                let pages: Set<Int>? =
                    range.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : Set(try PageRange.parse(range, pageCount: document.pageCount))
                let cropped = try PDFCrop.crop(document, pages: pages, margins: margins)
                let base = url.deletingPathExtension().lastPathComponent
                return try output.writeNewFile(for: toolID, preferredName: base + " cropped.pdf") {
                    try PDFTools.write(cropped, to: $0)
                }
            }
            isProcessing = false
        }
    }
}

private struct CropPreview: View {
    let url: URL
    let margins: PDFMargins

    var body: some View {
        if let document = PDFDocument(url: url), let page = document.page(at: 0) {
            let box = page.bounds(for: .cropBox)
            let quarterTurn = page.rotation % 180 != 0
            let size = quarterTurn ? CGSize(width: box.height, height: box.width) : box.size
            let image = page.thumbnail(of: CGSize(width: 440, height: 560), for: .cropBox)
            GeometryReader { geometry in
                let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                let shown = CGSize(width: size.width * scale, height: size.height * scale)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.08))
                        .frame(
                            width: max(0, shown.width - (margins.left + margins.right) * scale),
                            height: max(0, shown.height - (margins.top + margins.bottom) * scale)
                        )
                        .offset(x: margins.left * scale, y: margins.top * scale)
                }
                .frame(width: shown.width, height: shown.height)
                .shadow(radius: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
