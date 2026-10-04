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
            ComposeBar(
                text: $model.draft, isInFlight: false, notice: nil,
                attachments: [], canAttachMore: true,
                onAddAttachments: { _ in }, onRemoveAttachment: { _ in },
                onRetryAttachment: { _ in }, onNotice: { _ in },
                onSend: {}, onStop: {}, onDismissNotice: {}, insertModel: model.insertModel
            )
        }
    }
}
