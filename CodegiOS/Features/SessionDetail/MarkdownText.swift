import SwiftUI

/// Renders a string as inline Markdown (code spans as pills, file and `codeg://`
/// references as colored tokens — see `InlineMarkdown`), degrading to plain text
/// when the string is not valid Markdown. Whitespace is preserved between
/// paragraphs (`.inlineOnlyPreservingWhitespace` keeps newlines that the default
/// parser would otherwise collapse).
struct MarkdownText: View {
    let raw: String
    var color: Color = Theme.textPrimary
    var font: Font = Theme.Typography.messageBody
    /// When true, render the raw string verbatim and skip Markdown parsing. Used
    /// for live-streaming text so each token delta doesn't re-parse the entire
    /// accumulated reply (O(n²) main-actor work on long replies); the turn
    /// re-renders once with full Markdown when it finalizes.
    var plain: Bool = false

    var body: some View {
        // Live-streaming text (`plain`) renders verbatim and skips the cache —
        // each token delta is a distinct string, so caching would only churn.
        if plain {
            Text(verbatim: raw)
                .font(font)
                .lineSpacing(Theme.Typography.messageLineSpacing)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            InlineMarkdownText(raw: raw, font: font, color: color)
        }
    }

    /// Parse Markdown into an `AttributedString`, falling back to a verbatim
    /// string when parsing fails. Newlines are preserved so streamed multi-line
    /// replies keep their shape.
    static func attributed(from raw: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }
}
