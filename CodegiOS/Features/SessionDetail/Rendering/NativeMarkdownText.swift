import SwiftUI
import UIKit

/// Builds one attributed paragraph, so selection can span emphasis, links,
/// inline code and equations without breaking into separate selectable pieces.
@MainActor
enum NativeMarkdownText {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 300
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func attributed(_ raw: String, font: UIFont, color: UIColor,
                           lineSpacing: CGFloat = 5, alignment: NSTextAlignment = .left,
                           traits: UITraitCollection = .current, cached: Bool = true) -> NSAttributedString {
        let resolvedColor = color.resolvedColor(with: traits)
        let key = "\(raw)\u{001F}\(font.fontName)/\(font.pointSize)/\(resolvedColor)/\(lineSpacing)/\(alignment.rawValue)/\(traits.userInterfaceStyle.rawValue)" as NSString
        if cached, let hit = cache.object(forKey: key) { return hit }
        let masked = MarkdownMath.maskInline(raw)
        let parsed = MarkdownText.attributed(from: masked.text)
        let output = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: resolvedColor, .paragraphStyle: paragraph
            ]
            if intent.contains(.code) {
                runFont = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                attributes[.backgroundColor] = UIColor(InlineCodeRenderer.pillColor).resolvedColor(with: traits)
            } else {
                var symbolic = font.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { symbolic.insert(.traitBold) }
                if intent.contains(.emphasized) { symbolic.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
                    runFont = UIFont(descriptor: descriptor, size: font.pointSize)
                }
            }
            attributes[.font] = runFont
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link {
                attributes[.link] = url
                if let reference = Reference(url: url) {
                    let referenceColor = UIColor(reference.color).resolvedColor(with: traits)
                    attributes[.foregroundColor] = referenceColor
                    if let icon = UIImage(systemName: reference.symbol(label: text),
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.8)) {
                        let painted = icon.withTintColor(referenceColor, renderingMode: .alwaysOriginal)
                        let attachment = MessageSourceAttachment(image: painted,
                            bounds: CGRect(x: 0, y: font.descender, width: painted.size.width + 3, height: painted.size.height),
                            source: "")
                        let image = NSMutableAttributedString(attachment: attachment)
                        image.addAttributes(attributes, range: NSRange(location: 0, length: image.length))
                        output.append(image)
                        var separatorAttributes = attributes
                        separatorAttributes[.messageDecoration] = true
                        output.append(NSAttributedString(string: "\u{2060}", attributes: separatorAttributes))
                    }
                } else {
                    attributes[.foregroundColor] = UIColor(Theme.accent).resolvedColor(with: traits)
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }

        // Mask before Markdown, replace after it: TeX backslashes/underscores
        // never become Markdown escapes or emphasis, even inside bold prose.
        let original = output.string as NSString
        var replacements: [(NSRange, MarkdownMath.Formula)] = []
        for (marker, formula) in masked.formulas {
            let range = original.range(of: marker)
            if range.location != NSNotFound { replacements.append((range, formula)) }
        }
        for (range, formula) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            var attributes = output.attributes(at: range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            let formulaFont = (attributes[.font] as? UIFont) ?? font
            let formulaColor = (attributes[.foregroundColor] as? UIColor) ?? resolvedColor
            if let image = MathFormulaRenderer.image(latex: formula.latex, fontSize: formulaFont.pointSize,
                                                     color: formulaColor, display: formula.display) {
                let attachment = MessageSourceAttachment(image: image,
                    bounds: CGRect(x: 0, y: min(formulaFont.descender, (formulaFont.xHeight - image.size.height) / 2),
                                   width: image.size.width, height: image.size.height), source: formula.source)
                let rendered = NSMutableAttributedString(attachment: attachment)
                rendered.addAttributes(attributes, range: NSRange(location: 0, length: rendered.length))
                output.replaceCharacters(in: range, with: rendered)
            } else {
                output.replaceCharacters(in: range, with: NSAttributedString(string: formula.source, attributes: attributes))
            }
        }
        let result = NSAttributedString(attributedString: output)
        if cached, raw.utf16.count < 64 * 1024 {
            cache.setObject(result, forKey: key, cost: max(raw.utf16.count, result.length) * 8)
        }
        return result
    }

    static func font(style: UIFont.TextStyle, weight: UIFont.Weight? = nil,
                     category: ContentSizeCategory) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: category.uiKit)
        let preferred = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        guard let weight else { return preferred }
        return UIFont.systemFont(ofSize: preferred.pointSize, weight: weight)
    }
}

private extension ContentSizeCategory {
    var uiKit: UIContentSizeCategory {
        switch self {
        case .extraSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .extraLarge: return .extraLarge
        case .extraExtraLarge: return .extraExtraLarge
        case .extraExtraExtraLarge: return .extraExtraExtraLarge
        case .accessibilityMedium: return .accessibilityMedium
        case .accessibilityLarge: return .accessibilityLarge
        case .accessibilityExtraLarge: return .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: return .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
