import SwiftUI
import UIKit

/// A single text view for selections spanning multiple Markdown blocks. The
/// transcript's individual paragraphs also support selection directly.
struct SelectMessageTextButton: View {
    let raw: String
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "text.cursor")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select text")
        .sheet(isPresented: $presented) { MessageSelectionSheet(raw: raw) }
    }
}

private struct MessageSelectionSheet: View {
    let raw: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            SelectableMessageText(content: MessageSelectionDocument.attributed(raw,
                font: NativeMarkdownText.font(style: .body, category: sizeCategory),
                color: UIColor(Theme.textPrimary),
                traits: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)),
                scrolls: true)
                .padding(16)
                .background(Theme.bg)
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

@MainActor
enum MessageSelectionDocument {
    static func attributed(_ raw: String, font: UIFont, color: UIColor,
                           traits: UITraitCollection) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color.resolvedColor(with: traits)
        ]
        func inline(_ text: String) -> NSAttributedString {
            NativeMarkdownText.attributed(text, font: font, color: color, traits: traits)
        }
        func append(_ nodes: [MarkdownNode<String>]) {
            for node in nodes {
                if case .quote(let children) = node {
                    append(children)
                    continue
                }
                if result.length > 0 { result.append(NSAttributedString(string: "\n\n", attributes: base)) }
                switch node {
                case .paragraph(let text), .heading(_, let text): result.append(inline(text))
                case .quote: break // Handled recursively above.
                case .list(let items):
                    for (index, item) in items.enumerated() {
                        if index > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }
                        let marker: String
                        switch item.marker {
                        case .bullet: marker = "• "
                        case .ordered(let number): marker = "\(number). "
                        case .task(let checked): marker = checked ? "☑ " : "☐ "
                        }
                        result.append(NSAttributedString(string: String(repeating: "  ", count: item.level) + marker,
                                                         attributes: base))
                        result.append(inline(item.content))
                    }
                case .code(_, let source):
                    result.append(NSAttributedString(string: source, attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular),
                        .foregroundColor: color.resolvedColor(with: traits)
                    ]))
                case .math(let latex, let source):
                    if let image = MathFormulaRenderer.image(latex: latex, fontSize: font.pointSize,
                        color: color.resolvedColor(with: traits), display: true) {
                        let attachment = MessageSourceAttachment(image: image,
                            bounds: MathFormulaRenderer.attachmentBounds(for: image, display: true), source: source)
                        result.append(NSAttributedString(attachment: attachment))
                    } else {
                        result.append(NSAttributedString(string: source, attributes: base))
                    }
                case .table(let table):
                    for (index, row) in ([table.header] + table.rows).enumerated() {
                        if index > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }
                        for (column, cell) in row.enumerated() {
                            if column > 0 { result.append(NSAttributedString(string: "\t", attributes: base)) }
                            result.append(inline(cell))
                        }
                    }
                case .rule: result.append(NSAttributedString(string: "—", attributes: base))
                }
            }
        }
        append(MarkdownContent.parse(raw))
        return result
    }
}
