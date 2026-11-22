import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import OpenToolboxCore

/// Builds a solid image with an optional black text label (for OCR tests).
func makeTestImage(width: Int, height: Int, text: String? = nil, fontSize: CGFloat = 48) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A colored block in the top-left corner so rotations are observable.
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: height - max(1, height / 4), width: max(1, width / 4), height: max(1, height / 4)))
    if let text {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 20, y: CGFloat(height) / 2 - fontSize / 3)
        CTLineDraw(line, context)
    }
    return try #require(context.makeImage())
}

/// Writes a JPEG with camera and GPS metadata.
func writeJPEGWithMetadata(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    let properties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "One"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:01:02 03:04:05"],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E",
        ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

@Suite("Image processor")
struct ImageProcessorTests {
    func dims(_ size: (width: Int, height: Int)) -> [Int] { [size.width, size.height] }

    @Test func targetSizes() {
        #expect(dims(ImageProcessor.targetSize(width: 400, height: 200, resize: .none)) == [400, 200])
        #expect(dims(ImageProcessor.targetSize(width: 400, height: 200, resize: .scale(0.5))) == [200, 100])
        #expect(dims(ImageProcessor.targetSize(width: 400, height: 200, resize: .longEdge(100))) == [100, 50])
        #expect(dims(ImageProcessor.targetSize(width: 400, height: 200, resize: .longEdge(1000))) == [400, 200])
        #expect(dims(ImageProcessor.targetSize(width: 400, height: 200, resize: .fit(maxWidth: 300, maxHeight: 50))) == [100, 50])
    }

    @Test func resizeRotateAndConvert() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "photo.jpg")
            try writeJPEGWithMetadata(try makeTestImage(width: 400, height: 200), to: source)

            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let options = ImageEditOptions(format: .png, resize: .longEdge(100), rotation: .clockwise90)
            let result = try ImageProcessor.process(source: source, options: options, output: output, tool: "image.convert")
            #expect(result.pathExtension == "png")
            let properties = ImageProcessor.properties(of: result)
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 50)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 100)
            // Source untouched.
            #expect(ImageProcessor.properties(of: source)[kCGImagePropertyPixelWidth] as? Int == 400)
        }
    }

    @Test func rotationMovesPixels() throws {
        // Red block starts top-left; after a clockwise quarter turn it is top-right.
        let image = try makeTestImage(width: 40, height: 20)
        let rotated = try ImageProcessor.render(image, options: ImageEditOptions(rotation: .clockwise90))
        #expect(rotated.width == 20 && rotated.height == 40)
        let data = try #require(rotated.dataProvider?.data as Data?)
        func red(x: Int, y: Int) -> UInt8 { data[y * rotated.bytesPerRow + x * 4] }
        func green(x: Int, y: Int) -> UInt8 { data[y * rotated.bytesPerRow + x * 4 + 1] }
        // Row 0 of the bitmap is the top of the image.
        #expect(red(x: 18, y: 1) > 200 && green(x: 18, y: 1) < 50)
        #expect(green(x: 1, y: 1) > 200)
    }

    @Test func stripsMetadata() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "geo.jpg")
            try writeJPEGWithMetadata(try makeTestImage(width: 64, height: 64), to: source)
            #expect(ImageProcessor.properties(of: source)[kCGImagePropertyGPSDictionary] != nil)

            let locationOnly = directory.appending(path: "no-gps.jpg")
            try ImageProcessor.process(
                source: source, destination: locationOnly, options: ImageEditOptions(metadata: .removeLocation))
            let kept = ImageProcessor.properties(of: locationOnly)
            #expect(kept[kCGImagePropertyGPSDictionary] == nil)
            let tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "TestCam")

            let stripped = directory.appending(path: "clean.jpg")
            try ImageProcessor.process(source: source, destination: stripped, options: ImageEditOptions(metadata: .removeAll))
            let clean = ImageProcessor.properties(of: stripped)
            #expect(clean[kCGImagePropertyGPSDictionary] == nil)
            let cleanTIFF = clean[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect(cleanTIFF?[kCGImagePropertyTIFFMake] == nil)
            let cleanExif = clean[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(cleanExif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        }
    }

    @Test func removeLocationStripsIPTCPlaceNames() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "place.jpg")
            let destination = try #require(
                CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
            let iptc: [CFString: Any] = [
                kCGImagePropertyIPTCCity: "Paris",
                kCGImagePropertyIPTCSubLocation: "Louvre",
                kCGImagePropertyIPTCProvinceState: "Île-de-France",
                kCGImagePropertyIPTCCountryPrimaryLocationName: "France",
                kCGImagePropertyIPTCCountryPrimaryLocationCode: "FRA",
                kCGImagePropertyIPTCCaptionAbstract: "A test caption",
            ]
            CGImageDestinationAddImage(
                destination, try makeTestImage(width: 32, height: 32),
                [kCGImagePropertyIPTCDictionary: iptc] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            let original = try #require(
                ImageProcessor.properties(of: source)[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
            #expect(original[kCGImagePropertyIPTCCity] as? String == "Paris")
            #expect(ImageProcessor.metadataSummary(ImageProcessor.properties(of: source)).map(\.label).contains("Location"))

            let noLocation = directory.appending(path: "no-location.jpg")
            try ImageProcessor.process(
                source: source, destination: noLocation, options: ImageEditOptions(metadata: .removeLocation))
            let kept = ImageProcessor.properties(of: noLocation)
            let keptIPTC = kept[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            for key in [
                kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
            ] {
                #expect(keptIPTC[key] == nil, "\(key) survived")
            }
            #expect(keptIPTC[kCGImagePropertyIPTCCaptionAbstract] as? String == "A test caption")
            #expect(!ImageProcessor.metadataSummary(kept).map(\.label).contains("Location"))

            let clean = directory.appending(path: "clean.jpg")
            try ImageProcessor.process(source: source, destination: clean, options: ImageEditOptions(metadata: .removeAll))
            let cleanIPTC = ImageProcessor.properties(of: clean)[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            #expect(cleanIPTC?.isEmpty ?? true)
        }
    }

    @Test func iptcLocationKeysAreRecognized() {
        #expect(ImageProcessor.isIPTCLocationKey(kCGImagePropertyIPTCCity))
        #expect(ImageProcessor.isIPTCLocationKey(kCGImagePropertyIPTCSubLocation))
        #expect(ImageProcessor.isIPTCLocationKey(kCGImagePropertyIPTCCountryPrimaryLocationName))
        #expect(ImageProcessor.isIPTCLocationKey(kCGImagePropertyIPTCContentLocationName))
        #expect(!ImageProcessor.isIPTCLocationKey(kCGImagePropertyIPTCCaptionAbstract))
        #expect(!ImageProcessor.isIPTCLocationKey(kCGImagePropertyIPTCKeywords))
        #expect(!ImageProcessor.isIPTCLocationKey(kCGImagePropertyIPTCCreatorContactInfo))
    }

    @Test func keepFormatUsesTheRealTypeNotTheFileName() async throws {
        try await withTemporaryDirectory { directory in
            // JPEG bytes behind a .png name.
            let source = directory.appending(path: "photo.png")
            try writeJPEGWithMetadata(try makeTestImage(width: 20, height: 20), to: source)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let result = try ImageProcessor.process(
                source: source, options: ImageEditOptions(), output: output, tool: "image.convert")
            #expect(result.lastPathComponent == "photo.jpg")
            let written = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
            #expect(CGImageSourceGetType(written) as String? == "public.jpeg")
        }
    }

    @Test func metadataSummary() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "geo.jpg")
            try writeJPEGWithMetadata(try makeTestImage(width: 10, height: 10), to: source)
            let labels = ImageProcessor.metadataSummary(ImageProcessor.properties(of: source)).map(\.label)
            #expect(labels.contains("Camera"))
            #expect(labels.contains("Location"))
        }
    }

    @Test func writableFormatsIncludeBasics() {
        #expect(ImageFormat.writable.contains(.png))
        #expect(ImageFormat.writable.contains(.jpeg))
    }
}

