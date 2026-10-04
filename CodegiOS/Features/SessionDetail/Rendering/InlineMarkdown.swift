import SwiftUI
import UIKit

/// Inline Markdown (bold, italic, strikethrough, code spans, links) rendered to
/// a single `Text`, the way codeg web shows it: a code span is a monospaced pill,
/// a file or `codeg://` reference is a colored token with an icon, a web link is
/// underlined. One `Text` (not an HStack of pieces) so it wraps like prose.
///
/// A code span's pill is drawn by `InlineCodeRenderer`, which needs the runs to
/// carry `InlineCodeAttribute`; views showing a result with `hasCode` must apply
/// `.textRenderer(InlineCodeRenderer())` — `InlineMarkdownText` does.
enum InlineMarkdown {
    /// Where the text sits, which decides the code span's font: body prose uses
    /// a slightly smaller mono face (SF Mono runs large next to SF Pro); other
    /// contexts keep their own size.
    enum Style: Hashable {
        case body
        case heading
        case compact
    }

    struct Rendered {
        let text: Text
        let hasCode: Bool
    }

    /// Cached: a recycled `List` row re-displays a turn without re-parsing.
    /// A streaming paragraph passes `cached: false` — every partial string is
    /// distinct, so caching it would only evict settled entries.
    static func render(_ raw: String, style: Style, cached: Bool = true) -> Rendered {
        guard cached else { return build(raw, style: style) }
        let key = CacheKey(raw: raw, style: style)
        if let hit = cache[key] { return hit }
        let rendered = build(raw, style: style)
        cache[key] = rendered
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return rendered
    }

    /// Joins `Text` pieces through string interpolation: `+` is deprecated as of
    /// iOS 26, and a key made of placeholders only never matches a translation.
    static func concatenate(_ pieces: [Text]) -> Text {
        if pieces.isEmpty { return Text(verbatim: "") }
        if pieces.count == 1 { return pieces[0] }
        var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: pieces.count)
        for piece in pieces { interpolation.appendInterpolation(piece) }
        return Text(LocalizedStringKey(stringInterpolation: interpolation))
    }

    // MARK: Building

    private static func build(_ raw: String, style: Style) -> Rendered {
        let parsed = MarkdownText.attributed(from: raw)
        var pieces: [Text] = []
        var chunk = AttributedString()
        var hasCode = false

        func flush() {
            guard !chunk.characters.isEmpty else { return }
            pieces.append(Text(chunk))
            chunk = AttributedString()
        }

        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                hasCode = true
                // Room for the pill's padding: widen the character before the
                // span and the span's last one, so neither neighbour touches it.
                pad(lastCharacterOf: &chunk)
                var code = AttributedString(String(piece.characters))
                pad(lastCharacterOf: &code)
                flush()
                pieces.append(codeText(code, style: style))
                continue
            }
            if let url = run.link, let reference = Reference(url: url) {
                flush()
                pieces.append(
                    Text(Image(systemName: reference.symbol(label: String(piece.characters))))
                        .font(style == .body ? .subheadline : nil)
                        .foregroundStyle(reference.color)
                )
                // A no-break space, so the icon never ends a line on its own.
                chunk += AttributedString("\u{00A0}")
                piece.swiftUI.foregroundColor = reference.color
                chunk += piece
                continue
            }
            if run.link != nil {
                // The accent may be the neutral near-text gray, so the underline
                // is what marks a link.
                piece.swiftUI.underlineStyle = .single
            }
            chunk += piece
        }
        flush()
        return Rendered(text: concatenate(pieces), hasCode: hasCode)
    }

    private static func codeText(_ code: AttributedString, style: Style) -> Text {
        let text = Text(code).customAttribute(InlineCodeAttribute())
        switch style {
        case .body: return text.font(.system(.callout, design: .monospaced))
        case .heading, .compact: return text.monospaced()
        }
    }

    private static func pad(lastCharacterOf string: inout AttributedString) {
        guard !string.characters.isEmpty else { return }
        let last = string.characters.index(before: string.endIndex)
        string[last..<string.endIndex].swiftUI.kern = InlineCodeRenderer.padding
    }

    // MARK: Cache

    private struct CacheKey: Hashable {
        let raw: String
        let style: Style
    }

    /// Main-thread only (read from `body`), like `MarkdownText`'s cache.
    private static var cache: [CacheKey: Rendered] = [:]
    private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 800
}

