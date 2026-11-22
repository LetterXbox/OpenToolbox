import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import OpenToolboxCore

/// A detailed image that compresses measurably, so quality changes show in the file size.
func makeNoisyImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    var generator = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: height, by: 4) {
        for x in stride(from: 0, to: width, by: 4) {
            context.setFillColor(
                CGColor(
                    red: CGFloat.random(in: 0...1, using: &generator), green: CGFloat(x) / CGFloat(width),
                    blue: CGFloat(y) / CGFloat(height), alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
    }
    return try #require(context.makeImage())
}

func samplePDF(pages: Int) throws -> PDFDocument {
    PDFTools.makePDF(fromImages: try (0..<pages).map { _ in try makeTestImage(width: 200, height: 300) })
}

@Suite("Compress images")
struct CompressImagesTests {
    let tool: ToolID = "image.compress"

    @Test func jpegStaysJPEGAndShrinks() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "photo.jpg")
            try ImageProcessor.write(try makeNoisyImage(width: 800, height: 600), to: source, format: .jpeg, quality: 1)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let result = try ImageCompressor.compress(
                source, options: ImageCompressionOptions(quality: 0.3), output: output, tool: tool)
            let url = try #require(result.output)
            #expect(url.pathExtension == "jpg")
            #expect(result.compressedBytes < result.originalBytes)
            #expect(result.savedFraction > 0)
            let written = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(Int64(written) == result.compressedBytes)
            #expect(try ImageCompressor.fileSize(source) == result.originalBytes)
        }
    }

    @Test func pngFallsBackToHEICUnlessConverted() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "art.png")
            try ImageProcessor.write(try makeNoisyImage(width: 600, height: 400), to: source, format: .png)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let kept = try ImageCompressor.compress(
                source, options: ImageCompressionOptions(quality: 0.5), output: output, tool: tool)
            #expect(kept.output?.pathExtension == (ImageFormat.writable.contains(.heic) ? "heic" : "png"))
            let converted = try ImageCompressor.compress(
                source, options: ImageCompressionOptions(target: .convert(.jpeg), quality: 0.5), output: output,
                tool: tool)
            #expect(converted.output?.pathExtension == "jpg")
        }
    }

    @Test func largerResultIsNotWritten() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "tiny.jpg")
            try ImageProcessor.write(try makeNoisyImage(width: 400, height: 300), to: source, format: .jpeg, quality: 0.1)
            let base = directory.appending(path: "out")
            let result = try ImageCompressor.compress(
                source, options: ImageCompressionOptions(quality: 0.95, metadata: .keep),
                output: OutputDirectory(baseDirectory: base), tool: tool)
            #expect(result.output == nil)
            #expect(result.compressedBytes >= result.originalBytes)
            let written = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
            #expect(written.isEmpty)
        }
    }

    @Test func longEdgeLimitsSize() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "wide.jpg")
            try ImageProcessor.write(try makeNoisyImage(width: 1200, height: 600), to: source, format: .jpeg, quality: 1)
            let result = try ImageCompressor.compress(
                source, options: ImageCompressionOptions(quality: 0.8, longEdge: 300),
                output: OutputDirectory(baseDirectory: directory.appending(path: "out")), tool: tool)
            let url = try #require(result.output)
            let properties = ImageProcessor.properties(of: url)
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 300)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 150)
        }
    }
}

@Suite("PDF password")
struct PDFPasswordTests {
    let tool: ToolID = "pdf.password"

    func writeSample(_ directory: URL, pages: Int = 2) throws -> URL {
        let url = directory.appending(path: "report.pdf")
        try PDFTools.write(try samplePDF(pages: pages), to: url)
        return url
    }

    @Test func protectThenRemove() async throws {
        try await withTemporaryDirectory { directory in
            let source = try writeSample(directory)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let protected = try PDFSecurity.protect(
                source, with: PDFProtection(openPassword: "secret"), output: output, tool: tool)
            #expect(protected.lastPathComponent == "report protected.pdf")
            let locked = try #require(PDFDocument(url: protected))
            #expect(locked.isEncrypted)
            #expect(locked.isLocked)
            #expect(!locked.unlock(withPassword: "wrong"))
            #expect(locked.unlock(withPassword: "secret"))
            #expect(locked.pageCount == 2)
            #expect(try #require(PDFDocument(url: source)).isEncrypted == false)

            #expect(throws: PDFPasswordError.wrongPassword("report protected.pdf")) {
                try PDFSecurity.removePassword(protected, password: "nope", output: output, tool: tool)
            }
            let unlocked = try PDFSecurity.removePassword(protected, password: "secret", output: output, tool: tool)
            #expect(unlocked.lastPathComponent == "report protected unlocked.pdf")
            let plain = try #require(PDFDocument(url: unlocked))
            #expect(!plain.isEncrypted)
            #expect(plain.pageCount == 2)
        }
    }

    @Test func restrictionsNeedTheOwnerPassword() async throws {
        try await withTemporaryDirectory { directory in
            let source = try writeSample(directory)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let protection = PDFProtection(
                openPassword: "user", ownerPassword: "owner", allowsPrinting: false, allowsCopying: false)
            let protected = try PDFSecurity.protect(source, with: protection, output: output, tool: tool)
            let opened = try #require(PDFDocument(url: protected))
            #expect(opened.unlock(withPassword: "user"))
            #expect(!opened.allowsPrinting)
            #expect(!opened.allowsCopying)

            #expect(throws: PDFPasswordError.needsOwnerPassword("report protected.pdf")) {
                try PDFSecurity.removePassword(protected, password: "user", output: output, tool: tool)
            }
            let unlocked = try PDFSecurity.removePassword(protected, password: "owner", output: output, tool: tool)
            let plain = try #require(PDFDocument(url: unlocked))
            #expect(!plain.isEncrypted)
            #expect(plain.allowsPrinting)
            #expect(plain.allowsCopying)
        }
    }

    @Test func refusesEmptyAndUnprotected() async throws {
        try await withTemporaryDirectory { directory in
            let source = try writeSample(directory)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            #expect(throws: PDFPasswordError.emptyPassword) {
                try PDFSecurity.protect(source, with: PDFProtection(openPassword: ""), output: output, tool: tool)
            }
            #expect(throws: PDFPasswordError.notProtected("report.pdf")) {
                try PDFSecurity.removePassword(source, password: "x", output: output, tool: tool)
            }
        }
    }
}

@Suite("Delete PDF pages")
struct DeletePagesTests {
    @Test func deletesChosenPages() throws {
        let document = try samplePDF(pages: 4)
        let result = try PDFTools.delete([1, 3], from: document)
        #expect(result.pageCount == 2)
        #expect(document.pageCount == 4)
        #expect(throws: PDFToolError.empty) { try PDFTools.delete([0, 1, 2, 3], from: document) }
    }
}