@Suite("Vision tools")
struct VisionToolTests {
    @Test func qrRoundTrip() throws {
        let image = try QRCode.generate("https://example.com/opentoolbox?x=1", correction: .high, moduleSize: 8)
        #expect(image.width == image.height)
        #expect(try QRCode.read(from: image) == ["https://example.com/opentoolbox?x=1"])
    }

    @Test func qrReadFindsNothingInBlankImage() throws {
        #expect(try QRCode.read(from: try makeTestImage(width: 200, height: 200)).isEmpty)
    }

    @Test func recognizesRenderedText() throws {
        let image = try makeTestImage(width: 900, height: 200, text: "OPEN TOOLBOX 2026", fontSize: 64)
        let text = try TextRecognizer.recognize(in: image).map(\.text).joined(separator: " ").uppercased()
        #expect(text.contains("TOOLBOX"))
        #expect(text.contains("2026"))
    }

    @Test func anonymizeChangesOnlyRegions() throws {
        let image = try makeTestImage(width: 100, height: 100)
        let output = try FaceBlur.anonymize(
            image, regions: [CGRect(x: 60, y: 10, width: 30, height: 30)], style: .solid, padding: 0)
        #expect(output.width == 100 && output.height == 100)
        let data = try #require(output.dataProvider?.data as Data?)
        let bytesPerPixel = output.bitsPerPixel / 8
        func pixel(_ x: Int, _ yFromTop: Int) -> UInt8 { data[yFromTop * output.bytesPerRow + x * bytesPerPixel + 1] }
        // Region (bottom-left origin y 10...40) is dark; the top-left corner area stays white/red.
        #expect(pixel(75, 75) < 30)
        #expect(pixel(50, 50) > 200)
    }
}

