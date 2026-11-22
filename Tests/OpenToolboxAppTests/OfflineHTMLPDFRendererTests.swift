import Foundation
import PDFKit
import Testing

@testable import OpenToolboxApp
@testable import OpenToolboxCore

@Suite("Offline HTML PDF renderer")
struct OfflineHTMLPDFRendererTests {
    @MainActor
    @Test func rendersDefaultMarkdownSampleOfflineToValidPDF() async throws {
        let sample = "# Hello OpenToolbox\n\nWrite or paste **Markdown** here.\n"
        let html = MarkdownHTML.renderDocument(sample, title: "Sample")
        let renderer = OfflineHTMLPDFRenderer()
        let pdfData = try await renderer.renderHTMLString(html)
        let document = try #require(PDFDocument(data: pdfData))
        #expect(document.pageCount >= 1)
        let text = PDFTools.text(of: document)
        #expect(text.contains("Hello OpenToolbox"))
    }
}
