import AppKit
import OpenToolboxCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Renders local HTML or HTML strings to PDF completely offline using `WKWebView`.
/// Any attempt to navigate or load remote URLs is blocked.
@MainActor
final class OfflineHTMLPDFRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var allowedRootPath: String?

    func renderHTMLString(_ html: String, width: CGFloat = 794) async throws -> Data {
        try await render(width: width, allowedRoot: nil) { webView in
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func renderFile(_ htmlURL: URL, readAccessDirectory: URL, width: CGFloat = 794) async throws -> Data {
        try await render(width: width, allowedRoot: readAccessDirectory.standardizedFileURL.path) { webView in
            webView.loadFileURL(htmlURL, allowingReadAccessTo: readAccessDirectory)
        }
    }

    private func render(
        width: CGFloat,
        allowedRoot: String?,
        load: (WKWebView) -> Void
    ) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1122), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        self.allowedRootPath = allowedRoot
        defer {
            webView.stopLoading()
            self.webView = nil
            self.allowedRootPath = nil
        }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            load(webView)
        }
        try await Task.sleep(for: .milliseconds(250))
        return try await webView.pdf(configuration: WKPDFConfiguration())
    }

    func cancel() {
        webView?.stopLoading()
        resume(.failure(CancellationError()))
    }

    private func resume(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "data" { return .allow }
        if scheme == "file", let allowedRootPath {
            let path = url.standardizedFileURL.path
            if path == allowedRootPath || path.hasPrefix(allowedRootPath + "/") {
                return .allow
            }
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resume(.failure(error))
    }
}

enum PDFOutputLayout: Hashable {
    case a4
    case letter
    case singlePage

    var pageSize: CGSize? {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        case .singlePage: nil
        }
    }
}

@MainActor
private func saveRenderedPDF(
    _ data: Data,
    layout: PDFOutputLayout,
    preferredName: String,
    output: OutputDirectory,
    toolID: ToolID
) throws -> URL {
    try output.writeNewFile(for: toolID, preferredName: preferredName) { destination in
        if let size = layout.pageSize {
            guard let page = PDFDocument(data: data)?.page(at: 0) else { throw PDFToolError.writeFailed }
            try PDFPagination.paginate(page, pageSize: size, to: destination)
        } else {
            try data.write(to: destination)
        }
    }
}

