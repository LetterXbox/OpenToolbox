import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import OpenToolboxCore

@Suite("PDF forms")
struct PDFFormsTests {
    func formDocument() throws -> PDFDocument {
        let document = try samplePDF(pages: 1)
        let page = try #require(document.page(at: 0))
        let field = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 150, height: 30), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "name"
        field.widgetStringValue = "Ada"
        page.addAnnotation(field)
        return document
    }

    @Test func keepsOrFlattensFields() async throws {
        try await withTemporaryDirectory { directory in
            let document = try formDocument()
            #expect(PDFForms.fieldCount(in: document) == 1)

            let filled = directory.appending(path: "filled.pdf")
            try PDFForms.write(document, to: filled, flatten: false)
            let reopened = try PDFTools.open(filled)
            #expect(PDFForms.fieldCount(in: reopened) == 1)
            let field = try #require(reopened.page(at: 0)?.annotations.first { $0.type == "Widget" })
            #expect(field.widgetStringValue == "Ada")

            let flat = directory.appending(path: "flat.pdf")
            try PDFForms.write(document, to: flat, flatten: true)
            let flattened = try PDFTools.open(flat)
            #expect(PDFForms.fieldCount(in: flattened) == 0)
            #expect(flattened.pageCount == 1)
            #expect(PDFForms.fieldCount(in: document) == 1)
        }
    }

    @Test func refusesEmptyDocuments() async throws {
        try await withTemporaryDirectory { directory in
            _ = #expect(throws: PDFToolError.empty) {
                try PDFForms.write(PDFDocument(), to: directory.appending(path: "x.pdf"), flatten: true)
            }
        }
    }
}

@Suite("PDF pagination")
struct PDFPaginationTests {
    @Test func cutsATallPageIntoPages() async throws {
        try await withTemporaryDirectory { directory in
            let tall = PDFTools.makePDF(fromImages: [try makeTestImage(width: 600, height: 3000)])
            let page = try #require(tall.page(at: 0))
            let url = directory.appending(path: "pages.pdf")
            let a4 = CGSize(width: 595.28, height: 841.89)
            try PDFPagination.paginate(page, pageSize: a4, margin: 36, to: url)
            let result = try PDFTools.open(url)
            let scale = (a4.width - 72) / 600
            let expected = Int((3000 / ((a4.height - 72) / scale)).rounded(.up))
            #expect(result.pageCount == expected)
            let bounds = try #require(result.page(at: 0)).bounds(for: .mediaBox)
            #expect(abs(bounds.width - a4.width) < 0.01)
            #expect(abs(bounds.height - a4.height) < 0.01)
        }
    }

    @Test func shortPageIsOnePage() async throws {
        try await withTemporaryDirectory { directory in
            let short = PDFTools.makePDF(fromImages: [try makeTestImage(width: 600, height: 200)])
            let url = directory.appending(path: "one.pdf")
            try PDFPagination.paginate(try #require(short.page(at: 0)), pageSize: CGSize(width: 612, height: 792), to: url)
            #expect(try PDFTools.open(url).pageCount == 1)
        }
    }
}
