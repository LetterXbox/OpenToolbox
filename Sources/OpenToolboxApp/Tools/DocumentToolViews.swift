import ImageCaptureCore
import OpenToolboxCore
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Fill & Flatten Forms

private struct FormPDFView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

struct PDFFormsView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var document: PDFDocument?
    @State private var fieldCount = 0
    @State private var saved: URL?
    @State private var failure: String?

    var body: some View {
        ToolPage(tool: tool) {
            if document == nil {
                FileDropList(files: $files, allowedTypes: [.pdf], allowsMultiple: false, prompt: L("Drop a PDF form"))
            }
            if let document {
                HStack {
                    Text(fieldCount == 0 ? L("This PDF has no form fields.") : L("\(fieldCount) form fields"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Close")) { files = [] }
                    Button(L("Save Filled Copy")) { save(document, flatten: false) }
                    Button(L("Save Flattened Copy")) { save(document, flatten: true) }
                        .buttonStyle(.borderedProminent)
                        .help(L("Draws the filled-in fields and comments into the page, so they can't be changed."))
                }
                FormPDFView(document: document)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            if let failure { ErrorMessage(text: failure) }
            if let saved {
                HStack {
                    Label(L("Saved \(saved.lastPathComponent)"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
            }
        }
        .onChange(of: files) { load() }
    }

    private func load() {
        saved = nil
        failure = nil
        guard let url = files.first else {
            document = nil
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let opened = try PDFTools.open(url)
            document = opened
            fieldCount = PDFForms.fieldCount(in: opened)
        } catch {
            files = []
            failure = error.localizedDescription
        }
    }

    private func save(_ document: PDFDocument, flatten: Bool) {
        guard let source = files.first else { return }
        failure = nil
        let base = source.deletingPathExtension().lastPathComponent
        do {
            saved = try model.outputDirectory.writeNewFile(
                for: tool.id, preferredName: base + (flatten ? " flattened.pdf" : " filled.pdf")
            ) {
                try PDFForms.write(document, to: $0, flatten: flatten)
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Scan Document

@MainActor
@Observable
final class ScannerList: NSObject, ICDeviceBrowserDelegate {
    var scanners: [ICScannerDevice] = []
    @ObservationIgnored private let browser = ICDeviceBrowser()

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
                | ICDeviceLocationTypeMask.bonjour.rawValue | ICDeviceLocationTypeMask.shared.rawValue)
    }

    func start() { if !browser.isBrowsing { browser.start() } }
    func stop() { if browser.isBrowsing { browser.stop() } }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        let handoff = ScannerHandoff(device: scanner)
        Task { @MainActor in
            if !self.scanners.contains(handoff.device) { self.scanners.append(handoff.device) }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let handoff = ScannerHandoff(device: device)
        Task { @MainActor in self.scanners.removeAll { $0 === handoff.device } }
    }
}

/// ImageCaptureCore reports devices on the main thread; this carries them into a main-actor task.
private struct ScannerHandoff<Device: ICDevice>: @unchecked Sendable {
    let device: Device
}

private struct ScannerPane: NSViewRepresentable {
    let scanner: ICScannerDevice
    let onScan: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeNSView(context: Context) -> IKScannerDeviceView {
        let view = IKScannerDeviceView(frame: .zero)
        view.mode = .simple
        view.transferMode = .fileBased
        view.documentName = "Scan"
        view.delegate = context.coordinator
        view.scannerDevice = scanner
        return view
    }

    func updateNSView(_ view: IKScannerDeviceView, context: Context) {
        context.coordinator.onScan = onScan
        if view.scannerDevice !== scanner { view.scannerDevice = scanner }
    }

    @MainActor
    final class Coordinator: NSObject, IKScannerDeviceViewDelegate {
        var onScan: (URL) -> Void

        init(onScan: @escaping (URL) -> Void) {
            self.onScan = onScan
        }

        nonisolated func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didScanTo url: URL!, error: Error!) {
            guard error == nil, let url else { return }
            Task { @MainActor in self.onScan(url) }
        }
    }
}

struct ScanDocumentView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var scanners = ScannerList()
    @State private var selected: ICScannerDevice?
    @State private var pages: [ImageBox] = []
    @State private var saved: URL?
    @State private var failure: String?
    @State private var isSaving = false

    var body: some View {
        ToolPage(tool: tool) {
            HStack {
                Picker(L("Scanner"), selection: $selected) {
                    Text(L("None")).tag(ICScannerDevice?.none)
                    ForEach(scanners.scanners, id: \.self) { scanner in
                        Text(scanner.name ?? L("Scanner")).tag(Optional(scanner))
                    }
                }
                .frame(maxWidth: 340)
                if scanners.scanners.isEmpty {
                    Text(L("No scanners found.")).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let selected {
                ScannerPane(scanner: selected) { url in addScan(url) }
                    .frame(minHeight: 260)
            }
            Text(
                L(
                    "To scan with an iPhone or iPad, click below, then choose File → Import from iPhone or iPad → Scan Documents."
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        VStack(spacing: 4) {
                            Image(decorative: page.cgImage, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 120)
                                .shadow(radius: 1)
                            HStack(spacing: 4) {
                                Text(verbatim: "\(index + 1)").font(.caption).foregroundStyle(.secondary)
                                Button(L("Remove"), systemImage: "xmark.circle.fill") { pages.remove(at: index) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    if pages.isEmpty {
                        Text(L("Scanned pages appear here."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(8)
            }
            .frame(height: 160)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .focusable()
            .importsItemProviders([.image, .pdf]) { providers in
                importPages(providers)
                return true
            }

            HStack {
                Button(L("Save \(pages.count) Pages as PDF"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(pages.isEmpty || isSaving)
                Button(L("Clear")) { pages = [] }.disabled(pages.isEmpty)
                Spacer()
                if let saved {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
            }
            if let failure { ErrorMessage(text: failure) }
        }
        .onAppear { scanners.start() }
        .onDisappear { scanners.stop() }
        .reportsActivity(isSaving)
    }

    private func addScan(_ url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            pages.append(ImageBox(cgImage: try ImageProcessor.loadImage(at: url).image))
        } catch {
            failure = error.localizedDescription
        }
    }

    private func importPages(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                _ = provider.loadDataRepresentation(for: .pdf) { data, _ in
                    guard let data, let document = PDFDocument(data: data) else { return }
                    let images = (0..<document.pageCount).compactMap { index in
                        document.page(at: index).flatMap { try? PDFTools.render($0, dpi: 200) }
                    }
                    let boxes = images.map(ImageBox.init)
                    Task { @MainActor in pages += boxes }
                }
            } else {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else { return }
                    let box = ImageBox(cgImage: image)
                    Task { @MainActor in pages.append(box) }
                }
            }
        }
    }

    private func save() {
        let boxes = pages, output = model.outputDirectory, toolID = tool.id
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            let result = await runOffMain { () -> Result<URL, Error> in
                Result {
                    let document = PDFTools.makePDF(fromImages: boxes.map(\.cgImage), pageSize: .fitImage)
                    return try output.writeNewFile(for: toolID, preferredName: "Scan.pdf") {
                        try PDFTools.write(document, to: $0)
                    }
                }
            }
            switch result {
            case .success(let url): saved = url
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Web Page to PDF

@MainActor
final class WebPageRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    func render(_ url: URL, width: CGFloat) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        defer {
            webView.stopLoading()
            self.webView = nil
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 60))
        }
        try await Task.sleep(for: .seconds(1))
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

struct WebPageToPDFView: View {
    enum Layout: Hashable { case singlePage, a4, letter }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var address = ""
    @State private var layout: Layout = .a4
    @State private var width: CGFloat = 1024
    @State private var renderer = WebPageRenderer()
    @State private var isWorking = false
    @State private var saved: URL?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    private var url: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host() != nil
        else { return nil }
        return url
    }

    var body: some View {
        ToolPage(tool: tool) {
            TextField(L("Web address"), text: $address, prompt: Text(verbatim: "https://example.com"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
            Form {
                Picker(L("Pages"), selection: $layout) {
                    Text(verbatim: "A4").tag(Layout.a4)
                    Text(L("US Letter")).tag(Layout.letter)
                    Text(L("One long page")).tag(Layout.singlePage)
                }
                Picker(L("Page width"), selection: $width) {
                    Text(L("Desktop")).tag(CGFloat(1024))
                    Text(L("Wide")).tag(CGFloat(1440))
                    Text(L("Phone")).tag(CGFloat(390))
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 130)
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
                        .disabled(url == nil)
                }
                Spacer()
                if let saved {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
            }
            if let failure { ErrorMessage(text: failure) }
            Text(L("The page is loaded without your cookies or logins and nothing is kept afterwards."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onDisappear {
            task?.cancel()
            renderer.cancel()
        }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard let url, !isWorking else { return }
        let layout = self.layout, width = self.width, output = model.outputDirectory, toolID = tool.id
        isWorking = true
        failure = nil
        saved = nil
        task = Task {
            defer { isWorking = false }
            do {
                let data = try await renderer.render(url, width: width)
                let name = (url.host() ?? "Page").replacingOccurrences(of: "www.", with: "") + ".pdf"
                saved = try output.writeNewFile(for: toolID, preferredName: name) { destination in
                    switch layout {
                    case .singlePage:
                        try data.write(to: destination)
                    case .a4, .letter:
                        guard let page = PDFDocument(data: data)?.page(at: 0) else { throw PDFToolError.writeFailed }
                        let size =
                            layout == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792)
                        try PDFPagination.paginate(page, pageSize: size, to: destination)
                    }
                }
            } catch is CancellationError {
            } catch {
                failure = L("The page couldn't be saved: \(error.localizedDescription)")
            }
        }
    }
}
