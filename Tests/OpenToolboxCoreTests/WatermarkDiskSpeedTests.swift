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

extension WatermarkTests {
    @Test func positionedMarksStayInsideTheMargins() {
        let canvas = CGSize(width: 800, height: 400)
        let inset = 400 * Watermark.margin
        let room = CGRect(x: inset, y: inset, width: 800 - 2 * inset, height: 400 - 2 * inset)
        for diagonal in [false, true] {
            for position in WatermarkOptions.Position.allCases where position != .tiled {
                let options = WatermarkOptions(
                    content: .text("x"), position: position, relativeWidth: 0.6, isDiagonal: diagonal)
                let rects = Watermark.layout(aspectRatio: 0.5, canvas: canvas, options: options)
                #expect(rects.count == 1)
                let rect = rects[0]
                let footprint = diagonal ? (rect.width + rect.height) / 2.squareRoot() : 0
                let box = diagonal
                    ? CGRect(x: rect.midX - footprint / 2, y: rect.midY - footprint / 2, width: footprint, height: footprint)
                    : rect
                #expect(room.insetBy(dx: -0.01, dy: -0.01).contains(box), "\(position) diagonal \(diagonal): \(box)")
                #expect(abs(rect.width / rect.height - 0.5) < 0.001)
            }
        }
    }

    @Test(arguments: [
        (0, CGRect(x: 100, y: 150, width: 300, height: 200)),
        (90, CGRect(x: 150, y: 200, width: 200, height: 300)),
        (180, CGRect(x: 200, y: 450, width: 300, height: 200)),
        (270, CGRect(x: 450, y: 100, width: 200, height: 300)),
    ])
    func cropBoxesFollowThePageRotation(rotation: Int, expected: CGRect) {
        let media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let crop = CGRect(x: 100, y: 150, width: 300, height: 200)
        #expect(Watermark.outputRect(crop, media: media, rotation: rotation) == expected)
    }

    @Test func diagonalTilesStillCoverThePage() {
        let canvas = CGSize(width: 1000, height: 400)
        let options = WatermarkOptions(content: .text("x"), position: .tiled, relativeWidth: 0.4, isDiagonal: true)
        let rects = Watermark.layout(aspectRatio: 10, canvas: canvas, options: options)
        let rows = Set(rects.map { Int($0.minY.rounded()) })
        #expect(rows.count >= 3, "\(rows.sorted())")
    }

