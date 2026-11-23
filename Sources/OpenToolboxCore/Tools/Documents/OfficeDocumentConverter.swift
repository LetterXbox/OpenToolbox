import Foundation

public enum OfficeDocumentError: Error, Equatable, LocalizedError {
    case previewUnavailable(String)
    case unsupportedConversion(from: String, to: String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .previewUnavailable(let name):
            coreLocalized("macOS Quick Look could not generate a preview for “\(name)”.")
        case .unsupportedConversion(let from, let to):
            coreLocalized("Converting from \(from) to \(to) is not supported.")
        case .conversionFailed(let detail):
            detail
        }
    }
}

public enum DocumentTargetFormat: String, CaseIterable, Sendable, Identifiable {
    case pdf
    case docx
    case rtf
    case html
    case odt
    case txt
    case md

    public var id: String { rawValue }

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .pdf: coreLocalized("PDF")
        case .docx: coreLocalized("Word (.docx)")
        case .rtf: coreLocalized("Rich Text (.rtf)")
        case .html: coreLocalized("HTML (.html)")
        case .odt: coreLocalized("OpenDocument (.odt)")
        case .txt: coreLocalized("Plain Text (.txt)")
        case .md: coreLocalized("Markdown (.md, plain text from rich documents)")
        }
    }

    var textutilFormat: String? {
        switch self {
        case .docx: "docx"
        case .rtf: "rtf"
        case .html: "html"
        case .odt: "odt"
        case .txt: "txt"
        case .pdf, .md: nil
        }
    }
}

/// Staged HTML preview of an Office or rich document, owned until cleaned up by the caller.
public struct StagedHTMLPreview: Sendable {
    public let htmlURL: URL
    public let readAccessDirectory: URL
    public let stagingDirectory: URL

    public init(htmlURL: URL, readAccessDirectory: URL, stagingDirectory: URL) {
        self.htmlURL = htmlURL
        self.readAccessDirectory = readAccessDirectory
        self.stagingDirectory = stagingDirectory
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}

/// Converts Office and text documents natively on macOS using Quick Look (`qlmanage`),
/// `/usr/bin/textutil`, and `swift-markdown` with zero external engine downloads.
public enum OfficeDocumentConverter {
    public typealias Runner = @Sendable (URL, [String]) async throws -> EngineProcessResult

    private static let qlmanageURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    private static let textutilURL = URL(fileURLWithPath: "/usr/bin/textutil")
    private static let textutilReadableExtensions: Set<String> = [
        "doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "txt", "text", "webarchive", "xml",
    ]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public static func qlmanageArguments(input: URL, outputDirectory: URL) -> [String] {
        ["-p", "-o", outputDirectory.path, input.path]
    }

    public static func textutilArguments(input: URL, output: URL, format: String) -> [String] {
        ["-convert", format, "-noload", "-output", output.path, input.path]
    }

