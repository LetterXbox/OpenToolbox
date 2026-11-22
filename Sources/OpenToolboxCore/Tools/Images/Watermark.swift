import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

public enum WatermarkError: Error, Equatable, LocalizedError {
    case emptyText
    case multipleImages(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText: coreLocalized("Enter the watermark text.")
        case .multipleImages(let name):
            coreLocalized("“\(name)” holds several images or frames. Watermark supports single images and PDFs.")
        }
    }
}

public struct WatermarkOptions: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case text(String)
        /// An image file, drawn with its transparency.
        case image(URL)
    }

    public enum Position: String, CaseIterable, Sendable, Identifiable {
        case topLeft, top, topRight
        case left, center, right
        case bottomLeft, bottom, bottomRight
        /// Repeats the watermark across the whole page.
        case tiled

        public var id: String { rawValue }
    }

    public enum TextColor: String, CaseIterable, Sendable, Identifiable {
        case white, gray, black

        public var id: String { rawValue }

        var cgColor: CGColor {
            switch self {
            case .white: CGColor(gray: 1, alpha: 1)
            case .gray: CGColor(gray: 0.5, alpha: 1)
            case .black: CGColor(gray: 0, alpha: 1)
            }
        }
    }

    public var content: Content
    public var position: Position
    /// 0 (invisible) to 1 (opaque).
    public var opacity: Double
    /// The watermark's width as a fraction of the page or image width.
    public var relativeWidth: Double
    /// Turns the watermark 45° counterclockwise.
    public var isDiagonal: Bool
    public var textColor: TextColor

    public init(
        content: Content, position: Position = .center, opacity: Double = 0.4, relativeWidth: Double = 0.4,
        isDiagonal: Bool = false, textColor: TextColor = .gray
    ) {
        self.content = content
        self.position = position
        self.opacity = opacity
        self.relativeWidth = relativeWidth
        self.isDiagonal = isDiagonal
        self.textColor = textColor
    }
}

/// Adds a text or image watermark to images and PDFs. Inputs are never modified.
public enum Watermark {
    /// Margin from the edges, as a fraction of the shorter side.
    static let margin = 0.04

    /// Where the watermark goes on a canvas, in CoreGraphics coordinates (origin bottom-left).
    /// Tiled watermarks return one rectangle per tile.
    public static func frames(
        markSize: CGSize, canvas: CGSize, position: WatermarkOptions.Position
    ) -> [CGRect] {
        let inset = min(canvas.width, canvas.height) * margin
        let width = markSize.width
        let height = markSize.height
        guard position != .tiled else {
            let stepX = width * 1.5
            let stepY = max(height * 3, 1)
            var frames: [CGRect] = []
            var row = 0
            var y = inset
            while y < canvas.height {
                var x = (row % 2 == 0 ? inset : inset + stepX / 2) - stepX
                while x < canvas.width {
                    if x + width > 0 { frames.append(CGRect(x: x, y: y, width: width, height: height)) }
                    x += max(stepX, 1)
                }
                y += stepY
                row += 1
            }
            return frames
        }
        let x: CGFloat =
            switch position {
            case .topLeft, .left, .bottomLeft: inset
            case .top, .center, .bottom, .tiled: (canvas.width - width) / 2
            case .topRight, .right, .bottomRight: canvas.width - inset - width
            }
        let y: CGFloat =
            switch position {
            case .bottomLeft, .bottom, .bottomRight: inset
            case .left, .center, .right, .tiled: (canvas.height - height) / 2
            case .topLeft, .top, .topRight: canvas.height - inset - height
            }
        return [CGRect(x: x, y: y, width: width, height: height)]
    }

    /// A loaded watermark, ready to draw at any size.
    struct Mark {
        enum Kind {
            case text(String, CGColor)
            case image(CGImage)
        }

        let kind: Kind
        /// Width divided by height.
        let aspectRatio: CGFloat

        init(_ content: WatermarkOptions.Content, color: WatermarkOptions.TextColor) throws {
            switch content {
            case .text(let raw):
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw WatermarkError.emptyText }
                kind = .text(text, color.cgColor)
                let bounds = Mark.lineBounds(text, fontSize: 100, color: color.cgColor)
                aspectRatio = bounds.width / max(bounds.height, 1)
            case .image(let url):
                let image = try ImageProcessor.loadImage(at: url).image
                kind = .image(image)
                aspectRatio = CGFloat(image.width) / CGFloat(max(image.height, 1))
            }
        }

        static func line(_ text: String, fontSize: CGFloat, color: CGColor) -> CTLine {
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }

        static func lineBounds(_ text: String, fontSize: CGFloat, color: CGColor) -> CGRect {
            CTLineGetBoundsWithOptions(line(text, fontSize: fontSize, color: color), .useGlyphPathBounds)
        }

