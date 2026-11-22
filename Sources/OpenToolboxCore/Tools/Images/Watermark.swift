import CoreGraphics
import CoreText
import Foundation
import PDFKit

public enum WatermarkError: Error, Equatable, LocalizedError {
    case emptyText
    case unsupportedFile(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText: coreLocalized("Enter the watermark text.")
        case .unsupportedFile(let name): coreLocalized("“\(name)” is not an image or a PDF.")
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

        /// The size the mark is drawn at on a canvas of `canvas`.
        func size(on canvas: CGSize, relativeWidth: Double) -> CGSize {
            let width = canvas.width * min(max(relativeWidth, 0.02), 1)
            return CGSize(width: width, height: width / max(aspectRatio, 0.0001))
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

    static func draw(_ mark: Mark, on canvas: CGSize, in context: CGContext, options: WatermarkOptions) {
        let size = mark.size(on: canvas, relativeWidth: options.relativeWidth)
        context.saveGState()
        context.setAlpha(min(max(options.opacity, 0), 1))
        for frame in frames(markSize: size, canvas: canvas, position: options.position) {
            mark.draw(in: context, frame: frame, diagonal: options.isDiagonal)
        }
        context.restoreGState()
    }

    // MARK: Images

    /// Watermarks one image into the output folder, keeping its format and metadata.
    public static func apply(
        toImage source: URL, options: WatermarkOptions, output: OutputDirectory, tool: ToolID
    ) throws -> URL {
        let mark = try Mark(options.content, color: options.textColor)
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
        draw(mark, on: canvas, in: context, options: options)
        guard let result = context.makeImage() else { throw ImageProcessingError.renderFailed }
        return result
    }

    // MARK: PDFs

    /// Watermarks every page of a PDF into the output folder. Page content stays vector.
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
            let bounds = page.bounds(for: .mediaBox)
            let quarterTurn = page.rotation % 180 != 0
            let canvas = CGSize(
                width: quarterTurn ? bounds.height : bounds.width, height: quarterTurn ? bounds.width : bounds.height)
            var box = CGRect(origin: .zero, size: canvas)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(pageInfo as CFDictionary)
            // PDFKit applies the page's rotation and box origin when drawing.
            page.draw(with: .mediaBox, to: context)
            draw(mark, on: canvas, in: context, options: options)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