struct MarkdownToPDFView: View {
    enum SourceMode: Hashable { case text, files }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var sourceMode: SourceMode = .text
    @State private var markdown = "# Hello OpenToolbox\n\nWrite or paste **Markdown** here, or switch to **Files** to batch-convert `.md` files.\n"
    @State private var files: [URL] = []
    @State private var layout: PDFOutputLayout = .a4
    @State private var renderer = OfflineHTMLPDFRenderer()
    @State private var isWorking = false
    @State private var results: [FileResult] = []
    @State private var savedSingle: URL?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    private var markdownTypes: [UTType] {
        var types: [UTType] = [.plainText]
        for ext in ["md", "markdown", "mdown", "mkd"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    var body: some View {
        ToolPage(tool: tool) {
            HStack {
                Picker(L("Input"), selection: $sourceMode) {
                    Text(L("Write / Paste")).tag(SourceMode.text)
                    Text(L("Files")).tag(SourceMode.files)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Spacer()

                Picker(L("Pages"), selection: $layout) {
                    Text(verbatim: "A4").tag(PDFOutputLayout.a4)
                    Text(L("US Letter")).tag(PDFOutputLayout.letter)
                    Text(L("One long page")).tag(PDFOutputLayout.singlePage)
                }
                .frame(maxWidth: 220)
            }

            if sourceMode == .text {
                CodeEditor(text: $markdown)
                    .frame(minHeight: 240)
            } else {
                FileDropList(files: $files, allowedTypes: markdownTypes, prompt: L("Drop Markdown (.md) files here"))
            }

            HStack {
                if isWorking {
                    Button(L("Stop")) {
                        task?.cancel()
                        renderer.cancel()
                    }
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("Save as PDF"), action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(sourceMode == .text ? markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : files.isEmpty)
                }
                Spacer()
                if let savedSingle {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([savedSingle]) }
                }
            }

            if let failure { ErrorMessage(text: failure) }
            FileResultsView(results: results)
        }
        .onDisappear {
            task?.cancel()
            renderer.cancel()
        }
        .reportsActivity(isWorking)
    }

    private func run() {
        let mode = sourceMode, text = markdown, files = self.files, layout = self.layout
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        failure = nil
        savedSingle = nil
        results = []

        task = Task {
            defer { isWorking = false }
            do {
                if mode == .text {
                    let html = MarkdownHTML.renderDocument(text)
                    let data = try await renderer.renderHTMLString(html)
                    savedSingle = try saveRenderedPDF(data, layout: layout, preferredName: "Markdown.pdf", output: output, toolID: toolID)
                } else {
                    var batch: [FileResult] = []
                    for url in files {
                        if Task.isCancelled { break }
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let content = try String(contentsOf: url, encoding: .utf8)
                            let base = url.deletingPathExtension().lastPathComponent
                            let html = MarkdownHTML.renderDocument(content, title: base)
                            let data = try await renderer.renderHTMLString(html)
                            let saved = try saveRenderedPDF(data, layout: layout, preferredName: "\(base).pdf", output: output, toolID: toolID)
                            batch.append(FileResult(source: url, output: saved, error: nil))
                        } catch is CancellationError {
                            break
                        } catch {
                            batch.append(FileResult(source: url, output: nil, error: error.localizedDescription))
                        }
                    }
                    results = batch
                }
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct OfficeToPDFView: View {
    enum Kind {
        case word
        case powerpoint
        case excel

        var extensions: [String] {
            switch self {
            case .word: ["docx", "doc", "odt", "rtf"]
            case .powerpoint: ["pptx", "ppt"]
            case .excel: ["xlsx", "xls"]
            }
        }

        var prompt: String {
            switch self {
            case .word: L("Drop Word documents (.docx, .doc, .odt, .rtf) here")
            case .powerpoint: L("Drop PowerPoint presentations (.pptx, .ppt) here")
            case .excel: L("Drop Excel spreadsheets (.xlsx, .xls) here")
            }
        }

        var defaultLayout: PDFOutputLayout {
            switch self {
            case .word: .a4
            case .powerpoint, .excel: .singlePage
            }
        }

        var renderWidth: CGFloat {
            switch self {
            case .word: 794
            case .powerpoint: 1280
            case .excel: 1122
            }
        }
    }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    let kind: Kind

    @State private var files: [URL] = []
    @State private var layout: PDFOutputLayout
    @State private var renderer = OfflineHTMLPDFRenderer()
    @State private var isWorking = false
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    init(tool: ToolDescriptor, kind: Kind) {
        self.tool = tool
        self.kind = kind
        _layout = State(initialValue: kind.defaultLayout)
    }

    private var allowedTypes: [UTType] {
        kind.extensions.compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: allowedTypes, prompt: kind.prompt)
            Form {
                Picker(L("Pages"), selection: $layout) {
                    Text(verbatim: "A4").tag(PDFOutputLayout.a4)
                    Text(L("US Letter")).tag(PDFOutputLayout.letter)
                    Text(L("One long page")).tag(PDFOutputLayout.singlePage)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 420, maxHeight: 80)

            HStack {
                if isWorking {
                    Button(L("Stop")) {
                        task?.cancel()
                        renderer.cancel()
                    }
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("Convert \(files.count) Files to PDF"), action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(files.isEmpty)
                }
                Spacer()
                Text(L("Uses macOS Quick Look offline · layout may differ from Microsoft Office"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FileResultsView(results: results)
        }
        .onDisappear {
            task?.cancel()
            renderer.cancel()
        }
        .reportsActivity(isWorking)
    }

    private func run() {
        let files = self.files, layout = self.layout, width = kind.renderWidth
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        results = []

        task = Task {
            defer { isWorking = false }
            var batch: [FileResult] = []
            for url in files {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let preview = try await OfficeDocumentConverter.stageHTMLPreview(for: url)
                    defer { preview.cleanup() }
                    let data = try await renderer.renderFile(
                        preview.htmlURL,
                        readAccessDirectory: preview.readAccessDirectory,
                        width: width
                    )
                    let base = url.deletingPathExtension().lastPathComponent
                    let saved = try saveRenderedPDF(data, layout: layout, preferredName: "\(base).pdf", output: output, toolID: toolID)
                    batch.append(FileResult(source: url, output: saved, error: nil))
                } catch is CancellationError {
                    break
                } catch {
                    batch.append(FileResult(source: url, output: nil, error: error.localizedDescription))
                }
            }
            results = batch
        }
    }
}

struct ConvertDocumentsView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var target: DocumentTargetFormat = .pdf
    @State private var pdfLayout: PDFOutputLayout = .a4
    @State private var renderer = OfflineHTMLPDFRenderer()
    @State private var isWorking = false
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.plainText, .rtf, .html]
        for ext in ["docx", "doc", "odt", "md", "markdown", "pptx", "ppt", "xlsx", "xls"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(
                files: $files,
                allowedTypes: allowedTypes,
                prompt: L("Drop DOCX, DOC, RTF, HTML, ODT, TXT, or Markdown files here")
            )
            Form {
                Picker(L("Convert to"), selection: $target) {
                    ForEach(DocumentTargetFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                if target == .pdf {
                    Picker(L("PDF pages"), selection: $pdfLayout) {
                        Text(verbatim: "A4").tag(PDFOutputLayout.a4)
                        Text(L("US Letter")).tag(PDFOutputLayout.letter)
                        Text(L("One long page")).tag(PDFOutputLayout.singlePage)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 460, maxHeight: target == .pdf ? 130 : 80)

            HStack {
                if isWorking {
                    Button(L("Stop")) {
                        task?.cancel()
                        renderer.cancel()
                    }
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("Convert \(files.count) Documents"), action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(files.isEmpty)
                }
                Spacer()
                Text(L("Saved to \(model.outputBaseDirectory.lastPathComponent) · originals are not changed"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FileResultsView(results: results)
        }
        .onDisappear {
            task?.cancel()
            renderer.cancel()
        }
        .reportsActivity(isWorking)
    }

    private func run() {
        let files = self.files, target = self.target, layout = self.pdfLayout
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        results = []

        task = Task {
            defer { isWorking = false }
            var batch: [FileResult] = []
            for url in files {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let saved: URL
                    if target == .pdf {
                        let preview = try await OfficeDocumentConverter.stageHTMLPreview(for: url)
                        defer { preview.cleanup() }
                        let data = try await renderer.renderFile(
                            preview.htmlURL,
                            readAccessDirectory: preview.readAccessDirectory
                        )
                        let base = url.deletingPathExtension().lastPathComponent
                        saved = try saveRenderedPDF(data, layout: layout, preferredName: "\(base).pdf", output: output, toolID: toolID)
                    } else {
                        saved = try await OfficeDocumentConverter.convertDocument(
                            url,
                            to: target,
                            output: output,
                            tool: toolID
                        )
                    }
                    batch.append(FileResult(source: url, output: saved, error: nil))
                } catch is CancellationError {
                    break
                } catch {
                    batch.append(FileResult(source: url, output: nil, error: error.localizedDescription))
                }
            }
            results = batch
        }
    }
}
