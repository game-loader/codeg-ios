import SwiftUI

/// The resources a user turn carries (`UserResources`), as a wrapping row of
/// chips under the message — the way the composer showed them while the message
/// was written, instead of the raw page dump or context JSON the agent received.
/// A web chip opens its site; a machine or paper chip shows the context that was
/// sent.
struct UserResourceChips: View {
    let resources: [UserResource]

    @State private var shownDetail: UserResource?
    @Environment(\.openURL) private var openURL

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(resources) { resource in
                if let action = action(for: resource) {
                    Button(action: action) { ResourceChip(resource: resource, isInteractive: true) }
                        .buttonStyle(.plain)
                } else {
                    ResourceChip(resource: resource, isInteractive: false)
                }
            }
        }
        .sheet(item: $shownDetail) { resource in
            ResourceDetailSheet(resource: resource)
        }
    }

    private func action(for resource: UserResource) -> (() -> Void)? {
        if resource.detail != nil {
            return { shownDetail = resource }
        }
        if resource.kind == .web, let url = URL(string: resource.uri) {
            return { openURL(url) }
        }
        return nil
    }
}

private struct ResourceChip: View {
    let resource: UserResource
    let isInteractive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: resource.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(resource.tint)
            Text(verbatim: resource.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isInteractive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 0.75))
        .contentShape(Capsule())
    }
}

extension UserResource {
    var symbol: String {
        switch kind {
        case .web: "globe"
        case .mention: "at"
        case .attachment: FileIcon.symbol(for: name)
        case .machine: "server.rack"
        case .paper: "book.closed"
        }
    }

    var tint: Color {
        switch kind {
        case .web, .attachment: ReferencePalette.file
        case .mention: ReferencePalette.agent
        case .machine: ReferencePalette.session
        case .paper: ReferencePalette.commit
        }
    }
}

/// The context a machine or paper chip stands for, as it was sent.
private struct ResourceDetailSheet: View {
    let resource: UserResource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if resource.kind == .paper, let paper = PaperContext(json: resource.detail) {
                        paperSummary(paper)
                    }
                    CodeBlockView(code: prettyJSON, language: "json", collapsedLineLimit: 400)
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.vertical, 12)
            }
            .background(CodegBackground())
            .navigationTitle(Text(verbatim: resource.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func paperSummary(_ paper: PaperContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: paper.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if !paper.authors.isEmpty {
                Text(verbatim: paper.authors.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let abstract = paper.abstract {
                Text(verbatim: abstract)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prettyJSON: String {
        guard let detail = resource.detail,
              let object = try? JSONSerialization.jsonObject(with: Data(detail.utf8)),
              let data = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let pretty = String(data: data, encoding: .utf8)
        else { return resource.detail ?? "" }
        return pretty
    }
}

/// The fields of a paper context block worth reading at a glance.
private struct PaperContext {
    let title: String
    let authors: [String]
    let abstract: String?

    init?(json: String?) {
        guard let json,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let title = object["title"] as? String, !title.isEmpty else { return nil }
        self.title = title
        authors = object["authors"] as? [String] ?? []
        abstract = (object["abstract"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Flow layout

/// Lays subviews out left to right, wrapping to a new line when the next one
/// doesn't fit. A subview wider than the whole line is offered the line's width
/// (so a long chip truncates rather than overflowing).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (frames, CGSize(width: usedWidth, height: frames.isEmpty ? 0 : y + lineHeight))
    }
}