@Suite("PDF tools")
struct PDFToolTests {
    @Test(arguments: [
        ("", 5, [0, 1, 2, 3, 4]),
        ("1-3", 5, [0, 1, 2]),
        ("2, 4", 5, [1, 3]),
        ("4-", 5, [3, 4]),
        ("-2", 5, [0, 1]),
        ("5-3", 5, [4, 3, 2]),
        (" 1 , 1 ", 3, [0, 0]),
    ])
    func pageRanges(_ text: String, _ count: Int, _ expected: [Int]) throws {
        #expect(try PageRange.parse(text, pageCount: count) == expected)
    }

    @Test(arguments: ["0", "6", "a", "1-x", "-", "2-9"])
    func invalidPageRanges(_ text: String) {
        #expect(throws: PDFToolError.self) { try PageRange.parse(text, pageCount: 5) }
    }

    func sampleDocument(pages: Int) throws -> PDFDocument {
        let images = try (0..<pages).map { _ in try makeTestImage(width: 200, height: 300) }
        return PDFTools.makePDF(fromImages: images)
    }

    @Test func imagesToPDF() throws {
        let document = try sampleDocument(pages: 3)
        #expect(document.pageCount == 3)
        let a4 = PDFTools.makePDF(fromImages: [try makeTestImage(width: 300, height: 200)], pageSize: .a4)
        let bounds = try #require(a4.page(at: 0)).bounds(for: .mediaBox)
        #expect(bounds.width > bounds.height)  // landscape image → landscape A4
    }

