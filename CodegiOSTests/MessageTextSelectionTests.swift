import SwiftUI
import UIKit
import XCTest
@testable import Codeg

@MainActor
final class MessageTextSelectionTests: XCTestCase {
    private let font = UIFont.systemFont(ofSize: 17)
    private let traits = UITraitCollection(userInterfaceStyle: .light)

    private func rich(_ text: String) -> NSAttributedString {
        NativeMarkdownText.attributed(text, font: font, color: .black, traits: traits)
    }

    func testPartialRangeCopiesOnlySelectedChineseAndEmojiText() {
        let text = rich("开头🙂 **选这段中文**，不要复制其余内容。")
        let range = (text.string as NSString).range(of: "选这段中文")
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertEqual(MessageTextView.copyText(from: text, range: range), "选这段中文")
        let emoji = (text.string as NSString).range(of: "🙂")
        XCTAssertEqual(MessageTextView.copyText(from: text, range: emoji), "🙂")
    }

    func testCopyRangeSpansPlainBoldLinkAndCodeWithoutMarkdownMarkers() {
        let content = rich("Prefix **bold** [web](https://example.com) and `a_b` suffix")
        let range = (content.string as NSString).range(of: "bold web and a_b")
        XCTAssertEqual(MessageTextView.copyText(from: content, range: range), "bold web and a_b")
        XCTAssertEqual(content.attribute(.link, at: (content.string as NSString).range(of: "web").location,
                                         effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        let bold = content.attribute(.font, at: (content.string as NSString).range(of: "bold").location,
                                     effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    func testFileReferenceKeepsLinkAndCopiesLabelWithoutDecorativeAttachment() {
        let content = rich("Read [source.swift](src/source.swift#L12) now")
        let range = NSRange(location: 0, length: content.length)
        XCTAssertEqual(MessageTextView.copyText(from: content, range: range), "Read source.swift now")
        let label = (content.string as NSString).range(of: "source.swift")
        XCTAssertEqual(content.attribute(.link, at: label.location, effectiveRange: nil) as? URL,
                       URL(string: "src/source.swift#L12"))
    }

    func testFormulaIsDrawnAsAttachmentAndRangeCopyRestoresOriginalLatex() throws {
        let source = #"Before \(\frac{x_1}{\sqrt{y}}\) after"#
        let content = rich(source)
        let range = (content.string as NSString).range(of: "\u{FFFC}")
        XCTAssertNotEqual(range.location, NSNotFound)
        let formula = try XCTUnwrap(content.attribute(.attachment, at: range.location,
                                                     effectiveRange: nil) as? MessageSourceAttachment)
        XCTAssertNotNil(formula.image)
        XCTAssertGreaterThan(formula.bounds.height, 0)
        XCTAssertEqual(MessageTextView.copyText(from: content, range: range), #"\(\frac{x_1}{\sqrt{y}}\)"#)
        XCTAssertEqual(MessageTextView.copyText(from: content, range: NSRange(location: 0, length: content.length)), source)
    }

    func testFormulaInsideEmphasisRetainsSurroundingStyleAndExactSource() {
        let content = rich(#"**Result \(x_i^2\)**"#)
        XCTAssertFalse(content.string.contains("x_i"))
        let range = NSRange(location: 0, length: content.length)
        XCTAssertEqual(MessageTextView.copyText(from: content, range: range), #"Result \(x_i^2\)"#)
    }

    func testInlineCodeAndCurrencyAreLiteralRatherThanAttachments() {
        let source = #"Cost $9.99 or $19.99; `$HOME` and `\(x_i\)`"#
        let content = rich(source)
        XCTAssertFalse(content.string.contains("\u{FFFC}"))
        XCTAssertEqual(content.string, #"Cost $9.99 or $19.99; $HOME and \(x_i\)"#)
    }

    func testLongInlineEquationFitsPhoneColumnAndStillCopiesWholeFormula() throws {
        let source = #"\(a_1+a_2+a_3+a_4+a_5+a_6+a_7+a_8+a_9+a_{10}=b_1+b_2+b_3\)"#
        let content = rich(source)
        let attachment = try XCTUnwrap(content.attribute(.attachment, at: 0, effectiveRange: nil) as? MessageSourceAttachment)
        let bounds = attachment.attachmentBounds(for: NSTextContainer(size: CGSize(width: 120, height: 400)),
            proposedLineFragment: CGRect(x: 0, y: 0, width: 120, height: 400),
            glyphPosition: .zero, characterIndex: 0)
        XCTAssertLessThanOrEqual(bounds.width, 120)
        XCTAssertGreaterThan(bounds.height, 0)
        XCTAssertEqual(MessageTextView.copyText(from: content, range: NSRange(location: 0, length: content.length)), source)
    }

    func testUnsupportedFormulaPreservesSourceWithoutDroppingText() {
        let source = #"Value \(\codegUnknownCommand{x}\) stays available."#
        let content = rich(source)
        XCTAssertEqual(content.string, source)
        XCTAssertFalse(content.string.contains("\u{FFFC}"))
    }

    func testWholeMessageDocumentAllowsRangeAcrossParagraphsAndCode() {
        let source = "First **paragraph**\n\nSecond paragraph\n\n```swift\nlet x = 1\n```"
        let content = MessageSelectionDocument.attributed(source, font: font, color: .black, traits: traits)
        XCTAssertEqual(MessageTextView.copyText(from: content, range: NSRange(location: 0, length: content.length)),
                       "First paragraph\n\nSecond paragraph\n\nlet x = 1")
        let range = (content.string as NSString).range(of: "paragraph\n\nSecond paragraph\n\nlet x")
        XCTAssertEqual(MessageTextView.copyText(from: content, range: range), "paragraph\n\nSecond paragraph\n\nlet x")
    }

    func testWholeMessageFormulaCopyIncludesDisplaySourceAndNoPlaceholders() {
        let source = "Introduction\n\n" + #"\[\sum_{i=1}^n i\]"# + "\n\nConclusion"
        let content = MessageSelectionDocument.attributed(source, font: font, color: .black, traits: traits)
        let copied = MessageTextView.copyText(from: content, range: NSRange(location: 0, length: content.length))
        XCTAssertEqual(copied, source)
        XCTAssertFalse(copied.contains("\u{FFFC}"))
    }

    func testSystemCopyActionCopiesOnlyTheSelectedRange() {
        let view = MessageTextView()
        view.isEditable = false
        view.isSelectable = true
        view.attributedText = rich("Don't copy this; copy **this part** only")
        view.selectedRange = (view.attributedText.string as NSString).range(of: "this part")
        let previous = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previous }
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "this part")
    }

    func testLinkActivationUsesAppRouterWithoutReplacingSelectionMenu() throws {
        let coordinator = SelectableMessageText.Coordinator()
        let url = try XCTUnwrap(URL(string: "file:///tmp/workspace/report.pdf"))
        var opened: URL?
        coordinator.openURL = { opened = $0 }
        let view = MessageTextView()
        XCTAssertFalse(coordinator.textView(view, shouldInteractWith: url,
            in: NSRange(location: 0, length: 1), interaction: .invokeDefaultAction))
        XCTAssertEqual(opened, url)
        opened = nil
        XCTAssertTrue(coordinator.textView(view, shouldInteractWith: url,
            in: NSRange(location: 0, length: 1), interaction: .presentActions))
        XCTAssertNil(opened)
    }

    func testHostedTextIsReadOnlySelectableAndFitsNarrowTranscriptWidth() async throws {
        let content = rich("可选择的中文正文与 bold text that wraps across a narrow iPhone column.")
        let host = UIHostingController(rootView: SelectableMessageText(content: content).frame(width: 180))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> MessageTextView? {
            if let text = view as? MessageTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try XCTUnwrap(find(host.view))
        XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.isScrollEnabled)
        XCTAssertEqual(text.textContainerInset, .zero)
        XCTAssertLessThanOrEqual(text.bounds.width, 181)
        XCTAssertGreaterThan(text.bounds.height, font.lineHeight * 2)
        text.selectedRange = (text.attributedText.string as NSString).range(of: "中文正文")
        XCTAssertEqual(text.selectedTextRange.flatMap { text.text(in: $0) }, "中文正文")
    }

    func testDarkModeAndDynamicTypeDoNotReuseWrongAttributedAppearance() throws {
        let light = rich("Theme")
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let dark = NativeMarkdownText.attributed("Theme", font: font, color: .white, traits: darkTraits)
        XCTAssertNotEqual(light.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
                          dark.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        let largeFont = NativeMarkdownText.font(style: .body, category: .accessibilityExtraExtraExtraLarge)
        XCTAssertGreaterThan(largeFont.pointSize, font.pointSize)
        let large = NativeMarkdownText.attributed("Theme", font: largeFont, color: .black, traits: traits)
        XCTAssertEqual((large.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, largeFont.pointSize)
    }

    func testWholeMessageSheetFillsViewportAndScrollsLongContent() async throws {
        let raw = Array(repeating: "A paragraph for cross-paragraph selection.", count: 50).joined(separator: "\n\n")
        let host = UIHostingController(rootView: MessageSelectionSheet(raw: raw))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 480))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> MessageTextView? {
            if let text = view as? MessageTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try XCTUnwrap(find(host.view))
        XCTAssertTrue(text.isSelectable)
        XCTAssertTrue(text.isScrollEnabled)
        XCTAssertFalse(text.isEditable)
        XCTAssertGreaterThan(text.bounds.height, 200)
        XCTAssertGreaterThan(text.contentSize.height, text.bounds.height)
        XCTAssertEqual(MessageTextView.copyText(from: text.attributedText,
            range: NSRange(location: 0, length: text.attributedText.length)), raw)
    }

    func testTableContentRetainsUsefulNaturalColumnWidth() {
        let short = MessageTextView.idealSize(for: rich("ID"))
        let wide = MessageTextView.idealSize(for: rich("A reasonably long table heading"))
        XCTAssertGreaterThan(wide.width, 100)
        XCTAssertGreaterThan(wide.width, short.width)
        XCTAssertLessThan(short.height, font.lineHeight * 2)
    }
}
