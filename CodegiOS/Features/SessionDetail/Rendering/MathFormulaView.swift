import SwiftUI
import UIKit

/// A display equation with a native image path and a selectable raw-source
/// fallback when SwiftMath cannot parse or rasterize the expression.
public struct MathFormulaView: View {
    public let latex: String
    public let source: String
    public let color: Color
    public let display: Bool
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.colorScheme) private var colorScheme

    public init(latex: String, source: String, color: Color, display: Bool = true) {
        self.latex = latex
        self.source = source
        self.color = color
        self.display = display
    }

    public var body: some View {
        let font = NativeMarkdownText.font(style: .body, category: sizeCategory)
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        if let image = MathFormulaRenderer.image(
            latex: latex,
            fontSize: font.pointSize,
            color: UIColor(color).resolvedColor(with: traits),
            display: display
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableMessageText(content: attributed(image: image, font: font))
                    .frame(width: ceil(image.size.width) + 1)
                    .accessibilityLabel(Text(verbatim: source.isEmpty ? latex : source))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SelectablePlainText(text: source.isEmpty ? latex : source, color: color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func attributed(image: UIImage, font: UIFont) -> NSAttributedString {
        let attachment = MessageSourceAttachment(image: image,
            bounds: MathFormulaRenderer.attachmentBounds(for: image, display: true),
            source: source.isEmpty ? latex : source)
        let content = NSMutableAttributedString(attachment: attachment)
        content.addAttribute(.font, value: font, range: NSRange(location: 0, length: content.length))
        return content
    }
}
