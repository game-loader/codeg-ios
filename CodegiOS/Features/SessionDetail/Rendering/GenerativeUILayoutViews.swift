import SwiftUI

struct GenerativeUICardView: View {
    let element: GenerativeUISpec.Element
    let spec: GenerativeUISpec

    private var width: CGFloat {
        switch element.text("maxWidth") {
        case "sm": 320
        case "md": 384
        case "lg": 448
        default: .infinity
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !element.text("title").isEmpty {
                Text(verbatim: element.text("title")).font(.headline)
            }
            if !element.text("description").isEmpty {
                Text(verbatim: element.text("description"))
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            GenerativeUIChildren(element: element, spec: spec)
        }
        .padding(16)
        .frame(maxWidth: width, alignment: .leading)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .hairlineBorder(Theme.Radius.sm)
        .frame(maxWidth: .infinity, alignment: element.flag("centered") ? .center : .leading)
    }
}

struct GenerativeUIStackView: View {
    let element: GenerativeUISpec.Element
    let spec: GenerativeUISpec

    private var alignment: HorizontalAlignment {
        switch element.text("align") {
        case "center": .center
        case "end": .trailing
        default: .leading
        }
    }

    var body: some View {
        if element.text("direction") == "horizontal" {
            GenerativeUIFlowLayout(gap: GenerativeUISpacing.value(element.text("gap", default: "md")),
                                   alignment: element.text("align", default: "start")) {
                GenerativeUIChildren(element: element, spec: spec)
            }
        } else {
            VStack(alignment: alignment, spacing: GenerativeUISpacing.value(element.text("gap", default: "md"))) {
                GenerativeUIChildren(element: element, spec: spec)
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
        }
    }
}

struct GenerativeUIGridView: View {
    let element: GenerativeUISpec.Element
    let spec: GenerativeUISpec

    var body: some View {
        let gap = GenerativeUISpacing.value(element.text("gap", default: "md"))
        let count = Int(element.props["columns"]?.number ?? 1)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .topLeading), count: count),
                  alignment: .leading, spacing: gap) {
            GenerativeUIChildren(element: element, spec: spec)
        }
    }
}

enum GenerativeUISpacing {
    static func value(_ gap: String) -> CGFloat {
        switch gap {
        case "none": 0
        case "sm": 8
        case "lg": 16
        case "xl": 24
        default: 12
        }
    }
}

/// Upstream horizontal Stack wraps. A plain HStack would clip wide content.
private struct GenerativeUIFlowLayout: Layout {
    let gap: CGFloat
    let alignment: String

    struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var result: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let addition = (row.indices.isEmpty ? 0 : gap) + min(size.width, width)
            if !row.indices.isEmpty, row.width + addition > width {
                result.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : gap) + min(size.width, width)
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 320)
        let rows = rows(subviews, width: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: max(1, bounds.width)) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                let width = min(size.width, bounds.width)
                let offset = alignment == "end" ? row.height - size.height : (alignment == "center" ? (row.height - size.height) / 2 : 0)
                subviews[index].place(at: CGPoint(x: x, y: y + offset), anchor: .topLeading,
                                     proposal: ProposedViewSize(width: width, height: size.height))
                x += width + gap
            }
            y += row.height + gap
        }
    }
}