    @Test func aCropBoxOutsideThePageIsRefused() throws {
        let media = CGRect(x: 0, y: 0, width: 600, height: 800)
        #expect(throws: WatermarkError.noVisibleArea(page: 2)) {
            try Watermark.visibleArea(media: media, crop: CGRect(x: 700, y: 900, width: 100, height: 100), page: 2)
        }
        #expect(throws: WatermarkError.noVisibleArea(page: 1)) {
            try Watermark.visibleArea(media: media, crop: CGRect(x: 100, y: 100, width: 0, height: 50), page: 1)
        }
        #expect(try Watermark.visibleArea(media: media, crop: CGRect(x: 500, y: 700, width: 300, height: 300), page: 1)
            == CGRect(x: 500, y: 700, width: 100, height: 100))
    }

    @Test func multiFrameArtworkIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            let artwork = directory.appending(path: "logo.tiff")
            let destination = try #require(CGImageDestinationCreateWithURL(artwork as CFURL, "public.tiff" as CFString, 2, nil))
            CGImageDestinationAddImage(destination, try makeTestImage(width: 40, height: 40), nil)
            CGImageDestinationAddImage(destination, try makeTestImage(width: 40, height: 40), nil)
            #expect(CGImageDestinationFinalize(destination))
            let source = directory.appending(path: "photo.png")
            try ImageProcessor.write(try makeTestImage(width: 120, height: 80), to: source, format: .png)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            #expect(throws: WatermarkError.multipleImages("logo.tiff")) {
                try Watermark.apply(
                    toImage: source, options: WatermarkOptions(content: .image(artwork)), output: output, tool: "image.watermark")
            }
        }
    }

    @Test func pdfCopiesKeepTheCropBox() async throws {
        try await withTemporaryDirectory { directory in
            let document = PDFTools.makePDF(fromImages: [try makeTestImage(width: 600, height: 800)])
            let page = try #require(document.page(at: 0))
            let media = page.bounds(for: .mediaBox)
            let crop = CGRect(x: media.minX + 100, y: media.minY + 150, width: 300, height: 200)
            page.setBounds(crop, for: .cropBox)
            page.rotation = 90
            let source = directory.appending(path: "cropped.pdf")
            try PDFTools.write(document, to: source)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let result = try Watermark.apply(
                toPDF: source, options: WatermarkOptions(content: .text("COPY")), output: output, tool: "image.watermark")

            let marked = try #require(try PDFTools.open(result).page(at: 0))
            let markedCrop = marked.bounds(for: .cropBox)
            #expect(abs(markedCrop.width - 200) < 0.5 && abs(markedCrop.height - 300) < 0.5, "\(markedCrop)")
            #expect(marked.rotation == 0)
        }
    }

    @Test func multiFrameImagesAreRefused() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "pages.tiff")
            let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.tiff" as CFString, 2, nil))
            CGImageDestinationAddImage(destination, try makeTestImage(width: 40, height: 40), nil)
            CGImageDestinationAddImage(destination, try makeTestImage(width: 40, height: 40), nil)
            #expect(CGImageDestinationFinalize(destination))
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            #expect(throws: WatermarkError.multipleImages("pages.tiff")) {
                try Watermark.apply(
                    toImage: source, options: WatermarkOptions(content: .text("A")), output: output, tool: "image.watermark")
            }
        }
    }
}