// MARK: - References

/// A link the transcript shows as a colored token instead of an underlined
/// link: a file (a `file://` uri, or a path the way agents link source files)
/// or one of the composer's `codeg://` references. Colors follow codeg web.
enum Reference {
    case file(name: String)
    case session
    case agent
    case commit
    case skill

    init?(url: URL) {
        switch url.scheme?.lowercased() {
        case "file":
            self = .file(name: url.lastPathComponent)
        case "codeg":
            switch url.host?.lowercased() {
            case "session": self = .session
            case "agent": self = .agent
            case "commit": self = .commit
            case "skill": self = .skill
            // A pasted attachment's inert display uri.
            case "embedded": self = .file(name: "")
            default: return nil
            }
        case nil:
            // `[main.rs:12](src/main.rs#L12)`: scheme-less and path-like. A bare
            // `#anchor` is not a file.
            guard let path = Self.filePath(of: url) else { return nil }
            self = .file(name: (path as NSString).lastPathComponent)
        default:
            return nil
        }
    }

    /// The path a scheme-less link points at, without a `#L12` fragment or a
    /// `:12` line suffix; nil when it doesn't look like a file.
    static func filePath(of url: URL) -> String? {
        guard url.scheme == nil else { return url.isFileURL ? url.path : nil }
        var path = url.relativeString
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        path = path.removingPercentEncoding ?? path
        if let lineSuffix = path.range(of: #":\d+(:\d+)?(-\d+)?$"#, options: .regularExpression) {
            path.removeSubrange(lineSuffix)
        }
        guard !path.isEmpty, path.contains("/") || !(path as NSString).pathExtension.isEmpty else { return nil }
        return path
    }

    func symbol(label: String) -> String {
        switch self {
        case .file(let name): return FileIcon.symbol(for: name.isEmpty ? label : name)
        case .session: return "bubble.left"
        case .agent: return "at"
        case .commit: return "number"
        case .skill: return "command"
        }
    }

    var color: Color {
        switch self {
        case .file: return ReferencePalette.file
        case .session: return ReferencePalette.session
        case .agent: return ReferencePalette.agent
        case .commit: return ReferencePalette.commit
        case .skill: return ReferencePalette.skill
        }
    }
}

/// Reference-token hues (codeg web: blue files, emerald sessions, amber
/// commits, violet agents, rose skills). Not accent-driven, like `DiffPalette`.
enum ReferencePalette {
    static let file = Color(
        light: Color(red: 0.11, green: 0.39, blue: 0.87),
        dark: Color(red: 0.45, green: 0.68, blue: 1.00)
    )
    static let session = Color(
        light: Color(red: 0.02, green: 0.52, blue: 0.37),
        dark: Color(red: 0.25, green: 0.83, blue: 0.60)
    )
    static let commit = Color(
        light: Color(red: 0.71, green: 0.36, blue: 0.03),
        dark: Color(red: 0.98, green: 0.75, blue: 0.24)
    )
    static let agent = Color(
        light: Color(red: 0.43, green: 0.23, blue: 0.86),
        dark: Color(red: 0.70, green: 0.60, blue: 1.00)
    )
    static let skill = Color(
        light: Color(red: 0.83, green: 0.13, blue: 0.33),
        dark: Color(red: 0.98, green: 0.48, blue: 0.58)
    )
}

// MARK: - Code span pills

/// Marks the runs of a code span for `InlineCodeRenderer`.
struct InlineCodeAttribute: TextAttribute {}

/// Draws a capsule behind each code span, then the text over it. The span's
/// neighbours are kerned by `padding` (see `InlineMarkdown`), so the capsule
/// reaches that far past the glyphs without covering them.
struct InlineCodeRenderer: TextRenderer {
    static let padding: CGFloat = 4

