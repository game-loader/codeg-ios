import Foundation
import XCTest
@testable import Codeg

@MainActor
final class ConversationTagRefreshTests: XCTestCase {
    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message, file: file, line: line)
        throw URLError(.timedOut)
    }

    func testTagRefreshKeepsLiveStreamTranscriptAndDraft() async throws {
        let h = try RecoveryHarness()
        defer { h.close() }
        h.server.setDetail(text: "Original transcript", status: "in_progress")
        h.server.setConnected(true)
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Live reply")
        await h.model.load()
        try await eventually("Live stream attaches") { h.liveText == "Live reply" }
        let stream = try XCTUnwrap(h.streams.last)
        let originalTurns = h.persistedText
        let originalTitle = h.model.summary?.title
        let originalStatus = h.model.summary?.status
        let originalPhase = h.model.phase
        h.model.draft = "Unsent draft"
        var detail = RecoveryFixtures.detail(text: "Unrelated new transcript", status: "completed")
        var summary = detail["summary"] as! [String: Any]
        summary["tag_ids"] = [4, 9]
        summary["title"] = "Concurrent rename"
        detail["summary"] = summary
        h.server.setDetailPayload(detail)

        await h.model.reload()

        XCTAssertEqual(h.model.summary?.tagIds, [4, 9])
        XCTAssertEqual(h.model.summary?.title, originalTitle)
        XCTAssertEqual(h.model.summary?.status, originalStatus)
        XCTAssertEqual(h.persistedText, originalTurns)
        XCTAssertEqual(h.liveText, "Live reply")
        XCTAssertEqual(h.model.draft, "Unsent draft")
        XCTAssertEqual(h.model.phase, originalPhase)
        XCTAssertTrue(h.model.isInFlight)
        XCTAssertTrue(h.streams.last === stream)
        XCTAssertFalse(stream.isClosed)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        XCTAssertEqual(h.server.count("acp_cancel"), 0)
    }

    func testLateTagRefreshCannotPublishAfterTeardown() async throws {
        let h = try RecoveryHarness()
        defer { h.close() }
        await h.model.load()
        var detail = RecoveryFixtures.detail(text: "Late transcript")
        var summary = detail["summary"] as! [String: Any]
        summary["tag_ids"] = [9]
        detail["summary"] = summary
        h.server.setDetailPayload(detail)
        let gate = h.server.holdNextDetail()
        let task = Task { await h.model.reload() }
        try await eventually("Tag refresh reaches response barrier") { gate.hasRequest }
        h.model.teardown()
        let previous = h.model.summary?.tagIds
        gate.release()
        await task.value
        XCTAssertEqual(h.model.summary?.tagIds, previous)
    }
}