@Suite("Disk speed test", .serialized)
struct DiskSpeedTests {
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(DiskSpeedTest.Phase, Double)] = []

        func add(_ phase: DiskSpeedTest.Phase, _ fraction: Double) {
            lock.withLock { entries.append((phase, fraction)) }
        }

        var all: [(DiskSpeedTest.Phase, Double)] { lock.withLock { entries } }
    }

    private final class SpaceReadings: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [Int64?]
        private(set) var count = 0

        init(_ readings: [Int64?]) {
            self.readings = readings
        }

        func next(_: Int32) -> Int64? {
            lock.withLock {
                count += 1
                return readings.count > 1 ? readings.removeFirst() : readings.first ?? nil
            }
        }
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    private func fileSystem(of directory: URL) throws -> UInt64 {
        try #require(DiskSpeedTest.fileSystemID(of: directory))
    }

    private let megabyte = 1024 * 1024

    @Test func measuresWriteAndReadAndLeavesNothingBehind() async throws {
        try await withTemporaryDirectory { directory in
            let log = ProgressLog()
            let result = try DiskSpeedTest.run(
                in: directory, volumeName: "Test", expectedFileSystem: try fileSystem(of: directory),
                bytes: Int64(4 * megabyte), blockSize: megabyte, reserve: 0, progress: { log.add($0, $1) })
            #expect(result.bytes == Int64(4 * megabyte))
            #expect(result.writeBytesPerSecond > 0 && result.readBytesPerSecond > 0)
            #expect(try contents(of: directory).isEmpty)
            #expect(log.all.contains { $0.0 == .writing && $0.1 == 1 })
            #expect(log.all.last.map { $0.0 == .reading && $0.1 == 1 } == true)
        }
    }

    @Test func cancellingStopsTheTestAndLeavesNothingBehind() async throws {
        try await withTemporaryDirectory { directory in
            let fileSystem = try fileSystem(of: directory)
            let megabyte = self.megabyte
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try DiskSpeedTest.run(
                    in: directory, volumeName: "Test", expectedFileSystem: fileSystem, bytes: Int64(64 * megabyte),
                    blockSize: megabyte, reserve: 0)
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
        #expect(throws: DiskSpeedError.spaceUnknown("Test")) {
            try DiskSpeedTest.checkSpace(needed: 100, available: nil, reserve: 50, volumeName: "Test")
        }
    }

    @Test func onlyOneTestRunsAtATime() async throws {
        try await withTemporaryDirectory { directory in
            let fileSystem = try fileSystem(of: directory)
            #expect(DiskSpeedTest.claim())
            #expect(throws: DiskSpeedError.alreadyRunning) {
                try DiskSpeedTest.run(
                    in: directory, volumeName: "Test", expectedFileSystem: fileSystem, bytes: Int64(megabyte), reserve: 0)
            }
            DiskSpeedTest.release()
            let leftovers = try contents(of: directory)
            #expect(leftovers.isEmpty)
            _ = try DiskSpeedTest.run(
                in: directory, volumeName: "Test", expectedFileSystem: fileSystem, bytes: Int64(megabyte),
                blockSize: megabyte, reserve: 0)
        }
    }

    @Test func refusesADifferentFileSystemThanTheOneChosen() async throws {
        try await withTemporaryDirectory { directory in
            let other = try fileSystem(of: directory) ^ 1
            #expect(throws: DiskSpeedError.volumeChanged("Test")) {
                try DiskSpeedTest.run(
                    in: directory, volumeName: "Test", expectedFileSystem: other, bytes: Int64(megabyte), reserve: 0)
            }
        }
    }

    @Test func stopsWritingWhenFreeSpaceDropsIntoTheReserve() async throws {
        try await withTemporaryDirectory { directory in
            let plenty = Int64(1) << 40
            let readings = SpaceReadings([plenty, plenty, 0])
            let log = ProgressLog()
            #expect(throws: DiskSpeedError.notEnoughSpace(needed: Int64(8 * megabyte) + 100, available: 0)) {
                try DiskSpeedTest.run(
                    in: directory, volumeName: "Test", expectedFileSystem: try fileSystem(of: directory),
                    bytes: Int64(16 * megabyte), blockSize: megabyte, reserve: 100, freeSpace: readings.next,
                    progress: { log.add($0, $1) })
            }
            #expect(readings.count == 3)
            #expect(log.all.contains { $0.0 == .writing && $0.1 == 0.5 })
            #expect(!log.all.contains { $0.0 == .reading })
            #expect(try contents(of: directory).isEmpty)
        }
    }

    @Test func stopsWritingWhenFreeSpaceCannotBeRead() async throws {
        try await withTemporaryDirectory { directory in
            let plenty = Int64(1) << 40
            let readings = SpaceReadings([plenty, plenty, nil])
            #expect(throws: DiskSpeedError.spaceUnknown("Test")) {
                try DiskSpeedTest.run(
                    in: directory, volumeName: "Test", expectedFileSystem: try fileSystem(of: directory),
                    bytes: Int64(16 * megabyte), blockSize: megabyte, reserve: 0, freeSpace: readings.next,
                    progress: { _, _ in })
            }
            #expect(try contents(of: directory).isEmpty)
        }
    }

    @Test func reportsAFolderItCannotWriteTo() async throws {
        try await withTemporaryDirectory { directory in
            let missing = directory.appending(path: "missing", directoryHint: .isDirectory)
            #expect(throws: DiskSpeedError.cannotWrite("Test")) {
                try DiskSpeedTest.run(
                    in: missing, volumeName: "Test", expectedFileSystem: 0, bytes: Int64(megabyte), reserve: 0)
            }
        }
    }

    @Test func listsTheStartupDiskFirstWithAWritableTestFolder() throws {
        let volumes = SpeedTestVolume.mounted()
        let startup = try #require(volumes.first)
        #expect(startup.mountPoint.path == "/")
        #expect(startup.testDirectory == FileManager.default.temporaryDirectory)
        #expect(!startup.isReadOnly)
        #expect(startup.fileSystemID == DiskSpeedTest.fileSystemID(of: FileManager.default.temporaryDirectory))
    }
}
