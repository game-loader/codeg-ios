import Foundation
import UIKit
import SwiftMath

/// The single native rasterization boundary for Markdown math.
public enum MathFormulaRenderer {
    private static let cache = NSCache<NSString, UIImage>()
    private static let maxLatexBytes = 16 * 1024
    private static let maxFontSize: CGFloat = 96
    private static let maxRasterWidth: CGFloat = 8_192
    private static let maxRasterHeight: CGFloat = 4_096
    private static let maxRasterPixels: CGFloat = 8_000_000

    public static func image(
        latex: String,
        fontSize: CGFloat,
        color: UIColor,
        display: Bool
    ) -> UIImage? {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              latex.utf8.count <= maxLatexBytes,
              fontSize.isFinite,
              fontSize >= 6,
              fontSize <= maxFontSize else { return nil }

        let lineCount = max(1, latex.split(separator: "\n", omittingEmptySubsequences: false).count)
        let estimatedWidth = CGFloat(max(1, latex.utf8.count)) * fontSize * 2.75 + 32
        let estimatedHeight = CGFloat(lineCount) * fontSize * 3.5 + 32
        guard estimatedWidth <= maxRasterWidth,
              estimatedHeight <= maxRasterHeight,
              estimatedWidth * estimatedHeight <= maxRasterPixels else { return nil }

        let key = "\(display ? "display" : "text")|\(fontSize)|\(colorKey(color))|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let formatter = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: color,
            labelMode: display ? .display : .text,
            textAlignment: .left
        )
        let (error, image) = formatter.asImage()
        guard error == nil, let image,
              image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0,
              image.size.width <= maxRasterWidth,
              image.size.height <= maxRasterHeight,
              image.size.width * image.size.height <= maxRasterPixels else { return nil }

        cache.setObject(image, forKey: key)
        return image
    }

    /// Bounds suitable for assigning to an `NSTextAttachment`. Text-style math
    /// sits slightly below the surrounding baseline; display math stays on its
    /// own line and therefore uses the image origin directly.
    public static func attachmentBounds(for image: UIImage, display: Bool = false) -> CGRect {
        let baselineOffset = display ? 0 : -max(1, image.size.height * 0.18)
        return CGRect(origin: CGPoint(x: 0, y: baselineOffset), size: image.size)
    }

    public static func clearCache() {
        cache.removeAllObjects()
    }

    private static func colorKey(_ color: UIColor) -> String {
        let resolved = color.resolvedColor(with: .current)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return "\(red),\(green),\(blue),\(alpha)"
        }
        return resolved.description
    }
}
