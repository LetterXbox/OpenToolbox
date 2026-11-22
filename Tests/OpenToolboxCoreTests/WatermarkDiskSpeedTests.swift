import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import OpenToolboxCore

/// RGBA bytes of an image, row 0 at the top.
private struct Pixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = bytes
    }

    /// Red, green and blue at a point measured from the bottom-left, like CoreGraphics.
    func rgb(x: Int, y: Int) -> (Int, Int, Int) {
        let offset = ((height - 1 - y) * width + x) * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    /// Mean brightness of a rectangle in CoreGraphics coordinates.
    func brightness(in rect: CGRect) -> Double {
        var total = 0
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let (r, g, b) = rgb(x: x, y: y)
                total += r + g + b
                count += 3
            }
        }
        return Double(total) / Double(max(count, 1))
    }
}

private func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

@Suite("Watermark")
struct WatermarkTests {
    @Test func framesFollowThePosition() {
        let canvas = CGSize(width: 1000, height: 500)
        let mark = CGSize(width: 200, height: 50)
        #expect(Watermark.frames(markSize: mark, canvas: canvas, position: .center) == [CGRect(x: 400, y: 225, width: 200, height: 50)])
        #expect(Watermark.frames(markSize: mark, canvas: canvas, position: .bottomRight) == [CGRect(x: 780, y: 20, width: 200, height: 50)])
        #expect(Watermark.frames(markSize: mark, canvas: canvas, position: .topLeft) == [CGRect(x: 20, y: 430, width: 200, height: 50)])
    }

    @Test func tilesCoverThePage() {
        let canvas = CGSize(width: 1000, height: 500)
        let frames = Watermark.frames(markSize: CGSize(width: 200, height: 50), canvas: canvas, position: .tiled)
        #expect(frames.count > 6)
        #expect(frames.allSatisfy { $0.intersects(CGRect(origin: .zero, size: canvas)) })
        #expect(frames.contains { $0.minY > 300 })
        #expect(frames.contains { $0.minX < 100 } && frames.contains { $0.maxX > 900 })
    }

    @Test func emptyTextIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "photo.png")
            try ImageProcessor.write(try makeTestImage(width: 120, height: 80), to: source, format: .png)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            #expect(throws: WatermarkError.emptyText) {
                try Watermark.apply(
                    toImage: source, options: WatermarkOptions(content: .text("  \n")), output: output, tool: "image.watermark")
            }
        }
    }

    @Test func textIsDrawnWhereChosenAndTheOriginalIsKept() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "photo.png")
            try ImageProcessor.write(try solidImage(width: 400, height: 200, red: 1, green: 1, blue: 1), to: source, format: .png)
            let before = try Data(contentsOf: source)
            let options = WatermarkOptions(
                content: .text("SAMPLE"), position: .bottomRight, opacity: 1, relativeWidth: 0.4, textColor: .black)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let result = try Watermark.apply(toImage: source, options: options, output: output, tool: "image.watermark")

            #expect(result.pathExtension == "png")
            #expect(try Data(contentsOf: source) == before)
            let pixels = try Pixels(try ImageProcessor.loadImage(at: result).image)
            #expect(pixels.width == 400 && pixels.height == 200)
            let mark = Watermark.frames(
                markSize: CGSize(width: 160, height: 40), canvas: CGSize(width: 400, height: 200), position: .bottomRight)[0]
            #expect(pixels.brightness(in: CGRect(x: mark.minX, y: 8, width: mark.width, height: 50)) < 220)
            #expect(pixels.brightness(in: CGRect(x: 10, y: 150, width: 100, height: 40)) == 255)
        }
    }

    @Test func imageWatermarkBlendsAtTheChosenOpacity() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "photo.png")
            try ImageProcessor.write(try solidImage(width: 300, height: 300, red: 1, green: 1, blue: 1), to: source, format: .png)
            let logo = directory.appending(path: "logo.png")
            try ImageProcessor.write(try solidImage(width: 50, height: 50, red: 0, green: 0, blue: 1), to: logo, format: .png)
            let options = WatermarkOptions(content: .image(logo), position: .center, opacity: 0.5, relativeWidth: 0.5)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let result = try Watermark.apply(toImage: source, options: options, output: output, tool: "image.watermark")

            let pixels = try Pixels(try ImageProcessor.loadImage(at: result).image)
            let (r, g, b) = pixels.rgb(x: 150, y: 150)
            #expect((100...175).contains(r) && (100...175).contains(g) && b > 240, "center was \(r), \(g), \(b)")
            let corner = pixels.rgb(x: 10, y: 10)
            #expect(corner.0 == 255 && corner.1 == 255 && corner.2 == 255)
        }
    }

    @Test func pdfPagesKeepTheirSizeAndGainSearchableText() async throws {
        try await withTemporaryDirectory { directory in
            let images = try (0..<3).map { _ in try makeTestImage(width: 300, height: 200) }
            let source = directory.appending(path: "report.pdf")
            try PDFTools.write(PDFTools.makePDF(fromImages: images, pageSize: .a4), to: source)
            let before = try Data(contentsOf: source)
            let original = try PDFTools.open(source)
            let options = WatermarkOptions(content: .text("CONFIDENTIAL"), position: .tiled, isDiagonal: true)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let result = try Watermark.apply(toPDF: source, options: options, output: output, tool: "image.watermark")

            #expect(try Data(contentsOf: source) == before)
            let marked = try PDFTools.open(result)
            #expect(marked.pageCount == 3)
            for index in 0..<3 {
                let page = try #require(marked.page(at: index))
                let originalPage = try #require(original.page(at: index))
                let size = page.bounds(for: .mediaBox).size
                let expected = originalPage.bounds(for: .mediaBox).size
                let quarterTurn = originalPage.rotation % 180 != 0
                #expect(abs(size.width - (quarterTurn ? expected.height : expected.width)) < 0.5)
                #expect(abs(size.height - (quarterTurn ? expected.width : expected.height)) < 0.5)
                #expect(page.string?.contains("CONFIDENTIAL") == true)
            }
        }
    }
}

