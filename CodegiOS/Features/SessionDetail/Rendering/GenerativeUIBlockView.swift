import SwiftUI

/// Only called for a `spec` fence. A failed validation preserves the entire
/// fence, including unsupported elements and incomplete/malformed patches.
struct GenerativeUIBlockView: View {
    let source: String
    var streaming = false

    var body: some View {
        if let spec = GenerativeUISpec.parse(source, streaming: streaming) {
            VStack(alignment: .leading, spacing: 12) {
                GenerativeUINodeView(id: spec.root, spec: spec)
                HStack(alignment: .top, spacing: 8) {
                    DisclosureGroup("UI source") {
                        CodeBlockView(code: source, language: "spec")
                    }
                    CopyButton(text: source, label: "Copy")
                }
                .font(.caption)
                .tint(Theme.textSecondary)
            }
        } else {
            CodeBlockView(code: source, language: "spec")
        }
    }
}

/// Recursive calls are erased at this boundary; individual leaves and layouts
/// have small, independent SwiftUI bodies. The parser bounds expanded instances.
struct GenerativeUINodeView: View {
    let id: String
    let spec: GenerativeUISpec

    var body: some View {
        if let element = spec.elements[id] {
            content(element)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    @ViewBuilder
    private func content(_ element: GenerativeUISpec.Element) -> some View {
        switch element.type {
        case "Card": GenerativeUICardView(element: element, spec: spec)
        case "Stack": GenerativeUIStackView(element: element, spec: spec)
        case "Grid": GenerativeUIGridView(element: element, spec: spec)
        case "Table": GenerativeUITableView(element: element)
        default:
            if let chart = element.chart {
                GenerativeUIChartView(chart: chart)
            } else {
                GenerativeUILeafView(element: element)
            }
        }
    }
}

struct GenerativeUIChildren: View {
    let element: GenerativeUISpec.Element
    let spec: GenerativeUISpec

    var body: some View {
        ForEach(Array(element.children.enumerated()), id: \.offset) { _, child in
            AnyView(GenerativeUINodeView(id: child, spec: spec))
        }
    }
}
