import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Sendable, Identifiable {
    case png, jpeg, heic, tiff, gif, bmp

    public var id: String { rawValue }

    public var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    public var displayName: String { rawValue.uppercased() }

    public var supportsQuality: Bool { self == .jpeg || self == .heic }
    public var supportsAlpha: Bool { self == .png || self == .heic || self == .tiff || self == .gif }

    /// Formats this Mac's ImageIO can write.
    public static var writable: [ImageFormat] {
        let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { identifiers.contains($0.utType.identifier) }
    }

    public init?(utType: UTType) {
        guard let match = Self.allCases.first(where: { utType.conforms(to: $0.utType) }) else { return nil }
        self = match
    }
}

public enum ImageProcessingError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case cannotEncode(String)
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): coreLocalized("“\(name)” could not be read as an image.")
        case .cannotEncode(let format): coreLocalized("This Mac cannot write \(format) images.")
        case .renderFailed: coreLocalized("The image could not be rendered.")
        }
    }
}

public struct ImageEditOptions: Equatable, Sendable {
    public enum Resize: Equatable, Sendable {
        case none
        /// Multiply both dimensions, for example 0.5.
        case scale(Double)
        /// Fit inside the box, keeping the aspect ratio. Never upscales.
        case fit(maxWidth: Int, maxHeight: Int)
        /// Limit the longest edge. Never upscales.
        case longEdge(Int)
    }

    public enum Rotation: Int, CaseIterable, Sendable, Identifiable {
        case none = 0
        case clockwise90 = 90
        case upsideDown = 180
        case counterclockwise90 = 270
        public var id: Int { rawValue }
    }

    public enum Metadata: Equatable, Sendable {
        /// Keep camera and descriptive metadata.
        case keep
        /// Keep everything except GPS location.
        case removeLocation
        /// Write pixels only.
        case removeAll
    }

    /// `nil` keeps the source format (falling back to PNG if it cannot be written).
    public var format: ImageFormat?
    /// Lossy quality 0...1 for JPEG and HEIC.
    public var quality: Double
    public var resize: Resize
    public var rotation: Rotation
    public var flipHorizontal: Bool
    public var metadata: Metadata

    public init(
        format: ImageFormat? = nil, quality: Double = 0.85, resize: Resize = .none, rotation: Rotation = .none,
        flipHorizontal: Bool = false, metadata: Metadata = .keep
    ) {
        self.format = format
        self.quality = quality
        self.resize = resize
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.metadata = metadata
    }
}

