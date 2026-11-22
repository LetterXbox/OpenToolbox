import AppKit
import CoreGraphics
import Foundation
import PDFKit

public enum PDFToolError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case locked(String)
    case invalidRange(String)
    case writeFailed
    case empty
    case pageTooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): coreLocalized("“\(name)” is not a readable PDF.")
        case .locked(let name): coreLocalized("“\(name)” is password-protected. Unlock it first.")
        case .invalidRange(let text): coreLocalized("“\(text)” is not a valid page range. Use forms like 1-3, 5, 8-.")
        case .writeFailed: coreLocalized("The PDF could not be saved.")
        case .empty: coreLocalized("There are no pages to save.")
        case .pageTooLarge: coreLocalized("This page cannot be rendered at the chosen resolution.")
        }
    }
}

/// Parses page selections such as `1-3, 5, 8-` (1-based, inclusive).
public enum PageRange {
    /// Returns 0-based page indices in the order written. An empty string selects every page.
    /// Descending ranges (`5-3`) are allowed and produce reversed order.
    public static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(0..<pageCount) }
        var result: [Int] = []
        for rawPart in trimmed.split(separator: ",") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            func page(_ value: String, default fallback: Int) throws -> Int {
                if value.isEmpty { return fallback }
                guard let number = Int(value), (1...max(pageCount, 1)).contains(number), pageCount > 0 else {
                    throw PDFToolError.invalidRange(text)
                }
                return number
            }
            if bounds.count == 1 {
                result.append(try page(bounds[0], default: -1) - 1)
            } else {
                guard !(bounds[0].isEmpty && bounds[1].isEmpty) else { throw PDFToolError.invalidRange(text) }
                let start = try page(bounds[0], default: 1)
                let end = try page(bounds[1], default: pageCount)
                if start <= end {
                    result.append(contentsOf: (start...end).map { $0 - 1 })
                } else {
                    result.append(contentsOf: (end...start).reversed().map { $0 - 1 })
                }
            }
        }
        return result
    }
}

public enum PDFPageSize: String, CaseIterable, Sendable, Identifiable {
    /// Each page matches its image.
    case fitImage
    case a4
    case letter

    public var id: String { rawValue }

    /// Size in PDF points (1/72 inch).
    var points: CGSize? {
        switch self {
        case .fitImage: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }
}

/// PDFKit page operations. Every function returns new documents; inputs are not modified on disk.
public enum PDFTools {
    public static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw PDFToolError.unreadable(url.lastPathComponent) }
        if document.isLocked { throw PDFToolError.locked(url.lastPathComponent) }
        return document
    }

    /// Pages of all documents, in order, as a new document.
    public static func merge(_ documents: [PDFDocument]) -> PDFDocument {
        let merged = PDFDocument()
        for document in documents {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        return merged
    }

    /// A new document with the given 0-based pages (in that order; repeats allowed).
    public static func extract(_ pages: [Int], from document: PDFDocument) -> PDFDocument {
        let result = PDFDocument()
        for index in pages where index >= 0 && index < document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            result.insert(page, at: result.pageCount)
        }
        return result
    }

    /// Splits into chunks of `pagesPerFile` pages.
    public static func split(_ document: PDFDocument, pagesPerFile: Int) -> [PDFDocument] {
        let size = max(1, pagesPerFile)
        return stride(from: 0, to: document.pageCount, by: size).map { start in
            extract(Array(start..<min(start + size, document.pageCount)), from: document)
        }
    }

    /// A copy with the given pages rotated by a multiple of 90 degrees.
    public static func rotate(_ pages: Set<Int>, by degrees: Int, in document: PDFDocument) -> PDFDocument {
        let result = extract(Array(0..<document.pageCount), from: document)
        for index in pages where index >= 0 && index < result.pageCount {
            guard let page = result.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        return result
    }

    /// Builds a PDF with one image per page.
    public static func makePDF(fromImages images: [CGImage], pageSize: PDFPageSize = .fitImage) -> PDFDocument {
        let document = PDFDocument()
        for cgImage in images {
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            var options: [PDFPage.ImageInitializationOption: Any] = [:]
            if let size = pageSize.points {
                // Orient the page like the image.
                let landscape = cgImage.width > cgImage.height
                let width = landscape ? size.height : size.width
                let height = landscape ? size.width : size.height
                options[.mediaBox] = NSValue(rect: NSRect(x: 0, y: 0, width: width, height: height))
                options[.upscaleIfSmaller] = true
            }
            let page = PDFPage(image: image, options: options) ?? PDFPage(image: image)
            if let page { document.insert(page, at: document.pageCount) }
        }
        return document
    }

    /// Largest rendered page: 20,000 px per side and 200 megapixels.
    static let maximumRenderSide: CGFloat = 20_000
    static let maximumRenderPixels: CGFloat = 200_000_000

    /// Renders a page at `dpi` (72 = 1 point per pixel), honoring page rotation.
    public static func render(_ page: PDFPage, dpi: CGFloat = 144) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let quarterTurn = page.rotation % 180 != 0
        let scale = dpi / 72
        let pixelWidth = ((quarterTurn ? bounds.height : bounds.width) * scale).rounded()
        let pixelHeight = ((quarterTurn ? bounds.width : bounds.height) * scale).rounded()
        // A damaged or hostile page box, or a bad DPI, must not trap the Int conversion or exhaust memory.
        guard dpi.isFinite, dpi > 0, pixelWidth.isFinite, pixelHeight.isFinite,
            pixelWidth >= 0, pixelHeight >= 0,
            pixelWidth <= maximumRenderSide, pixelHeight <= maximumRenderSide,
            pixelWidth * pixelHeight <= maximumRenderPixels
        else { throw PDFToolError.pageTooLarge }
        let width = max(1, Int(pixelWidth))
        let height = max(1, Int(pixelHeight))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PDFToolError.writeFailed }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // PDFKit applies the page's rotation and box origin when drawing.
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw PDFToolError.writeFailed }
        return image
    }

    public static func write(_ document: PDFDocument, to url: URL) throws {
        guard document.pageCount > 0 else { throw PDFToolError.empty }
        guard document.write(to: url) else { throw PDFToolError.writeFailed }
    }

    /// Text of every page in order. Pages with embedded text use it; image-only pages
    /// (scans) are rendered and recognized with Vision, so mixed documents lose nothing.
    public static func recognizeText(in document: PDFDocument, accurate: Bool = true, dpi: CGFloat = 200) throws
        -> String
    {
        try (0..<document.pageCount).compactMap { document.page(at: $0) }.map { page in
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !embedded.isEmpty { return embedded }
            return try TextRecognizer.recognize(in: try render(page, dpi: dpi), accurate: accurate)
                .map(\.text).joined(separator: "\n")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Text already embedded in the PDF (no OCR).
    public static func text(of document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
    }
}
