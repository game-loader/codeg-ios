import SwiftUI
import UIKit

/// A display equation with a native image path and a selectable raw-source
/// fallback when SwiftMath cannot parse or rasterize the expression.
public struct MathFormulaView: View {
    public let latex: String
    public let source: String
    public let color: Color
    public let display: Bool

    public init(latex: String, source: String, color: Color, display: Bool = true) {
        self.latex = latex
        self.source = source
        self.color = color
        self.display = display
    }

    public var body: some View {
        let fontSize = max(17, UIFont.preferredFont(forTextStyle: .body).pointSize)
        if let image = MathFormulaRenderer.image(
            latex: latex,
            fontSize: fontSize,
            color: UIColor(color),
            display: display
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: image.size.width, height: image.size.height, alignment: .leading)
                    .accessibilityLabel(Text(verbatim: source.isEmpty ? latex : source))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(verbatim: source.isEmpty ? latex : source)
                .font(.body.monospaced())
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