/// ImageIO/CoreGraphics image conversion. Inputs are never modified.
public enum ImageProcessor {
    /// Loads the first frame with its EXIF orientation applied.
    public static func loadImage(at url: URL) throws -> (image: CGImage, properties: [CFString: Any], type: UTType?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageProcessingError.unreadable(url.lastPathComponent)
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageProcessingError.unreadable(url.lastPathComponent)
        }
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        return (image, properties, type)
    }

    public static func properties(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    /// Converts `source` with `options` and writes the result to `destination`.
    public static func process(source: URL, destination: URL, options: ImageEditOptions) throws {
        let loaded = try loadImage(at: source)
        let format = resolvedFormat(options.format, sourceType: loaded.type)
        let rendered = try render(loaded.image, options: options, opaque: !format.supportsAlpha)
        let metadata = filteredMetadata(loaded.properties, mode: options.metadata)
        try write(rendered, to: destination, format: format, quality: options.quality, metadata: metadata)
    }

    /// Converts into the dated output folder and returns the new file's URL.
    public static func process(
        source: URL, options: ImageEditOptions, output: OutputDirectory, tool: ToolID
    ) throws -> URL {
        let type = UTType(filenameExtension: source.pathExtension)
        let format = resolvedFormat(options.format, sourceType: type)
        let destination = try output.outputURL(forSource: source, tool: tool, newExtension: format.fileExtension)
        try process(source: source, destination: destination, options: options)
        return destination
    }

    static func resolvedFormat(_ requested: ImageFormat?, sourceType: UTType?) -> ImageFormat {
        let writable = ImageFormat.writable
        if let requested, writable.contains(requested) { return requested }
        if let sourceType, let format = ImageFormat(utType: sourceType), writable.contains(format) { return format }
        return .png
    }

    /// Output pixel size before rotation.
    public static func targetSize(width: Int, height: Int, resize: ImageEditOptions.Resize) -> (width: Int, height: Int) {
        let w = Double(width)
        let h = Double(height)
        let factor: Double
        switch resize {
        case .none: factor = 1
        case .scale(let scale): factor = max(scale, 0.0001)
        case .fit(let maxWidth, let maxHeight):
            factor = min(1, Double(max(maxWidth, 1)) / w, Double(max(maxHeight, 1)) / h)
        case .longEdge(let edge):
            factor = min(1, Double(max(edge, 1)) / max(w, h))
        }
        return (max(1, Int((w * factor).rounded())), max(1, Int((h * factor).rounded())))
    }

    public static func render(_ image: CGImage, options: ImageEditOptions, opaque: Bool = false) throws -> CGImage {
        let size = targetSize(width: image.width, height: image.height, resize: options.resize)
        let quarterTurn = options.rotation == .clockwise90 || options.rotation == .counterclockwise90
        let canvasWidth = quarterTurn ? size.height : size.width
        let canvasHeight = quarterTurn ? size.width : size.height
        if size.width == image.width, size.height == image.height, options.rotation == .none, !options.flipHorizontal,
            !opaque || image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst
        {
            return image
        }

        let colorSpace: CGColorSpace =
            image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ImageProcessingError.renderFailed }
        context.interpolationQuality = .high
        if opaque {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        }

        // CoreGraphics' origin is bottom-left; rotate around the canvas center.
        context.translateBy(x: CGFloat(canvasWidth) / 2, y: CGFloat(canvasHeight) / 2)
        context.rotate(by: -CGFloat(options.rotation.rawValue) * .pi / 180)
        if options.flipHorizontal { context.scaleBy(x: -1, y: 1) }
        let rect = CGRect(
            x: -CGFloat(size.width) / 2, y: -CGFloat(size.height) / 2, width: CGFloat(size.width),
            height: CGFloat(size.height))
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ImageProcessingError.renderFailed }
        return result
    }

    /// Metadata to carry over. Orientation is always reset because pixels are already upright.
    static func filteredMetadata(_ properties: [CFString: Any], mode: ImageEditOptions.Metadata) -> [CFString: Any] {
        guard mode != .removeAll else { return [:] }
        var result: [CFString: Any] = [:]
        let carried: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary,
        ]
        for key in carried {
            if let value = properties[key] { result[key] = value }
        }
        if mode == .removeLocation { result[kCGImagePropertyGPSDictionary] = nil }
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        result[kCGImagePropertyOrientation] = 1
        return result
    }

    public static func write(
        _ image: CGImage, to url: URL, format: ImageFormat, quality: Double = 0.85, metadata: [CFString: Any] = [:]
    ) throws {
        guard ImageFormat.writable.contains(format),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil)
        else { throw ImageProcessingError.cannotEncode(format.displayName) }
        var properties = metadata
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.cannotEncode(format.displayName) }
    }

    /// Encodes to in-memory data (for previews, PDF pages, and the clipboard).
    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.85) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, format.utType.identifier as CFString, 1, nil)
        else { throw ImageProcessingError.cannotEncode(format.displayName) }
        var properties: [CFString: Any] = [:]
        if format.supportsQuality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.cannotEncode(format.displayName) }
        return data as Data
    }

    /// Short human-readable metadata summary (camera, date, location present).
    public static func metadataSummary(_ properties: [CFString: Any]) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        {
            rows.append((coreLocalized("Dimensions"), "\(width) × \(height)"))
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let camera = [tiff?[kCGImagePropertyTIFFMake] as? String, tiff?[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0 }.joined(separator: " ")
        if !camera.isEmpty { rows.append((coreLocalized("Camera"), camera)) }
        if let date = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            rows.append((coreLocalized("Taken"), date))
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            rows.append((coreLocalized("Location"), coreLocalized("Embedded GPS coordinates")))
        }
        return rows
    }
}
