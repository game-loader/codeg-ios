import Foundation
import UIKit
import SwiftMath

/// The single native rasterization boundary for Markdown math.
@MainActor
public enum MathFormulaRenderer {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
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

        let normalized = normalizedLatex(for: latex)
        let key = "\(display ? "display" : "text")|\(fontSize)|\(colorKey(color))|\(normalized.boxed)|\(normalized.latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let formatter = MTMathImage(
            latex: normalized.latex,
            fontSize: fontSize,
            textColor: color,
            labelMode: display ? .display : .text,
            textAlignment: .left
        )
        // Measure native layout before allocating a bitmap. TeX command length
        // is not its visual width: even a long matrix can fit a small image.
        let measure = MTMathUILabel()
        measure.font = formatter.font
        measure.labelMode = display ? .display : .text
        measure.latex = normalized.latex
        guard measure.error == nil else { return nil }
        // SwiftMath 1.7.3 implements intrinsicContentSize; sizeThatFits is the
        // UIView default and just returns the label's initial zero-sized frame.
        let size = measure.intrinsicContentSize
        let scale = UIGraphicsImageRendererFormat.default().scale
        guard measure.error == nil, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= maxRasterWidth, size.height <= maxRasterHeight,
              size.width * size.height * scale * scale <= maxRasterPixels else { return nil }
        let (error, image) = formatter.asImage()
        guard error == nil, let image,
              image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0,
              image.size.width <= maxRasterWidth,
              image.size.height <= maxRasterHeight,
              image.size.width * image.size.height <= maxRasterPixels else { return nil }

        let renderedImage = normalized.boxed ? boxedImage(image, color: color, fontSize: fontSize) : image
        guard let renderedImage,
              renderedImage.size.width.isFinite,
              renderedImage.size.height.isFinite,
              renderedImage.size.width > 0,
              renderedImage.size.height > 0,
              renderedImage.size.width <= maxRasterWidth,
              renderedImage.size.height <= maxRasterHeight,
              renderedImage.size.width * renderedImage.size.height <= maxRasterPixels else { return nil }

        let cost = renderedImage.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(renderedImage.size.width * renderedImage.size.height * 4)
        cache.setObject(renderedImage, forKey: key, cost: cost)
        return renderedImage
    }

    /// Returns the SwiftMath-compatible form while keeping the source string
    /// untouched in the Markdown and selection layers.
    internal static func normalizedLatex(for latex: String) -> (latex: String, boxed: Bool) {
        let normalized = normalize(latex)
        return (normalized.latex, normalized.boxed)
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

    private struct NormalizedLatex {
        let latex: String
        let boxed: Bool
    }

    private struct CommandArgument {
        let innerStart: Int
        let innerEnd: Int
        let end: Int
    }

    private static func normalize(_ latex: String) -> NormalizedLatex {
        let characters = Array(latex)
        var output = ""
        var boxed = false
        var index = 0

        while index < characters.count {
            guard characters[index] == "\\" else {
                output.append(characters[index])
                index += 1
                continue
            }

            if let argument = commandArgument(named: "boxed", at: index, in: characters)
                ?? commandArgument(named: "fbox", at: index, in: characters) {
                let inner = normalize(String(characters[argument.innerStart..<argument.innerEnd]))
                output.append(inner.latex)
                boxed = true
                index = argument.end
                continue
            }

            if let argument = commandArgument(named: "operatorname", at: index, in: characters) {
                let inner = normalize(String(characters[argument.innerStart..<argument.innerEnd]))
                output.append("\\mathrm{")
                output.append(inner.latex)
                output.append("}")
                boxed = boxed || inner.boxed
                index = argument.end
                continue
            }

            output.append(characters[index])
            index += 1
        }

        return NormalizedLatex(latex: output, boxed: boxed)
    }

    private static func commandArgument(
        named name: String,
        at index: Int,
        in characters: [Character]
    ) -> CommandArgument? {
        let command = Array(name)
        guard index + 1 + command.count <= characters.count,
              Array(characters[(index + 1)..<(index + 1 + command.count)]) == command else {
            return nil
        }

        var cursor = index + 1 + command.count
        if name == "operatorname", cursor < characters.count, characters[cursor] == "*" {
            cursor += 1
        }
        guard cursor == characters.count || !characters[cursor].isLetter else {
            return nil
        }

        while cursor < characters.count, isWhitespace(characters[cursor]) {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "{" else { return nil }
        return bracedArgument(at: cursor, in: characters)
    }

    private static func bracedArgument(at start: Int, in characters: [Character]) -> CommandArgument? {
        var depth = 0
        var index = start
        while index < characters.count {
            if characters[index] == "\\" {
                index += min(2, characters.count - index)
                continue
            }
            if characters[index] == "{" {
                depth += 1
            } else if characters[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return CommandArgument(innerStart: start + 1, innerEnd: index, end: index + 1)
                }
            }
            index += 1
        }
        return nil
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }

    private static func boxedImage(_ image: UIImage, color: UIColor, fontSize: CGFloat) -> UIImage? {
        let padding = max(2, ceil(fontSize * 0.14))
        let borderWidth = max(1, ceil(fontSize * 0.045))
        let size = CGSize(
            width: image.size.width + padding * 2,
            height: image.size.height + padding * 2
        )
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(at: CGPoint(x: padding, y: padding))
            color.setStroke()
            let rect = CGRect(
                x: borderWidth / 2,
                y: borderWidth / 2,
                width: size.width - borderWidth,
                height: size.height - borderWidth
            )
            let path = UIBezierPath(rect: rect)
            path.lineWidth = borderWidth
            path.stroke()
        }
    }
}
