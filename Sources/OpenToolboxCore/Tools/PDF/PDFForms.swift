import CoreGraphics
import Foundation
import PDFKit

/// Form filling, flattening and page layout helpers for PDFKit documents.
public enum PDFForms {
    /// Number of form fields on every page.
    public static func fieldCount(in document: PDFDocument) -> Int {
        (0..<document.pageCount).reduce(0) { total, index in
            total + (document.page(at: index)?.annotations.filter { $0.type == "Widget" }.count ?? 0)
        }
    }

    /// Writes `document` to `url`. Flattening draws every form field and comment into the page,
    /// so the values can no longer be edited.
    public static func write(_ document: PDFDocument, to url: URL, flatten: Bool) throws {
        guard document.pageCount > 0 else { throw PDFToolError.empty }
        let options: [PDFDocumentWriteOption: Any] = flatten ? [.burnInAnnotationsOption: true] : [:]
        guard document.write(to: url, withOptions: options) else { throw PDFToolError.writeFailed }
    }
}

public enum PDFPagination {
    /// Cuts one tall page into pages of `pageSize`, scaled to the page width minus `margin`
    /// points on each side. Pages stay vector.
    public static func paginate(_ page: PDFPage, pageSize: CGSize, margin: CGFloat = 36, to url: URL) throws {
        let source = page.bounds(for: .mediaBox)
        let contentWidth = pageSize.width - 2 * margin
        let contentHeight = pageSize.height - 2 * margin
        guard source.width > 0, source.height > 0, contentWidth > 0, contentHeight > 0 else {
            throw PDFToolError.empty
        }
        let scale = contentWidth / source.width
        let sliceHeight = contentHeight / scale
        let count = max(1, Int((source.height / sliceHeight).rounded(.up)))
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw PDFToolError.writeFailed }
        for index in 0..<count {
            context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
            context.saveGState()
            context.clip(to: CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight))
            let sliceTop = source.maxY - CGFloat(index) * sliceHeight
            context.translateBy(x: margin, y: margin + contentHeight)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -source.minX, y: -sliceTop)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}
