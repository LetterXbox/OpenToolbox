import CoreGraphics
import Foundation
import PDFKit

public enum PDFCropError: Error, Equatable, LocalizedError {
    case marginsTooLarge(page: Int)

    public var errorDescription: String? {
        switch self {
        case .marginsTooLarge(let page): coreLocalized("The margins leave nothing of page \(page).")
        }
    }
}

/// Margins in PDF points, as the page appears on screen.
public struct PDFMargins: Equatable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static func millimeters(top: Double, left: Double, bottom: Double, right: Double) -> PDFMargins {
        let points = 72 / 25.4
        return PDFMargins(top: top * points, left: left * points, bottom: bottom * points, right: right * points)
    }

    public var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
}

public enum PDFCrop {
    static let minimumSide: CGFloat = 1

    static func cropRect(_ box: CGRect, margins: PDFMargins, rotation: Int) -> CGRect? {
        let (top, left, bottom, right): (Double, Double, Double, Double) =
            switch ((rotation % 360) + 360) % 360 {
            case 90: (margins.right, margins.top, margins.left, margins.bottom)
            case 180: (margins.bottom, margins.right, margins.top, margins.left)
            case 270: (margins.left, margins.bottom, margins.right, margins.top)
            default: (margins.top, margins.left, margins.bottom, margins.right)
            }
        let width = box.width - left - right
        let height = box.height - top - bottom
        guard [top, left, bottom, right].allSatisfy({ $0 >= 0 && $0.isFinite }),
            width >= minimumSide, height >= minimumSide
        else { return nil }
        return CGRect(x: box.minX + left, y: box.minY + bottom, width: width, height: height)
    }

    /// A copy with the given 0-based pages (all when `nil`) cropped by `margins`.
    public static func crop(_ document: PDFDocument, pages: Set<Int>? = nil, margins: PDFMargins) throws -> PDFDocument {
        let result = PDFTools.extract(Array(0..<document.pageCount), from: document)
        for index in 0..<result.pageCount where pages?.contains(index) ?? true {
            guard let page = result.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            guard let rect = cropRect(box, margins: margins, rotation: page.rotation) else {
                throw PDFCropError.marginsTooLarge(page: index + 1)
            }
            page.setBounds(rect, for: .cropBox)
        }
        return result
    }
}