        func draw(in context: CGContext, frame: CGRect, diagonal: Bool) {
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: frame.midX, y: frame.midY)
            if diagonal { context.rotate(by: .pi / 4) }
            let local = CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
            switch kind {
            case .image(let image):
                context.interpolationQuality = .high
                context.draw(image, in: local)
            case .text(let text, let color):
                let reference = Mark.lineBounds(text, fontSize: 100, color: color)
                let fontSize = 100 * frame.width / max(reference.width, 1)
                let line = Mark.line(text, fontSize: fontSize, color: color)
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: local.minX - bounds.minX, y: local.minY - bounds.minY)
                CTLineDraw(line, context)
            }
        }
    }

    /// The rectangle of each watermark copy before any diagonal turn. A positioned mark is scaled
    /// down when needed so that it, turned if diagonal, fits inside the margins.
    public static func layout(aspectRatio: CGFloat, canvas: CGSize, options: WatermarkOptions) -> [CGRect] {
        let aspect = max(aspectRatio, 0.0001)
        var width = canvas.width * min(max(options.relativeWidth, 0.02), 1)
        var height = width / aspect
        func footprint(_ width: CGFloat, _ height: CGFloat) -> CGSize {
            guard options.isDiagonal else { return CGSize(width: width, height: height) }
            let side = (width + height) / 2.squareRoot()
            return CGSize(width: side, height: side)
        }
        if options.position != .tiled {
            let inset = min(canvas.width, canvas.height) * margin
            let room = CGSize(width: canvas.width - 2 * inset, height: canvas.height - 2 * inset)
            let needed = footprint(width, height)
            let scale = max(0, min(1, room.width / needed.width, room.height / needed.height))
            width *= scale
            height *= scale
        }
        return frames(markSize: footprint(width, height), canvas: canvas, position: options.position).map { box in
            CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
        }
    }

    /// Draws the watermark over `area`, the visible part of the page or image.
    static func draw(_ mark: Mark, over area: CGRect, in context: CGContext, options: WatermarkOptions) {
        context.saveGState()
        context.translateBy(x: area.minX, y: area.minY)
        context.setAlpha(min(max(options.opacity, 0), 1))
        for frame in layout(aspectRatio: mark.aspectRatio, canvas: area.size, options: options) {
            mark.draw(in: context, frame: frame, diagonal: options.isDiagonal)
        }
        context.restoreGState()
    }

    /// Watermarks one image into the output folder, keeping its format and metadata.
    public static func apply(
        toImage source: URL, options: WatermarkOptions, output: OutputDirectory, tool: ToolID
    ) throws -> URL {
        let mark = try Mark(options.content, color: options.textColor)
        if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(imageSource) > 1 {
            throw WatermarkError.multipleImages(source.lastPathComponent)
        }
        let loaded = try ImageProcessor.loadImage(at: source)
        let format = ImageProcessor.resolvedFormat(nil, sourceType: loaded.type)
        let rendered = try render(loaded.image, mark: mark, options: options, opaque: !format.supportsAlpha)
        let metadata = ImageProcessor.filteredMetadata(loaded.properties, mode: .keep)
        return try output.writeOutput(forSource: source, tool: tool, newExtension: format.fileExtension) {
            try ImageProcessor.write(rendered, to: $0, format: format, quality: 0.92, metadata: metadata)
        }
    }

    static func render(_ image: CGImage, mark: Mark, options: WatermarkOptions, opaque: Bool) throws -> CGImage {
        let colorSpace: CGColorSpace =
            image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ImageProcessingError.renderFailed }
        let canvas = CGSize(width: image.width, height: image.height)
        if opaque {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvas))
        }
        context.draw(image, in: CGRect(origin: .zero, size: canvas))
        draw(mark, over: CGRect(origin: .zero, size: canvas), in: context, options: options)
        guard let result = context.makeImage() else { throw ImageProcessingError.renderFailed }
        return result
    }

    /// Watermarks every page of a PDF into the output folder. Page content stays vector, and each
    /// page keeps its crop box, so the copy shows the same area as the original.
    public static func apply(
        toPDF source: URL, options: WatermarkOptions, output: OutputDirectory, tool: ToolID
    ) throws -> URL {
        let mark = try Mark(options.content, color: options.textColor)
        let document = try PDFTools.open(source)
        guard document.pageCount > 0 else { throw PDFToolError.empty }
        return try output.writeOutput(forSource: source, tool: tool, newExtension: "pdf") { url in
            try write(document, mark: mark, options: options, to: url)
        }
    }

    static func write(_ document: PDFDocument, mark: Mark, options: WatermarkOptions, to url: URL) throws {
        var info: [CFString: Any] = [kCGPDFContextCreator: "OpenToolbox"]
        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle] = title }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor] = author }
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw PDFToolError.writeFailed
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let visible = page.bounds(for: .cropBox).intersection(media)
            let rotation = ((page.rotation % 360) + 360) % 360
            var mediaBox = outputRect(media, media: media, rotation: rotation)
            var cropBox = outputRect(visible.isNull ? media : visible, media: media, rotation: rotation)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size),
                kCGPDFContextCropBox: Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size),
            ]
            context.beginPDFPage(pageInfo as CFDictionary)
            // PDFKit applies the page's rotation and box origin when drawing.
            page.draw(with: .mediaBox, to: context)
            draw(mark, over: cropBox, in: context, options: options)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Where a rectangle in a page's own space lands on the upright output page, whose media box
    /// starts at the origin. `rotation` is the page's clockwise turn in degrees.
    static func outputRect(_ rect: CGRect, media: CGRect, rotation: Int) -> CGRect {
        let x0 = rect.minX - media.minX
        let x1 = rect.maxX - media.minX
        let y0 = rect.minY - media.minY
        let y1 = rect.maxY - media.minY
        let width = media.width
        let height = media.height
        switch rotation {
        case 90: return CGRect(x: y0, y: width - x1, width: y1 - y0, height: x1 - x0)
        case 180: return CGRect(x: width - x1, y: height - y1, width: x1 - x0, height: y1 - y0)
        case 270: return CGRect(x: height - y1, y: x0, width: y1 - y0, height: x1 - x0)
        default: return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }
}