    @Test func mergeExtractSplitRotate() throws {
        let merged = PDFTools.merge([try sampleDocument(pages: 2), try sampleDocument(pages: 3)])
        #expect(merged.pageCount == 5)
        #expect(PDFTools.extract([4, 0], from: merged).pageCount == 2)
        #expect(PDFTools.split(merged, pagesPerFile: 2).map(\.pageCount) == [2, 2, 1])
        let rotated = PDFTools.rotate([1], by: 90, in: merged)
        #expect(rotated.page(at: 1)?.rotation == 90)
        #expect(rotated.page(at: 0)?.rotation == 0)
        #expect(merged.page(at: 1)?.rotation == 0)  // original unchanged
    }

    /// PDF rotation is clockwise; the red marker starts in the page's top-left corner.
    @Test func recognizeTextReadsEmbeddedAndScannedPages() async throws {
        try await withTemporaryDirectory { directory in
            // Page 1 carries real (selectable) text drawn into a PDF context.
            let url = directory.appending(path: "cover.pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Embedded cover", attributes: attributes))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
            context.closePDF()

            let document = try PDFTools.open(url)
            #expect(document.page(at: 0)?.string?.contains("Embedded cover") == true)
            // Page 2 is image-only, like a scan.
            let scan = try makeTestImage(width: 900, height: 200, text: "SCANNED PAGE", fontSize: 64)
            let scanPage = try #require(PDFPage(image: NSImage(cgImage: scan, size: NSSize(width: 450, height: 100))))
            document.insert(scanPage, at: 1)

            let text = try PDFTools.recognizeText(in: document).uppercased()
            #expect(text.contains("EMBEDDED COVER"))
            #expect(text.contains("SCANNED"))
            let cover = try #require(text.range(of: "EMBEDDED"))
            let scanned = try #require(text.range(of: "SCANNED"))
            #expect(cover.lowerBound < scanned.lowerBound)
        }
    }

    @Test func renderRefusesHugePageBoxes() throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 1e30, height: 1e30), for: .mediaBox)
        #expect(throws: PDFToolError.pageTooLarge) { try PDFTools.render(page, dpi: 144) }
    }

    @Test func renderRefusesInvalidResolutions() throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        #expect(throws: PDFToolError.pageTooLarge) { try PDFTools.render(page, dpi: -1e20) }
        #expect(throws: PDFToolError.pageTooLarge) { try PDFTools.render(page, dpi: 0) }
        #expect(throws: PDFToolError.pageTooLarge) { try PDFTools.render(page, dpi: .nan) }
        let tiny = try PDFTools.render(page, dpi: 1)
        #expect(tiny.width >= 1 && tiny.height >= 1)
    }

    @Test func renderHonorsPageRotation() throws {
        let rotated = PDFTools.rotate([0], by: 90, in: try sampleDocument(pages: 1))
        let page = try #require(rotated.page(at: 0))
        let image = try PDFTools.render(page, dpi: 72)
        #expect(image.width == 300 && image.height == 200)
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int, _ yFromTop: Int) -> (UInt8, UInt8) {
            let offset = yFromTop * image.width * 4 + x * 4
            return (data[offset], data[offset + 1])
        }
        let topRight = rgb(image.width - 10, 10)
        let topLeft = rgb(10, 10)
        #expect(topRight.0 > 200 && topRight.1 < 60, "expected red marker top-right, got \(topRight)")
        #expect(topLeft.1 > 200, "expected white top-left, got \(topLeft)")
    }

    @Test func renderAndWrite() async throws {
        try await withTemporaryDirectory { directory in
            let document = try sampleDocument(pages: 2)
            let page = try #require(document.page(at: 0))
            let bounds = page.bounds(for: .mediaBox)
            let image = try PDFTools.render(page, dpi: 72)
            #expect(image.width == Int(bounds.width.rounded()))
            let url = directory.appending(path: "out.pdf")
            try PDFTools.write(document, to: url)
            #expect(try PDFTools.open(url).pageCount == 2)
            #expect(throws: PDFToolError.empty) { try PDFTools.write(PDFDocument(), to: directory.appending(path: "x.pdf")) }
        }
    }
}
