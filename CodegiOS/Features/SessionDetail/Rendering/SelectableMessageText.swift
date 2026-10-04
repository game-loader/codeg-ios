import SwiftUI
import UIKit

/// Read-only UIKit text keeps the system selection handles and range-copy menu
/// on iPhone. Disabling its own scrolling lets the transcript own vertical drag.
struct SelectableMessageText: UIViewRepresentable {
    let content: NSAttributedString
    var isSelectable = true
    var scrolls = false

    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> MessageTextView {
        let view = MessageTextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.linkTextAttributes = [:] // Keep per-reference colors and underline.
        return view
    }

    func updateUIView(_ view: MessageTextView, context: Context) {
        context.coordinator.openURL = { openURL($0) }
        if view.isSelectable != isSelectable { view.isSelectable = isSelectable }
        if view.isScrollEnabled != scrolls { view.isScrollEnabled = scrolls }
        if !view.attributedText.isEqual(to: content) {
            let selected = view.selectedRange
            view.attributedText = content
            if selected.location != NSNotFound, NSMaxRange(selected) <= content.length {
                view.selectedRange = selected
            }
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MessageTextView, context: Context) -> CGSize? {
        if scrolls {
            guard let width = proposal.width, let height = proposal.height,
                  width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }
        guard let width = proposal.width else { return MessageTextView.idealSize(for: content) }
        guard width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: ((URL) -> Void)?

        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            // Preview/context actions retain the system selection behavior.
            guard interaction == .invokeDefaultAction else { return true }
            openURL?(URL)
            return false
        }
    }
}

/// Attachments are drawn as formulas/reference icons, but range-copy keeps the
/// formula's original TeX and omits decorative icons instead of copying U+FFFC.
final class MessageSourceAttachment: NSTextAttachment {
    let source: String

    init(image: UIImage, bounds: CGRect, source: String) {
        self.source = source
        super.init(data: nil, ofType: nil)
        self.image = image
        self.bounds = bounds
    }

    required init?(coder: NSCoder) { return nil }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        // A long inline equation is an indivisible glyph. Fit it to the text
        // column instead of letting TextKit clip it off the edge of an iPhone.
        // Display equations in the transcript use a horizontal scroll surface.
        let width = lineFrag.width - (textContainer?.lineFragmentPadding ?? 0) * 2
        guard !source.isEmpty, width.isFinite, width > 0, bounds.width > width else { return bounds }
        let scale = width / bounds.width
        return CGRect(x: bounds.minX, y: bounds.minY * scale, width: width, height: bounds.height * scale)
    }
}

final class MessageTextView: UITextView {
    // Counts actual TextKit measurements, not SwiftUI layout proposals.
    private(set) var layoutMeasurementCount = 0
    private var measuredSizes: [MeasurementKey: CGSize] = [:]
    private var storageObserver: NSObjectProtocol?

    override init(frame: CGRect = .zero, textContainer: NSTextContainer? = nil) {
        super.init(frame: frame, textContainer: textContainer)
        observeStorage()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeStorage()
    }

    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
    }

    private func observeStorage() {
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil
        ) { [weak self] _ in
            // Includes same-length replacements and attribute/font changes,
            // not just changes to the plain string's length.
            self?.measuredSizes.removeAll(keepingCapacity: true)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let key = MeasurementKey(
            width: size.width, height: size.height,
            top: textContainerInset.top, left: textContainerInset.left,
            bottom: textContainerInset.bottom, right: textContainerInset.right,
            padding: textContainer.lineFragmentPadding,
            maximumLines: textContainer.maximumNumberOfLines,
            lineBreakMode: Int(textContainer.lineBreakMode.rawValue),
            scrolls: isScrollEnabled, fontName: font?.fontName, fontSize: font?.pointSize
        )
        if let measured = measuredSizes[key] { return measured }
        layoutMeasurementCount += 1
        let measured = super.sizeThatFits(size)
        // SwiftUI asks for the same row size repeatedly as the composer/keyboard
        // changes. Keep a small per-view cache, invalidated by TextKit edits.
        if size.width.isFinite, size.height.isFinite,
           measured.width.isFinite, measured.height.isFinite {
            if measuredSizes.count >= 4 { measuredSizes.removeAll(keepingCapacity: true) }
            measuredSizes[key] = measured
        }
        return measured
    }

    private struct MeasurementKey: Hashable {
        let width: CGFloat
        let height: CGFloat
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat
        let padding: CGFloat
        let maximumLines: Int
        let lineBreakMode: Int
        let scrolls: Bool
        let fontName: String?
        let fontSize: CGFloat?
    }

    override func copy(_ sender: Any?) {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0,
              NSMaxRange(selectedRange) <= attributedText.length else { return }
        UIPasteboard.general.string = Self.copyText(from: attributedText, range: selectedRange)
    }

    static func copyText(from content: NSAttributedString, range: NSRange) -> String {
        guard range.location != NSNotFound, range.location >= 0,
              range.length >= 0, NSMaxRange(range) <= content.length else { return "" }
        let selected = content.attributedSubstring(from: range)
        var result = ""
        selected.enumerateAttributes(in: NSRange(location: 0, length: selected.length)) { attributes, run, _ in
            if attributes[.messageDecoration] as? Bool == true {
                return
            } else if let source = attributes[.attachment] as? MessageSourceAttachment {
                result += source.source
            } else {
                result += (selected.string as NSString).substring(with: run)
            }
        }
        return result
    }

    static func idealSize(for content: NSAttributedString) -> CGSize {
        let bounds = content.boundingRect(with: CGSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: max(1, ceil(bounds.width) + 1), height: max(1, ceil(bounds.height) + 1))
    }
}

extension NSAttributedString.Key {
    static let messageDecoration = NSAttributedString.Key("codeg.messageDecoration")
}

/// Plain source/code keeps all bytes, including indentation, while still
/// offering native range selection. Code panels opt out of line wrapping.
struct SelectablePlainText: View {
    let text: String
    var color: Color = Theme.textPrimary
    var code = false

    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let preferred = NativeMarkdownText.font(style: code ? .footnote : .body, category: sizeCategory)
        let font = code ? UIFont.monospacedSystemFont(ofSize: preferred.pointSize, weight: .regular) : preferred
        let content = attributed(font: font)
        if code {
            let bounds = content.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                          height: CGFloat.greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            SelectableMessageText(content: content)
                .frame(width: max(1, ceil(bounds.width) + 1), height: max(font.lineHeight, ceil(bounds.height) + 1))
        } else {
            SelectableMessageText(content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func attributed(font: UIFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = code ? Theme.Typography.codeLineSpacing : Theme.Typography.messageLineSpacing
        paragraph.lineBreakMode = code ? .byClipping : .byWordWrapping
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor(color).resolvedColor(with: traits), .paragraphStyle: paragraph
        ])
    }
}
