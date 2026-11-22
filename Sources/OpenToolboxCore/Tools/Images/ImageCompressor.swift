import CoreGraphics
import Foundation
import ImageIO

public struct ImageCompressionOptions: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// Keep JPEG and HEIC files in their format; re-encode anything else as `fallback`.
        case keepFormat(fallback: ImageFormat)
        case convert(ImageFormat)
    }

    public var target: Target
    /// Lossy quality 0...1.
    public var quality: Double
    /// Longest edge in pixels, or `nil` to keep the size.
    public var longEdge: Int?
    public var metadata: ImageEditOptions.Metadata

    public init(
        target: Target = .keepFormat(fallback: .heic), quality: Double = 0.7, longEdge: Int? = nil,
        metadata: ImageEditOptions.Metadata = .removeLocation
    ) {
        self.target = target
        self.quality = quality
        self.longEdge = longEdge
        self.metadata = metadata
    }
}

public struct ImageCompressionResult: Sendable {
    public let source: URL
    /// `nil` when the compressed copy was not smaller, so nothing was written.
    public let output: URL?
    public let originalBytes: Int64
    public let compressedBytes: Int64

    public var savedFraction: Double {
        originalBytes > 0 ? 1 - Double(compressedBytes) / Double(originalBytes) : 0
    }
}

/// Re-encodes images to make them smaller. A copy that would not be smaller is not written.
public enum ImageCompressor {
    static func format(for target: ImageCompressionOptions.Target, source: ImageFormat?) -> ImageFormat {
        switch target {
        case .keepFormat(let fallback):
            if let source, source.supportsQuality { return source }
            return fallback
        case .convert(let format):
            return format
        }
    }

    public static func compress(
        _ source: URL, options: ImageCompressionOptions, output: OutputDirectory, tool: ToolID
    ) throws -> ImageCompressionResult {
        let originalBytes = try fileSize(source)
        let loaded = try ImageProcessor.loadImage(at: source)
        let format = ImageProcessor.resolvedFormat(
            format(for: options.target, source: loaded.type.flatMap(ImageFormat.init(utType:))), sourceType: loaded.type)
        let edit = ImageEditOptions(
            format: format, quality: options.quality, resize: options.longEdge.map { .longEdge($0) } ?? .none,
            metadata: options.metadata)
        let rendered = try ImageProcessor.render(loaded.image, options: edit, opaque: !format.supportsAlpha)
        let metadata = ImageProcessor.filteredMetadata(loaded.properties, mode: options.metadata)

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, format.utType.identifier as CFString, 1, nil)
        else { throw ImageProcessingError.cannotEncode(format.displayName) }
        var properties = metadata
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(options.quality, 0), 1)
        }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.cannotEncode(format.displayName) }

        let compressedBytes = Int64(data.length)
        guard compressedBytes < originalBytes else {
            return ImageCompressionResult(
                source: source, output: nil, originalBytes: originalBytes, compressedBytes: compressedBytes)
        }
        let url = try output.writeOutput(forSource: source, tool: tool, newExtension: format.fileExtension) {
            try (data as Data).write(to: $0, options: .withoutOverwriting)
        }
        return ImageCompressionResult(
            source: source, output: url, originalBytes: originalBytes, compressedBytes: compressedBytes)
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}
