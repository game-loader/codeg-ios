import Foundation
import XCTest
@testable import Codeg

@MainActor
final class SessionForegroundRecoveryTests: XCTestCase {
    // Wait on observable state with deadlines, not guessed transport delays.
    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), message, file: file, line: line)
        if !predicate() { throw URLError(.timedOut) }
    }
    private func finish(_ h: RecoveryHarness, file: StaticString = #filePath, line: UInt = #line) {
        h.close()
        XCTAssertEqual(h.server.unexpectedRequests, [], file: file, line: line)
    }
    private func running(_ h: RecoveryHarness, pending: Bool = false) async throws {
        h.server.setDetail(text: "Partial persisted reply", status: "in_progress")
        h.server.setConnected(true)
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Hello", pending: pending)
        await h.model.load()
        try await eventually("Initial stream must attach") { h.liveText == "Hello" && h.model.isInFlight }
    }

    func testInitialResumeLoadsThenIdleForegroundRefetchPreservesDraft() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        await h.model.resume()
        XCTAssertEqual(h.model.phase, .loaded)
        XCTAssertTrue(h.persistedText.contains("Old reply"))
        XCTAssertEqual(h.model.folder?.id, 7)
        XCTAssertGreaterThan(h.server.count("list_all_folder_details"), 0)
        h.model.draft = "Unsent local draft"
        let before = h.server.count("get_folder_conversation")
        h.server.setDetail(text: "Finished on another client")
        await h.model.resume()
        XCTAssertGreaterThan(h.server.count("get_folder_conversation"), before)
        XCTAssertTrue(h.persistedText.contains("Finished on another client"))
        XCTAssertFalse(h.persistedText.contains("Old reply"))
        XCTAssertEqual(h.model.draft, "Unsent local draft")
        XCTAssertFalse(h.model.isInFlight)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
    }

    func testForegroundReplacesPartialWithFullSnapshotThenAppendsOnlyNewDelta() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h)
        let oldStream = try XCTUnwrap(h.streams.last)
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Hello world")
        await h.model.resume()
        try await eventually("Recovery must replace, not concatenate, the full snapshot") {
            h.liveText == "Hello world" && h.streams.count == 2
        }
        let recovered = try XCTUnwrap(h.streams.last)
        XCTAssertTrue(oldStream.isClosed)
        XCTAssertTrue(recovered.attachedWithoutReplay)
        XCTAssertTrue(h.model.liveTurnFromReattach)
        recovered.emit(try RecoveryFixtures.event("content_delta", fields: ["text": "!"]))
        try await eventually("Fresh deltas must append to the recovered text") { h.liveText == "Hello world!" }
        XCTAssertTrue(h.model.isInFlight)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
    }

    func testMissedTurnCompleteRefreshesFinalTranscriptAndStopsSpinner() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h)
        h.server.setDetail(text: "Final complete reply", status: "completed")
        h.server.setConnected(false)
        h.nextSnapshot = try RecoveryFixtures.snapshot()
        // No turn_complete event: the terminal frame was missed in background.
        await h.model.resume()
        try await eventually("A missed terminal frame must not leave a spinner") {
            !h.model.isInFlight && h.persistedText.contains("Final complete reply")
        }
        XCTAssertEqual(h.model.sendState, .idle)
        XCTAssertNil(h.model.liveTurn)
        XCTAssertEqual(h.model.pendingUserTurns.count, 0)
    }

    func testIdleAttachSnapshotSettlesAMissedCompletionOnAnExistingConnection() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h)
        h.server.setDetail(text: "Final reply from idle connection")
        // Connection still exists, but its authoritative snapshot is now idle.
        h.nextSnapshot = try RecoveryFixtures.snapshot()
        await h.model.resume()
        try await eventually("An idle snapshot must reconcile a missed terminal event") {
            h.persistedText.contains("Final reply from idle connection") && h.model.liveTurn == nil
        }
        XCTAssertEqual(h.model.sendState, .idle)
        XCTAssertFalse(h.model.isInFlight)
        XCTAssertNil(h.model.pendingPermission)
        XCTAssertNil(h.model.pendingQuestion)
    }

    func testNewModeCreatedAndLinkedConversationRecoversOnForeground() async throws {
        let h = try RecoveryHarness(newSession: true)
        defer { finish(h) }
        await h.model.load()
        XCTAssertNil(h.model.conversationID)
        h.model.draft = "First prompt"
        h.model.send()
        try await eventually("Draft must create and submit its first conversation") {
            h.server.count("acp_prompt") == 1 && h.model.conversationID == 42
        }
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("conversation_linked", fields: ["conversation_id": 42, "folder_id": 7]))
        h.server.setDetail(text: "New session completed while away", status: "completed")
        let before = h.server.count("get_folder_conversation")
        h.model.draft = "Next unsent prompt"
        await h.model.resume()
        try await eventually("New mode must refresh its adopted conversation ID") {
            h.persistedText.contains("New session completed while away") && !h.model.isInFlight
        }
        XCTAssertGreaterThan(h.server.count("get_folder_conversation"), before)
        XCTAssertEqual(h.model.draft, "Next unsent prompt")
        XCTAssertEqual(h.server.count("create_conversation"), 1)
        XCTAssertEqual(h.server.count("acp_prompt"), 1)
    }

    func testFailedForegroundRefreshKeepsVisibleTranscriptAndDraft() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        await h.model.load()
        let original = h.model.turns
        h.model.draft = "Keep this draft"
        h.server.setDetail(text: "Must not appear", httpStatus: 503)
        await h.model.resume()
        XCTAssertEqual(h.model.phase, .loaded)
        XCTAssertEqual(h.model.turns, original)
        XCTAssertEqual(h.model.draft, "Keep this draft")
        XCTAssertFalse(h.model.isInFlight)
    }

    func testFreshSnapshotClearsPermissionAndQuestionResolvedElsewhere() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h, pending: true)
        XCTAssertEqual(h.model.pendingPermission?.requestId, "permission-1")
        XCTAssertEqual(h.model.pendingQuestion?.questionId, "question-1")
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Continuing after approval")
        await h.model.resume()
        try await eventually("Fresh snapshot must clear both stale cards") {
            h.liveText == "Continuing after approval" && h.model.pendingPermission == nil && h.model.pendingQuestion == nil
        }
        XCTAssertTrue(h.model.isInFlight)
    }

    func testRefreshSupersededBySendCannotOverwriteOptimisticTurn() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        await h.model.load()
        let original = h.model.turns
        h.server.setDetail(text: "Stale recovery result")
        let gate = h.server.holdNextDetail()
        defer { gate.release() }
        let recovery = Task { await h.model.resume() }
        defer { recovery.cancel() }
        try await eventually("Recovery request must be suspended") { gate.hasRequest }
        h.model.draft = "A newer send"
        h.model.send()
        try await eventually("New send must reach the server") { h.server.count("acp_prompt") == 1 }
        let currentLive = h.model.liveTurn
        gate.release()
        await recovery.value
        XCTAssertEqual(h.model.turns, original)
        XCTAssertEqual(RecoveryHarness.text(h.model.pendingUserTurns), "A newer send")
        XCTAssertTrue(h.model.liveTurn === currentLive)
        XCTAssertTrue(h.model.isInFlight)
    }

    func testRefreshSupersededByCancelCannotResurrectStreaming() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h)
        let original = h.model.turns
        h.server.setDetail(text: "Stale recovery result", status: "in_progress")
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Must not resurrect")
        let gate = h.server.holdNextDetail()
        defer { gate.release() }
        let recovery = Task { await h.model.resume() }
        defer { recovery.cancel() }
        try await eventually("Recovery request must be suspended") { gate.hasRequest }
        h.model.cancel()
        let streamCount = h.streams.count
        gate.release()
        await recovery.value
        XCTAssertEqual(h.model.turns, original)
        XCTAssertFalse(h.model.isInFlight)
        XCTAssertEqual(h.model.sendState, .idle)
        XCTAssertEqual(h.streams.count, streamCount)
        try await eventually("Cancellation must reach existing connection") { h.server.count("acp_cancel") == 1 }
    }

    func testRefreshSupersededByTeardownCannotMutateTranscriptOrOpenStream() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        await h.model.load()
        let original = h.model.turns
        h.server.setDetail(text: "Stale recovery result", status: "in_progress")
        h.server.setConnected(true)
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Must not attach")
        let gate = h.server.holdNextDetail()
        defer { gate.release() }
        let recovery = Task { await h.model.resume() }
        defer { recovery.cancel() }
        try await eventually("Recovery request must be suspended") { gate.hasRequest }
        h.model.teardown()
        gate.release()
        await recovery.value
        XCTAssertEqual(h.model.turns, original)
        XCTAssertTrue(h.streams.isEmpty)
        XCTAssertFalse(h.model.isInFlight)
    }

    func testSocketDropRecoversWithoutForegroundTransition() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h)
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Hello after network gap")
        h.streams.last?.emit(.closed(reason: "Network changed"))
        try await eventually("Automatic reconnect must apply the complete snapshot") {
            h.liveText == "Hello after network gap" && h.streams.count == 2
        }
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
    }

    func testTerminalStatusCannotReplaceFullReplyWithUnchangedPartial() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h)
        h.streams.last?.emit(try RecoveryFixtures.event("content_delta", fields: ["text": " complete reply"]))
        try await eventually("Full live reply must be present") { h.liveText == "Hello complete reply" }
        h.server.setDetail(text: "Partial persisted reply", status: "completed")
        h.nextSnapshot = try RecoveryFixtures.snapshot()
        await h.model.resume()
        try await eventually("Keep the full reply when terminal metadata beats persistence") {
            !h.model.isInFlight && h.persistedText.contains("Hello complete reply")
        }
        XCTAssertFalse(h.persistedText.contains("Partial persisted reply"))
    }

    func testFirstSnapshotFailureStillReconcilesSameCountFinalReply() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Partial", status: "in_progress")
        h.server.setConnected(true)
        h.nextDeliversSnapshot = false
        await h.model.load()
        try await eventually("First socket must attempt attach") { h.streams.last?.attachedWithoutReplay == true }
        h.server.setDetail(text: "Final complete reply", status: "completed")
        h.nextDeliversSnapshot = true
        h.streams.last?.emit(.closed(reason: "Lost before first snapshot"))
        try await eventually("Same-count completion must recover even before the first snapshot") {
            !h.model.isInFlight && h.persistedText.contains("Final complete reply")
        }
    }

    func testAcceptedPromptRecoversBeforeDelayedHTTPResponseAndSurvivesItsFailure() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        await h.model.load()
        let gate = h.server.holdNextPrompt(httpStatus: 503)
        defer { gate.release() }
        h.model.draft = "Submit only once"
        h.model.send()
        try await eventually("Prompt response must still be pending") { gate.hasRequest }
        let messageID = try XCTUnwrap(h.server.submittedMessageID)
        h.server.setDetail(text: "Partial", status: "in_progress")
        h.server.setConnected(true)
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Accepted and streaming", messageID: messageID)
        let recovery = Task { await h.model.resume() }
        defer { recovery.cancel() }
        try await eventually("Foreground recovery must not wait for the POST response") {
            h.liveText == "Accepted and streaming"
        }
        gate.release()
        await recovery.value
        // Ensure the late HTTP failure has been processed by the send pipeline.
        await h.model.resume()
        try await eventually("Confirmed prompt must survive a late HTTP failure") {
            h.liveText == "Accepted and streaming" && h.model.isInFlight
        }
        XCTAssertEqual(h.server.count("acp_prompt"), 1)
        XCTAssertEqual(h.model.draft, "")
    }

    func testForegroundPreservesCompletedLocalReplyWhenOnlyUserTurnPersisted() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        await h.model.load()
        h.model.draft = "A new question"
        h.model.send()
        try await eventually("Local prompt must be accepted") { h.server.count("acp_prompt") == 1 }
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("content_delta", fields: ["text": "Entire new reply"]))
        try await eventually("Reply must stream") { h.liveText == "Entire new reply" }
        var detail = RecoveryFixtures.detail(text: "Old reply", status: "completed")
        var turns = detail["turns"] as! [[String: Any]]
        turns.append(["id": "user-2", "role": "user", "timestamp": RecoveryFixtures.date,
                      "blocks": [["type": "text", "text": "A new question"]]])
        detail["turns"] = turns
        h.server.setDetailPayload(detail)
        stream.emit(try RecoveryFixtures.event("turn_complete", fields: ["stop_reason": "end_turn"]))
        try await eventually("Completion event must settle the spinner") { !h.model.isInFlight }
        await h.model.resume()
        XCTAssertTrue((h.persistedText + h.liveText).contains("Entire new reply"))
        XCTAssertEqual(h.server.count("acp_prompt"), 1)
    }
}