    /// A span starting a line reaches `padding` left of the text's frame.
    var displayPadding: EdgeInsets {
        EdgeInsets(top: 0, leading: Self.padding, bottom: 0, trailing: 0)
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            // Adjacent runs of one span (a font fallback splits them) share one
            // capsule, or the overlaps would darken.
            var span: CGRect?
            for run in line {
                if run[InlineCodeAttribute.self] != nil {
                    let rect = run.typographicBounds.rect
                    span = span.map { $0.union(rect) } ?? rect
                } else if let rect = span {
                    fill(rect, in: &ctx)
                    span = nil
                }
            }
            if let rect = span { fill(rect, in: &ctx) }
        }
        for line in layout { ctx.draw(line) }
    }

    private func fill(_ rect: CGRect, in ctx: inout GraphicsContext) {
        // The kern on the span's last character already pads its right side.
        let pill = CGRect(x: rect.minX - Self.padding, y: rect.minY,
                          width: rect.width + Self.padding, height: rect.height)
        ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Self.pillColor))
    }

    static let pillColor = Color(light: .black.opacity(0.065), dark: .white.opacity(0.11))
}

/// One run of inline Markdown as a view, with the transcript's reading style.
struct InlineMarkdownText: View {
    let raw: String
    var style: InlineMarkdown.Style = .body
    var font: Font = Theme.Typography.messageBody
    var color: Color = Theme.textPrimary
    var lineSpacing: CGFloat = Theme.Typography.messageLineSpacing
    /// Appended to the text: the streaming "typing" caret (`CaretParagraph`).
    var caret: Text?
    var alignment: TextAlignment = .leading
    var uiTextStyle: UIFont.TextStyle = .body
    var uiWeight: UIFont.Weight? = nil
    var caretVisible = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sizeCategory) private var sizeCategory

    var body: some View {
        if let caret {
            // Streaming remains lightweight SwiftUI text for ordinary prose;
            // complete formulas switch to the native attributed renderer.
            let masked = MarkdownMath.maskInline(raw)
            if masked.formulas.isEmpty {
                let rendered = InlineMarkdown.render(raw, style: style, cached: false)
                styled(InlineMarkdown.concatenate([rendered.text, caret]), hasCode: rendered.hasCode)
            } else {
                nativeText(isSelectable: false)
            }
        } else {
            nativeText(isSelectable: true)
        }
    }

    private func nativeText(isSelectable: Bool) -> some View {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let nativeFont = NativeMarkdownText.font(style: uiTextStyle, weight: uiWeight, category: sizeCategory)
        let content = NSMutableAttributedString(attributedString: NativeMarkdownText.attributed(raw,
            font: nativeFont,
            color: UIColor(color), lineSpacing: lineSpacing,
            alignment: alignment == .center ? .center : (alignment == .trailing ? .right : .left),
            traits: traits, cached: caret == nil))
        if caret != nil {
            content.append(NSAttributedString(string: " ▌", attributes: [
                .font: NativeMarkdownText.font(style: uiTextStyle, category: sizeCategory),
                .foregroundColor: UIColor(Theme.accent).resolvedColor(with: traits).withAlphaComponent(caretVisible ? 1 : 0)
            ]))
        }
        return SelectableMessageText(content: content, isSelectable: isSelectable)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .alignmentGuide(.firstTextBaseline) { _ in nativeFont.ascender }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    @ViewBuilder
    private func styled(_ text: Text, hasCode: Bool) -> some View {
        let base = text
            .font(font)
            .lineSpacing(lineSpacing)
            .foregroundStyle(color)
            .tint(Theme.accent)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        // A streaming paragraph changes every few frames; selection only makes
        // sense once it has settled.
        if hasCode {
            if caret == nil {
                base.textRenderer(InlineCodeRenderer()).textSelection(.enabled)
            } else {
                base.textRenderer(InlineCodeRenderer())
            }
        } else if caret == nil {
            base.textSelection(.enabled)
        } else {
            base
        }
    }
}
