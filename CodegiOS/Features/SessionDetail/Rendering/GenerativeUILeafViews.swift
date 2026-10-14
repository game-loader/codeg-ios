import SwiftUI

struct GenerativeUILeafView: View {
    let element: GenerativeUISpec.Element

    var body: some View {
        switch element.type {
        case "Heading":
            Text(verbatim: element.text("text"))
                .font(headingFont).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
        case "Text": GenerativeUITextView(element: element)
        case "Badge": GenerativeUIBadgeView(element: element)
        case "Separator":
            if element.text("orientation") == "vertical" {
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 24).accessibilityHidden(true)
            } else { Divider() }
        case "Link": GenerativeUILinkView(element: element)
        default: EmptyView() // Only parser-validated types reach this view.
        }
    }

    private var headingFont: Font {
        switch element.text("level", default: "h2") {
        case "h1": .title
        case "h2": .title2
        case "h3": .title3
        default: .headline
        }
    }
}

private struct GenerativeUITextView: View {
    let element: GenerativeUISpec.Element
    private var variant: String { element.text("variant", default: "body") }
    private var font: Font {
        switch variant {
        case "caption": .caption
        case "lead": .title3
        case "code": .body.monospaced()
        default: .body
        }
    }
    var body: some View {
        Text(verbatim: element.text("text"))
            .font(font)
            .foregroundStyle(variant == "muted" || variant == "caption" ? Theme.textSecondary : Theme.textPrimary)
            .textSelection(.enabled)
    }
}

private struct GenerativeUIBadgeView: View {
    let element: GenerativeUISpec.Element
    private var color: Color {
        switch element.text("variant") {
        case "destructive": .red
        case "secondary", "outline": Theme.textSecondary
        default: Theme.accent
        }
    }
    var body: some View {
        Text(verbatim: element.text("text"))
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(element.text("variant") == "outline" ? Color.clear : color.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }
}

private struct GenerativeUILinkView: View {
    let element: GenerativeUISpec.Element
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = GenerativeUISpec.linkURL(element.text("href")) {
            Button { openURL(url) } label: {
                Text(verbatim: element.text("label")).underline().foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isLink)
        }
    }
}

struct GenerativeUITableView: View {
    let element: GenerativeUISpec.Element
    private var columns: [String] { (element.props["columns"]?.array ?? []).compactMap(\.string) }
    private var rows: [[String]] { (element.props["rows"]?.array ?? []).map { ($0.array ?? []).compactMap(\.string) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            cell(column, header: true)
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                cell(value, header: false)
                            }
                        }
                    }
                }
                .background(Theme.surfaceNested)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .hairlineBorder(Theme.Radius.sm)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            if !element.text("caption").isEmpty {
                Text(verbatim: element.text("caption")).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func cell(_ text: String, header: Bool) -> some View {
        Text(verbatim: text)
            .font(header ? .subheadline.weight(.semibold) : .subheadline)
            .textSelection(.enabled)
            .frame(minWidth: 60, maxWidth: 240, alignment: .topLeading)
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(header ? Theme.surface : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}
