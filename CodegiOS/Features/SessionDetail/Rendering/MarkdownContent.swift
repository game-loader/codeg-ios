import SwiftUI
import UIKit

/// Block-level Markdown for assistant replies and user turns. `MarkdownParser`
/// splits the source into paragraphs, headings, nested lists, quotes, fenced
/// code, rules and GFM tables, so a coding agent's reply renders like a chat
/// client instead of a wall of text; each block's inline content (code pills,
/// file tokens, links) is drawn by `InlineMarkdown`.
///
/// Streaming text uses this too, via `LiveTextNode` with `streaming: true`, which
/// parses directly and bypasses the block cache (the partial strings would only
/// churn it); the finalized turn re-renders once through the cached path.
struct MarkdownContent: View {
    let raw: String
    /// While a reply is streaming, parse directly (skip the block LRU): the text
    /// changes ~20×/sec, so caching every partial string would only churn (and
    /// evict useful finalized entries). The finalized turn re-renders once through
    /// the cached path.
    var streaming: Bool = false
    /// Keep paragraph lines' indentation — for what a person typed.
    var keepsIndentation: Bool = false

    var body: some View {
        MarkdownBlocks(
            nodes: streaming
                ? Self.parse(raw, keepsIndentation: keepsIndentation)
                : Self.nodes(for: raw, keepsIndentation: keepsIndentation),
            caret: streaming
        )
    }
}

/// A run of blocks. The streaming caret rides the last block only when it is a
/// paragraph — a code/list/table tail is self-evidently in progress already.
private struct MarkdownBlocks: View {
    let nodes: [MarkdownNode<String>]
    var secondary = false
    var caret = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Typography.blockSpacing) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                MarkdownBlockView(
                    node: node,
                    isFirst: index == 0,
                    secondary: secondary,
                    caret: caret && index == nodes.count - 1
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let node: MarkdownNode<String>
    let isFirst: Bool
    /// Quoted content reads a step quieter than the reply around it.
    let secondary: Bool
    let caret: Bool

    private var color: Color { secondary ? Theme.textSecondary : Theme.textPrimary }

    var body: some View {
        switch node {
        case .paragraph(let text):
            if caret {
                CaretParagraph(raw: text, color: color)
            } else {
                InlineMarkdownText(raw: text, color: color)
            }

        case .heading(let level, let text):
            InlineMarkdownText(
                raw: text,
                style: .heading,
                font: Theme.Typography.heading(level).weight(Theme.Typography.headingWeight(level)),
                color: color,
                lineSpacing: Theme.Typography.headingLineSpacing,
                uiTextStyle: level == 1 ? .title2 : (level == 2 ? .title3 : (level == 3 ? .headline : .subheadline)),
                uiWeight: level <= 2 ? .bold : .semibold
            )
            // A heading opens a section: more air above than between paragraphs.
            .padding(.top, isFirst ? 0 : Theme.Typography.headingTopSpacing(level))

        case .list(let items):
            MarkdownList(items: items, color: color)

        case .quote(let children):
            // Type-erased: a quote holds blocks, which may hold quotes.
            AnyView(MarkdownBlocks(nodes: children, secondary: true))
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.quoteBar).frame(width: 3)
                }

        case .code(let language, let code):
            CodeBlockView(code: code, language: language)

        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.vertical, 4)

        case .table(let table):
            MarkdownTableView(table: table)

        case .math(let latex, let source):
            MathFormulaView(latex: latex, source: source, color: color)
        }
    }
}

// MARK: - Lists

/// A list with its nesting flattened into levels: each row indents to where its
/// parent's text starts, and markers sit in a column of one width per level so
/// the item text lines up.
private struct MarkdownList: View {
    let items: [MarkdownListItem<String>]
    let color: Color

    private static let markerSpacing: CGFloat = 7

    var body: some View {
        let widths = markerWidths
        VStack(alignment: .leading, spacing: Theme.Typography.listItemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Self.markerSpacing) {
                    marker(item)
                        .fixedSize()
                        .frame(minWidth: widths[item.level] ?? 14, alignment: .trailing)
                    InlineMarkdownText(raw: item.content, color: color)
                }
                .padding(.leading, indent(item.level, widths: widths))
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownListItem<String>) -> some View {
        switch item.marker {
        case .bullet:
            Text(verbatim: Self.bullets[min(item.level, Self.bullets.count - 1)])
                .font(Theme.Typography.messageBody)
                .foregroundStyle(Theme.textTertiary)
        case .ordered(let number):
            Text(verbatim: "\(number).")
                .font(Theme.Typography.messageBody.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        case .task(let checked):
            Text(Image(systemName: checked ? "checkmark.square.fill" : "square"))
                .font(Theme.Typography.messageBody)
                .foregroundStyle(checked ? Theme.accent : Theme.textTertiary)
        }
    }

    private static let bullets = ["•", "◦", "▪\u{FE0E}"]

    /// Per level, room for the widest marker: numbers need a digit's width each
    /// plus the period; bullets and checkboxes one glyph.
    private var markerWidths: [Int: CGFloat] {
        var widths: [Int: CGFloat] = [:]
        for item in items {
            let width: CGFloat
            if case .ordered(let number) = item.marker {
                width = CGFloat(String(number).count) * 10.5 + 6
            } else {
                width = 16
            }
            widths[item.level] = max(widths[item.level] ?? 0, width)
        }
        return widths
    }

    private func indent(_ level: Int, widths: [Int: CGFloat]) -> CGFloat {
        (0..<level).reduce(0) { $0 + (widths[$1] ?? 16) + Self.markerSpacing }
    }
}

// MARK: - Streaming caret

/// The trailing paragraph of a still-streaming reply, with a blinking "typing"
/// caret glued to the end of the text (so it wraps with the last word, like
/// ChatGPT). The caret glyph is *always* in the layout (constant width — only
/// its color alpha toggles), so the blink never re-measures the line box.
///
/// The blink is a discrete timer toggle with NO animation — deliberately. An
/// *ambient* `withAnimation(.repeatForever)` would make every concurrent layout
/// change animate too, so each streamed token would interpolate the caret's
/// x-position across the line (it visibly flew right). A hard terminal-style
/// blink keeps the caret pinned to the text end at every frame. Selection is
/// off: streaming text isn't selected mid-flight.
private struct CaretParagraph: View {
    let raw: String
    let color: Color
    @State private var visible = true

