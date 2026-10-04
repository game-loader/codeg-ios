import SwiftUI
import UIKit
import XCTest
@testable import Codeg

@MainActor
final class ComposerPerformanceTests: XCTestCase {
    func testRepeatedTranscriptLayoutDoesNotRemeasureUnchangedText() {
        let view = MessageTextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.attributedText = NativeMarkdownText.attributed(
            String(repeating: "Long 中文 paragraph with **bold** and \\(x_i^2\\). ", count: 100),
            font: .systemFont(ofSize: 17), color: .black)
        let proposal = CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude)
        let expected = view.sizeThatFits(proposal)
        for _ in 0..<30 {
            XCTAssertEqual(view.sizeThatFits(proposal), expected)
        }
        print("Transcript measurement count: \(view.layoutMeasurementCount)")
        XCTAssertEqual(view.layoutMeasurementCount, 1)
    }

    func testTranscriptMeasurementsInvalidateForWidthTextAttributesAndInsets() {
        let view = MessageTextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.attributedText = NSAttributedString(string: String(repeating: "中文 paragraph ", count: 100),
                                                 attributes: [.font: UIFont.systemFont(ofSize: 17)])
        let wide = CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude)
        let narrow = CGSize(width: 140, height: CGFloat.greatestFiniteMagnitude)
        let first = view.sizeThatFits(wide)
        XCTAssertGreaterThan(view.sizeThatFits(narrow).height, first.height)
        XCTAssertEqual(view.sizeThatFits(wide), first)
        XCTAssertEqual(view.layoutMeasurementCount, 2)

        view.attributedText = NSAttributedString(string: "short", attributes: [.font: UIFont.systemFont(ofSize: 17)])
        let short = view.sizeThatFits(wide)
        XCTAssertLessThan(short.height, first.height)
        XCTAssertEqual(view.layoutMeasurementCount, 3)

        view.textStorage.addAttribute(.font, value: UIFont.systemFont(ofSize: 40),
                                      range: NSRange(location: 0, length: view.textStorage.length))
        let large = view.sizeThatFits(wide)
        XCTAssertGreaterThan(large.height, short.height)
        XCTAssertEqual(view.layoutMeasurementCount, 4)

        view.textContainerInset.top += 20
        XCTAssertGreaterThan(view.sizeThatFits(wide).height, large.height)
        XCTAssertEqual(view.layoutMeasurementCount, 5)

        view.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "other")
        _ = view.sizeThatFits(wide)
        XCTAssertEqual(view.layoutMeasurementCount, 6, "Same-length text edits must invalidate the cache")
    }

    func testDraftTypingDoesNotInvalidateSessionParent() async throws {
        let harness = try RecoveryHarness()
        defer { harness.close() }
        let counter = BodyCounter()
        let host = UIHostingController(rootView: ComposerParentProbe(model: harness.model, counter: counter))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let before = counter.evaluations
        for character in "zhongwen中文输入" {
            harness.model.draft.append(character)
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
        }
        print("Session parent bodies for typing: \(counter.evaluations - before)")
        XCTAssertEqual(counter.evaluations, before)
        XCTAssertEqual(harness.model.draft, "zhongwen中文输入")
    }
}

@MainActor
private final class BodyCounter {
    var evaluations = 0
    func record() { evaluations += 1 }
}

private struct ComposerParentProbe: View {
    @State var model: SessionDetailViewModel
    let counter: BodyCounter

    var body: some View {
        let _ = counter.record()
        VStack {
            MarkdownContent(raw: "Transcript with **rich content** and \\(x^2\\).")
            SessionComposeBar(model: model)
        }
    }
}