    /// Generates an offline HTML preview for `.docx`, `.doc`, `.pptx`, `.ppt`, `.xlsx`, `.xls`,
    /// `.odt`, `.rtf`, `.md`, `.html`, or `.txt` so `WKWebView` can render it to PDF.
    public static func stageHTMLPreview(
        for source: URL,
        runner: Runner = { exe, args in try await EngineProcess.run(exe, arguments: args) }
    ) async throws -> StagedHTMLPreview {
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL.temporaryDirectory,
            create: true
        )
        do {
            let ext = source.pathExtension.lowercased()
            if markdownExtensions.contains(ext) {
                let text = try String(contentsOf: source, encoding: .utf8)
                let html = MarkdownHTML.renderDocument(text, title: source.deletingPathExtension().lastPathComponent)
                let htmlURL = staging.appending(path: "Preview.html", directoryHint: .notDirectory)
                try html.write(to: htmlURL, atomically: true, encoding: .utf8)
                return StagedHTMLPreview(htmlURL: htmlURL, readAccessDirectory: staging, stagingDirectory: staging)
            }

            if ext == "txt" || ext == "text" {
                let text = try String(contentsOf: source, encoding: .utf8)
                let html = plainTextHTML(text, title: source.deletingPathExtension().lastPathComponent)
                let htmlURL = staging.appending(path: "Preview.html", directoryHint: .notDirectory)
                try html.write(to: htmlURL, atomically: true, encoding: .utf8)
                return StagedHTMLPreview(htmlURL: htmlURL, readAccessDirectory: staging, stagingDirectory: staging)
            }

            if ext == "html" || ext == "htm" {
                let htmlURL = staging.appending(path: "Preview.html", directoryHint: .notDirectory)
                try FileManager.default.copyItem(at: source, to: htmlURL)
                return StagedHTMLPreview(htmlURL: htmlURL, readAccessDirectory: staging, stagingDirectory: staging)
            }

            let qlResult = try await runner(qlmanageURL, qlmanageArguments(input: source, outputDirectory: staging))
            if qlResult.exitCode == 0, let found = findQuickLookHTML(in: staging) {
                return StagedHTMLPreview(
                    htmlURL: found,
                    readAccessDirectory: found.deletingLastPathComponent(),
                    stagingDirectory: staging
                )
            }

            if textutilReadableExtensions.contains(ext) {
                let fallbackHTML = staging.appending(path: "Preview.html", directoryHint: .notDirectory)
                let tuResult = try await runner(textutilURL, textutilArguments(input: source, output: fallbackHTML, format: "html"))
                if tuResult.exitCode == 0,
                   FileManager.default.fileExists(atPath: fallbackHTML.path),
                   (try? fallbackHTML.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0
                {
                    return StagedHTMLPreview(htmlURL: fallbackHTML, readAccessDirectory: staging, stagingDirectory: staging)
                }
            }

            throw OfficeDocumentError.previewUnavailable(source.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Converts between non-PDF document formats (`.docx`, `.rtf`, `.html`, `.odt`, `.txt`, `.md`).
    public static func convertDocument(
        _ source: URL,
        to target: DocumentTargetFormat,
        output: OutputDirectory,
        tool: ToolID,
        runner: Runner = { exe, args in try await EngineProcess.run(exe, arguments: args) }
    ) async throws -> URL {
        guard target != .pdf else {
            throw OfficeDocumentError.unsupportedConversion(from: source.pathExtension.lowercased(), to: target.fileExtension)
        }
        let ext = source.pathExtension.lowercased()
        let base = source.deletingPathExtension().lastPathComponent
        let preferredName = "\(base).\(target.fileExtension)"

        if markdownExtensions.contains(ext) {
            let markdown = try String(contentsOf: source, encoding: .utf8)
            switch target {
            case .md:
                return try output.writeNewFile(for: tool, preferredName: preferredName) { destination in
                    try markdown.write(to: destination, atomically: true, encoding: .utf8)
                }
            case .html:
                let html = MarkdownHTML.renderDocument(markdown, title: base)
                return try output.writeNewFile(for: tool, preferredName: preferredName) { destination in
                    try html.write(to: destination, atomically: true, encoding: .utf8)
                }
            case .docx, .rtf, .odt, .txt:
                guard let fmt = target.textutilFormat else {
                    throw OfficeDocumentError.unsupportedConversion(from: ext, to: target.fileExtension)
                }
                let staging = try makeStaging(appropriateFor: output.baseDirectory)
                defer { try? FileManager.default.removeItem(at: staging) }
                let intermediateHTML = staging.appending(path: "source.html", directoryHint: .notDirectory)
                try MarkdownHTML.renderDocument(markdown, title: base)
                    .write(to: intermediateHTML, atomically: true, encoding: .utf8)
                let tempOut = staging.appending(path: "converted.\(target.fileExtension)", directoryHint: .notDirectory)
                let result = try await runner(textutilURL, textutilArguments(input: intermediateHTML, output: tempOut, format: fmt))
                guard result.exitCode == 0, FileManager.default.fileExists(atPath: tempOut.path) else {
                    throw OfficeDocumentError.conversionFailed(
                        result.stderrString.isEmpty ? coreLocalized("Document conversion failed.") : result.stderrString
                    )
                }
                return try output.writeNewFile(for: tool, preferredName: preferredName) { destination in
                    try FileManager.default.moveItem(at: tempOut, to: destination)
                }
            case .pdf:
                throw OfficeDocumentError.unsupportedConversion(from: ext, to: "pdf")
            }
        }

        guard textutilReadableExtensions.contains(ext) else {
            throw OfficeDocumentError.unsupportedConversion(from: ext, to: target.fileExtension)
        }

        let staging = try makeStaging(appropriateFor: output.baseDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        let targetFormat = target == .md ? "txt" : (target.textutilFormat ?? "txt")
        let tempOut = staging.appending(path: "converted.\(targetFormat)", directoryHint: .notDirectory)
        let result = try await runner(textutilURL, textutilArguments(input: source, output: tempOut, format: targetFormat))
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: tempOut.path) else {
            throw OfficeDocumentError.conversionFailed(
                result.stderrString.isEmpty ? coreLocalized("Document conversion failed.") : result.stderrString
            )
        }
        return try output.writeNewFile(for: tool, preferredName: preferredName) { destination in
            try FileManager.default.moveItem(at: tempOut, to: destination)
        }
    }

    static func findQuickLookHTML(in staging: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for item in items {
            let preview = item.appending(path: "Preview.html", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: preview.path),
               let size = try? preview.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0
            {
                return preview
            }
            if item.lastPathComponent == "Preview.html",
               let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0
            {
                return item
            }
        }
        return nil
    }

    static func plainTextHTML(_ text: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline';">
        <title>\(MarkdownHTML.escapeHTML(title))</title>
        <style>
        body {
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            font-size: 12px;
            line-height: 1.5;
            color: #1c1c1e;
            background: #ffffff;
            margin: 0;
            padding: 24px 32px;
        }
        pre { white-space: pre-wrap; word-wrap: break-word; margin: 0; }
        </style>
        </head>
        <body><pre>\(MarkdownHTML.escapeHTML(text))</pre></body>
        </html>
        """
    }

    private static func makeStaging(appropriateFor base: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: base,
            create: true
        )
    }
}