    var body: some View {
        InlineMarkdownText(
            raw: raw,
            color: color,
            caret: Text(verbatim: " ▌").foregroundStyle(visible ? Theme.accent : Theme.accent.opacity(0)),
            caretVisible: visible
        )
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(530))
                visible.toggle()
            }
        }
    }
}

// MARK: - Tables

/// A GFM table: each column as wide as its widest cell (up to a cap, past which
/// cells wrap), in a horizontally scrollable card when it outgrows the screen.
private struct MarkdownTableView: View {
    let table: MarkdownTable<String>

    var body: some View {
        let columns = table.header.count
        ScrollView(.horizontal, showsIndicators: false) {
            TableLayout(columns: columns) {
                ForEach(0..<columns, id: \.self) { column in
                    cell(table.header[column], column: column, isHeader: true, isLastRow: table.rows.isEmpty)
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    ForEach(0..<columns, id: \.self) { column in
                        cell(row[column], column: column, isHeader: false, isLastRow: index == table.rows.count - 1)
                    }
                }
            }
            .background(Theme.surfaceNested)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func cell(_ raw: String, column: Int, isHeader: Bool, isLastRow: Bool) -> some View {
        let alignment: TextAlignment = switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return InlineMarkdownText(
            raw: raw,
            style: .compact,
            font: isHeader ? .subheadline.weight(.semibold) : .subheadline,
            color: isHeader ? Theme.textPrimary : Theme.textSecondary,
            lineSpacing: 2,
            alignment: alignment,
            uiTextStyle: .subheadline,
            uiWeight: isHeader ? .semibold : nil
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Fill the row's height, so the separator and header fill line up
        // across cells of different heights.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isHeader ? Theme.surface : Color.clear)
        .overlay(alignment: .bottom) {
            if !isLastRow {
                Rectangle().fill(isHeader ? Theme.surfaceStroke : Theme.hairline).frame(height: 0.5)
            }
        }
    }
}

/// Lays cells out row-major in `columns` columns: a column takes its widest
/// cell's natural width (capped at `maxColumnWidth`, beyond which cells wrap),
/// a row its tallest cell's height at those widths.
private struct TableLayout: Layout {
    let columns: Int
    var minColumnWidth: CGFloat = 44
    var maxColumnWidth: CGFloat = 240

    struct Metrics {
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Metrics { Metrics() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics) -> CGSize {
        cache = measure(subviews)
        return CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics) {
        if cache.widths.count != columns { cache = measure(subviews) }
        var y = bounds.minY
        for (row, height) in cache.heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cache.widths[column], height: height)
                )
                x += cache.widths[column]
            }
            y += height
        }
    }

    private func measure(_ subviews: Subviews) -> Metrics {
        guard columns > 0 else { return Metrics() }
        var widths = Array(repeating: minColumnWidth, count: columns)
        for (index, subview) in subviews.enumerated() {
            let natural = subview.sizeThatFits(.unspecified).width
            widths[index % columns] = max(widths[index % columns], min(natural.rounded(.up), maxColumnWidth))
        }
        var heights = Array(repeating: CGFloat(0), count: (subviews.count + columns - 1) / columns)
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            heights[index / columns] = max(heights[index / columns], height)
        }
        return Metrics(widths: widths, heights: heights)
    }
}

// MARK: - Parsing + cache

extension MarkdownContent {
    /// Parse into blocks, memoized per source string (block parsing is heavier
    /// than inline; the cache keeps recycled `List` rows free). Main-thread-only,
    /// like `InlineMarkdown`'s cache.
    static func nodes(for raw: String, keepsIndentation: Bool = false) -> [MarkdownNode<String>] {
        let key = CacheKey(raw: raw, keepsIndentation: keepsIndentation)
        if let hit = cache[key] { return hit }
        let parsed = parse(raw, keepsIndentation: keepsIndentation)
        cache[key] = parsed
        order.append(key)
        if order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }

    /// Inline content stays raw here: it is rendered (and cached) per context
    /// by `InlineMarkdown`, since a heading's code span takes the heading's size.
    static func parse(_ raw: String, keepsIndentation: Bool = false) -> [MarkdownNode<String>] {
        MarkdownParser.parse(raw, keepsIndentation: keepsIndentation, inline: { $0 })
    }

    private struct CacheKey: Hashable {
        let raw: String
        let keepsIndentation: Bool
    }

    private static var cache: [CacheKey: [MarkdownNode<String>]] = [:]
    private static var order: [CacheKey] = []
    private static let limit = 300
}
