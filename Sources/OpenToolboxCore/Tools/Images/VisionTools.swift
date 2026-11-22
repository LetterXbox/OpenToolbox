import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

public enum VisionToolError: Error, Equatable, LocalizedError {
    case noSubject
    case noCodeFound
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .noSubject: coreLocalized("No foreground subject was found in this image.")
        case .noCodeFound: coreLocalized("No QR code was found in this image.")
        case .renderFailed: coreLocalized("The image could not be rendered.")
        }
    }
}

/// On-device text recognition with Vision.
public enum TextRecognizer {
    public struct Line: Equatable, Sendable {
        public var text: String
        public var confidence: Float
        /// Normalized bounding box (origin bottom-left).
        public var boundingBox: CGRect
    }

    /// Recognizes text, returning lines in reading order (top to bottom, then left to right).
    public static func recognize(in image: CGImage, accurate: Bool = true, languages: [String] = []) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, confidence: candidate.confidence, boundingBox: observation.boundingBox)
        }
        return lines.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > min(a.boundingBox.height, b.boundingBox.height) / 2 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
    }

    public static func supportedLanguages() -> [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }
}

/// Face detection and anonymization.
public enum FaceBlur {
    public enum Style: String, CaseIterable, Sendable, Identifiable {
        case blur, pixelate, solid
        public var id: String { rawValue }
    }

    /// Face rectangles in pixel coordinates (origin bottom-left, like Core Image).
    public static func detectFaces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map {
            VNImageRectForNormalizedRect($0.boundingBox, image.width, image.height)
        }
    }

    /// Obscures each rectangle (expanded by `padding` of its size) and returns a new image.
    public static func anonymize(
        _ image: CGImage, regions: [CGRect], style: Style, strength: Double = 0.5, padding: Double = 0.15
    ) throws -> CGImage {
        let source = CIImage(cgImage: image)
        let extent = source.extent
        let longEdge = max(extent.width, extent.height)
        let amount = max(0.05, min(strength, 1))
        let obscured: CIImage
        switch style {
        case .blur:
            obscured = source.clampedToExtent().applyingGaussianBlur(sigma: Double(longEdge) * 0.03 * amount)
                .cropped(to: extent)
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = source.clampedToExtent()
            filter.scale = Float(longEdge * 0.04 * amount)
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            obscured = (filter.outputImage ?? source).cropped(to: extent)
        case .solid:
            obscured = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }
        var result = source
        for region in regions {
            let expanded = region.insetBy(dx: -region.width * padding, dy: -region.height * padding)
                .intersection(extent)
            guard !expanded.isNull, !expanded.isEmpty else { continue }
            result = obscured.cropped(to: expanded).composited(over: result)
        }
        let context = CIContext()
        guard let output = context.createCGImage(result, from: extent) else { throw VisionToolError.renderFailed }
        return output
    }
}

/// Lifts the foreground subject(s) from a photo (Vision, macOS 14+).
public enum BackgroundRemover {
    public static func removeBackground(from image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw VisionToolError.noSubject
        }
        let buffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let output = context.createCGImage(masked, from: masked.extent) else { throw VisionToolError.renderFailed }
        return output
    }
}

/// QR code generation (Core Image) and reading (Vision).
public enum QRCode {
    public enum Correction: String, CaseIterable, Sendable, Identifiable {
        /// ~7% damage tolerance
        case low = "L"
        /// ~15%
        case medium = "M"
        /// ~25%
        case quartile = "Q"
        /// ~30%
        case high = "H"
        public var id: String { rawValue }
    }

    /// Renders `text` as a crisp QR code; `moduleSize` is the pixel size of one module.
    public static func generate(_ text: String, correction: Correction = .medium, moduleSize: Int = 12) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction.rawValue
        guard let output = filter.outputImage else { throw VisionToolError.renderFailed }
        let scale = CGFloat(max(1, moduleSize))
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Add the 4-module quiet zone scanners expect.
        let canvas = scaled.extent.insetBy(dx: -4 * scale, dy: -4 * scale)
        let composed = scaled.composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas))
        let context = CIContext()
        guard let image = context.createCGImage(composed, from: canvas) else { throw VisionToolError.renderFailed }
        return image
    }

    /// Payload strings of every QR code found in `image`.
    public static func read(from image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