@Suite("Disk speed test")
struct DiskSpeedTests {
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(DiskSpeedTest.Phase, Double)] = []

        func add(_ phase: DiskSpeedTest.Phase, _ fraction: Double) {
            lock.withLock { entries.append((phase, fraction)) }
        }

        var all: [(DiskSpeedTest.Phase, Double)] { lock.withLock { entries } }
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    @Test func measuresWriteAndReadAndLeavesNothingBehind() async throws {
        try await withTemporaryDirectory { directory in
            let log = ProgressLog()
            let result = try DiskSpeedTest.run(
                in: directory, volumeName: "Test", bytes: 4 * 1024 * 1024, blockSize: 1024 * 1024, reserve: 0,
                progress: { log.add($0, $1) })
            #expect(result.bytes == 4 * 1024 * 1024)
            #expect(result.writeBytesPerSecond > 0 && result.readBytesPerSecond > 0)
            #expect(try contents(of: directory).isEmpty)
            #expect(log.all.contains { $0.0 == .writing && $0.1 == 1 })
            #expect(log.all.last.map { $0.0 == .reading && $0.1 == 1 } == true)
        }
    }

    @Test func cancellingStopsTheTestAndLeavesNothingBehind() async throws {
        try await withTemporaryDirectory { directory in
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try DiskSpeedTest.run(
                    in: directory, volumeName: "Test", bytes: 64 * 1024 * 1024, blockSize: 1024 * 1024, reserve: 0)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            let leftovers = try contents(of: directory)
            #expect(leftovers.isEmpty)
        }
    }

    @Test func refusesWhenTheVolumeIsTooFull() throws {
        #expect(throws: DiskSpeedError.notEnoughSpace(needed: 100, available: 50)) {
            try DiskSpeedTest.checkSpace(needed: 100, available: 50, reserve: 0)
        }
        #expect(throws: DiskSpeedError.notEnoughSpace(needed: 150, available: 120)) {
            try DiskSpeedTest.checkSpace(needed: 100, available: 120, reserve: 50)
        }
        try DiskSpeedTest.checkSpace(needed: 100, available: 150, reserve: 50)
        try DiskSpeedTest.checkSpace(needed: 100, available: nil, reserve: 50)
    }

    @Test func reportsAFolderItCannotWriteTo() async throws {
        try await withTemporaryDirectory { directory in
            let missing = directory.appending(path: "missing", directoryHint: .isDirectory)
            #expect(throws: DiskSpeedError.cannotWrite("Test")) {
                try DiskSpeedTest.run(in: missing, volumeName: "Test", bytes: 1024 * 1024, reserve: 0)
            }
        }
    }

    @Test func listsTheStartupDiskFirstWithAWritableTestFolder() throws {
        let volumes = SpeedTestVolume.mounted()
        let startup = try #require(volumes.first)
        #expect(startup.mountPoint.path == "/")
        #expect(startup.testDirectory == FileManager.default.temporaryDirectory)
        #expect(!startup.isReadOnly)
    }
}
