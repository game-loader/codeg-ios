import Foundation
import XCTest
@testable import Codeg

@MainActor
final class SessionToolBoundaryTests: XCTestCase {
    private var sequence: UInt64 = 100

    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let satisfied = predicate()
        XCTAssertTrue(satisfied, message, file: file, line: line)
        if !satisfied { throw URLError(.timedOut) }
    }

    private func finish(_ h: RecoveryHarness, file: StaticString = #filePath, line: UInt = #line) {
        h.close()
        XCTAssertEqual(h.server.unexpectedRequests, [], file: file, line: line)
    }

    private func running(_ h: RecoveryHarness, native: Bool? = true,
                         feedback: [[String: Any]] = []) async throws {
        h.server.setDetail(text: "Partial reply", status: "in_progress")
        h.server.setConnected(true)
        h.server.setFeedbackEnabled(true)
        h.server.setConnectionSnapshot(native.map { ["native_steering_available": $0] } ?? [:])
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Working", nativeSteeringAvailable: native,
                                                       feedback: feedback)
        await h.model.load()
        try await eventually("The running conversation must attach") {
            h.liveText == "Working" && h.model.isInFlight
        }
        if native == true, h.model.agentTypeForUI == .codex {
            try await eventually("Native delivery must be advertised only after settings load") {
                h.model.usesToolBoundaryDelivery
            }
        }
        // Later ordinary prompts attach to an idle connection before submission.
        h.nextSnapshot = try RecoveryFixtures.snapshot()
    }

    @discardableResult
    private func queue(_ h: RecoveryHarness, _ text: String, images: [Attachment] = []) throws -> UUID {
        h.model.draft = text
        h.model.addAttachments(images)
        h.model.send()
        return try XCTUnwrap(h.model.queuedMessages.last?.id)
    }

    private func emit(_ h: RecoveryHarness, _ type: String, _ fields: [String: Any] = [:]) throws {
        sequence += 1
        try XCTUnwrap(h.streams.last).emit(RecoveryFixtures.event(type, fields: fields, seq: sequence))
    }

    private func boundary(_ h: RecoveryHarness, id: String = "tool-1", status: String = "completed",
                          type: String = "tool_call_update") throws {
        try emit(h, type, ["tool_call_id": id, "title": "Read file", "kind": "read", "status": status])
    }

    // An observable marker after earlier frames, not a guessed sleep for the socket.
    private func drainEvents(_ h: RecoveryHarness) async throws {
        let marker = " event-barrier-\(UUID().uuidString)"
        try emit(h, "content_delta", ["text": marker])
        try await eventually("Earlier stream events must be consumed") { h.liveText.contains(marker) }
    }

    private func complete(_ h: RecoveryHarness) async throws {
        let tick = h.model.completedTurnTick
        h.server.setDetail(text: "Final reply \(tick)", status: "completed")
        try emit(h, "turn_complete", ["stop_reason": "end_turn"])
        try await eventually("Turn completion must be processed") { h.model.completedTurnTick > tick }
    }

    private func image(_ name: String = "pixel.png", alternate: Bool = false) -> Attachment {
        // Two distinct 1x1 PNGs make attachment order observable on the wire.
        let base64 = alternate
            ? "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            : "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
        return Attachment(name: name, mimeType: "image/png", data: Data(base64Encoded: base64)!)
    }

    private func promptTexts(_ h: RecoveryHarness) -> [String] {
        h.server.bodies("acp_prompt").map { body in
            (body["blocks"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
    }

    private func assertBlocks(_ body: [String: Any], text: String, images: [Attachment],
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let blocks = try XCTUnwrap(body["blocks"] as? [[String: Any]], file: file, line: line)
        var expected: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        expected += images.map { ["type": "image", "data": $0.base64, "mime_type": $0.mimeType] }
        XCTAssertEqual(NSArray(array: blocks), NSArray(array: expected), file: file, line: line)
    }

    func testSendWhileRunningQueuesCompleteDraftsFIFOWithoutReplacingLiveTurn() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        let live = h.model.liveTurn
        let pending = h.model.pendingUserTurns
        let firstImage = image()
        let first = try queue(h, "  First message\n", images: [firstImage])
        let second = try queue(h, "Second message")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(h.model.queuedMessages.map(\.text), ["First message", "Second message"])
        XCTAssertEqual(h.model.queuedMessages.map(\.attachments), [[firstImage], []])
        XCTAssertTrue(h.model.queuedMessages.allSatisfy { !$0.isSending && $0.failure == nil })
        XCTAssertEqual(h.model.draft, "")
        XCTAssertTrue(h.model.attachments.isEmpty)
        XCTAssertTrue(h.model.liveTurn === live)
        XCTAssertEqual(h.model.pendingUserTurns, pending)
        h.model.draft = " \n "
        h.model.send()
        XCTAssertEqual(h.model.queuedMessages.count, 2, "Whitespace alone must not become a queued message")
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
    }

    func testCompletedToolCallDeliversCamelCaseTextOnlyFeedbackAndPreservesNewDraft() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "Use the existing helper")
        h.model.draft = "Still editing"
        let staged = image("next.png")
        h.model.addAttachments([staged])
        let start = h.server.requestedRoutes.count
        try boundary(h, type: "tool_call")
        try await eventually("Accepted feedback must remove exactly the queued draft and display its note") {
            h.model.queuedMessages.isEmpty && h.model.feedbackNotes.count == 1
        }
        let body = try XCTUnwrap(h.server.bodies("submit_session_feedback").first)
        XCTAssertEqual(Set(body.keys), Set(["connectionId", "text"]))
        XCTAssertEqual(body["connectionId"] as? String, "connection-42")
        XCTAssertEqual(body["text"] as? String, "Use the existing helper")
        XCTAssertEqual(Array(h.server.requestedRoutes.dropFirst(start).prefix(3)),
                       ["get_feedback_settings", "acp_get_session_snapshot", "submit_session_feedback"])
        XCTAssertEqual(h.server.bodies("acp_get_session_snapshot").last?["connectionId"] as? String, "connection-42")
        XCTAssertEqual(h.model.feedbackNotes.first?.status, "delivered")
        XCTAssertEqual(h.model.feedbackNotes.first?.text, "Use the existing helper")
        XCTAssertEqual(h.model.draft, "Still editing")
        XCTAssertEqual(h.model.attachments, [staged])
        XCTAssertTrue(h.model.isInFlight)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
    }

    func testFailedToolUpdateDeliversExistingBatchInFIFOOrder() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        for text in ["First", "Second", "Third"] { try queue(h, text) }
        try boundary(h, status: "failed")
        try await eventually("A failed tool is also a boundary; the entire existing batch must drain") {
            h.model.queuedMessages.isEmpty && h.model.feedbackNotes.count == 3
        }
        XCTAssertEqual(h.server.bodies("submit_session_feedback").compactMap { $0["text"] as? String },
                       ["First", "Second", "Third"])
        XCTAssertEqual(h.model.feedbackNotes.map(\.text), ["First", "Second", "Third"])
        XCTAssertTrue(h.model.feedbackNotes.allSatisfy { $0.status == "delivered" })
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
    }

    func testNonterminalToolEventsDoNotDeliverOrConsumeTheCompletionID() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "Wait for the tool")
        try boundary(h, status: "pending", type: "tool_call")
        try boundary(h, status: "in_progress")
        try emit(h, "tool_call_update", ["tool_call_id": "tool-1", "content": "partial output"])
        try await drainEvents(h)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        XCTAssertEqual(h.model.queuedMessages.count, 1)
        try boundary(h)
        try await eventually("The later completion of the same ID must still deliver") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
    }

    func testDuplicateCompletionIDsCannotDeliverNewlyQueuedInput() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "First")
        try boundary(h, type: "tool_call")
        try await eventually("First delivery must settle") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        let second = try queue(h, "Second")
        // Distinct envelope sequences, identical tool ID: both event shapes deduplicate.
        try boundary(h)
        try boundary(h, status: "failed", type: "tool_call")
        try await drainEvents(h)
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [second])
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
        try boundary(h, id: "tool-2")
        try await eventually("A new tool completion admits the new draft") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        XCTAssertEqual(h.server.count("submit_session_feedback"), 2)
    }

    func testDraftAddedDuringSuspendedBatchWaitsForAnotherBoundary() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "First")
        try queue(h, "Second")
        let gate = try XCTUnwrap(h.server.enqueueFeedbackResponse(
            RecoveryFixtures.feedback(id: "first", text: "First", status: "delivered"), held: true))
        defer { gate.release() }
        try boundary(h)
        try await eventually("First feedback POST must be held") { gate.hasRequest && h.model.queuedMessages.first?.isSending == true }
        let late = try queue(h, "Typed during POST")
        gate.release()
        try await eventually("Only the drafts present at the boundary may drain") {
            h.model.queuedMessages.map(\.id) == [late] && h.model.feedbackNotes.count == 2 && !h.model.isDeliveringQueuedFeedback
        }
        XCTAssertEqual(h.server.count("submit_session_feedback"), 2)
        try boundary(h, id: "tool-2")
        try await eventually("Next boundary sends the late draft") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        XCTAssertEqual(h.server.bodies("submit_session_feedback").compactMap { $0["text"] as? String },
                       ["First", "Second", "Typed during POST"])
    }

    private func capabilityFallback(snapshot: [String: Any]?, enabled: Bool = true) async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        // Initially advertised support must be rechecked, not cached forever.
        h.server.setConnectionSnapshot(snapshot)
        h.server.setFeedbackEnabled(enabled)
        try queue(h, "Ordinary follow-up")
        try boundary(h)
        try await eventually("Unavailable capability/settings must turn off native delivery") {
            !h.model.usesToolBoundaryDelivery
        }
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        XCTAssertNil(h.model.queuedMessages.first?.failure)
        let gate = h.server.holdNextPrompt()
        defer { gate.release() }
        try await complete(h)
        try await eventually("Completion must submit the retained draft as a normal prompt") { gate.hasRequest }
        XCTAssertEqual(promptTexts(h), ["Ordinary follow-up"])
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        gate.release()
        try await eventually("Accepted ordinary prompt removes the queue entry") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testMissingCapabilityFallsBackToPromptAfterCompletion() async throws {
        try await capabilityFallback(snapshot: [:])
    }

    func testFalseCapabilityFallsBackToPromptAfterCompletion() async throws {
        try await capabilityFallback(snapshot: ["native_steering_available": false])
    }

    func testMissingConnectionSnapshotFallsBackToPromptAfterCompletion() async throws {
        try await capabilityFallback(snapshot: nil)
    }

    func testDisabledFeedbackSettingsOverrideNativeCapability() async throws {
        try await capabilityFallback(snapshot: ["native_steering_available": true], enabled: false)
    }

    func testOldServerMissingSettingsEndpointRetainsOrdinaryDelivery() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h, native: nil)
        h.server.setFeedbackEnabled(false, httpStatus: 404)
        try queue(h, "Old server follow-up")
        try boundary(h)
        try await eventually("The boundary must consult settings") { h.server.count("get_feedback_settings") == 1 }
        let gate = h.server.holdNextPrompt()
        defer { gate.release() }
        try await complete(h)
        try await eventually("Settings lookup failure must not strand the ordinary queue") { gate.hasRequest }
        XCTAssertEqual(promptTexts(h), ["Old server follow-up"])
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        gate.release()
        try await eventually("Ordinary acceptance must clear the draft") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testCapabilityBecomingAvailableAfterAttachIsRecheckedAtBoundary() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h, native: nil)
        XCTAssertFalse(h.model.usesToolBoundaryDelivery)
        h.server.setConnectionSnapshot(["native_steering_available": true])
        try queue(h, "Adapter is ready now")
        try boundary(h)
        try await eventually("A stale early snapshot must not prevent native delivery") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        XCTAssertTrue(h.model.usesToolBoundaryDelivery)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
    }

    func testNoActiveTurnRejectionRetainsDraftForOrdinaryPrompt() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        let id = try queue(h, "Keep this follow-up")
        let feedback = try XCTUnwrap(h.server.enqueueFeedbackResponse(
            ["code": "invalid_input", "message": "no active turn to send feedback to"], httpStatus: 400, held: true))
        defer { feedback.release() }
        try boundary(h)
        try await eventually("Feedback POST must be pending") { feedback.hasRequest }
        feedback.release()
        try await eventually("An explicit rejection retains an unsent, retryable draft") {
            h.model.queuedMessages.first?.isSending == false
        }
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [id])
        XCTAssertNil(h.model.queuedMessages.first?.failure)
        XCTAssertTrue(h.model.feedbackNotes.isEmpty)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        let prompt = h.server.holdNextPrompt()
        defer { prompt.release() }
        try await complete(h)
        try await eventually("Idle delivery owns the explicitly rejected feedback") { prompt.hasRequest }
        XCTAssertEqual(promptTexts(h), ["Keep this follow-up"])
        prompt.release()
        try await eventually("Accepted fallback removes the original entry") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testCompletionDuringFeedbackPOSTWaitsForAcceptanceAndNeverDuplicatesItAsPrompt() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "Accepted steering")
        let tail = try queue(h, "Next ordinary prompt")
        let feedback = try XCTUnwrap(h.server.enqueueFeedbackResponse(
            RecoveryFixtures.feedback(id: "accepted", text: "Accepted steering", status: "delivered"), held: true))
        defer { feedback.release() }
        try boundary(h)
        try await eventually("Steering request must be held") { feedback.hasRequest }
        let prompt = h.server.holdNextPrompt()
        defer { prompt.release() }
        try await complete(h)
        XCTAssertFalse(prompt.hasRequest, "Completion must wait for the feedback outcome")
        XCTAssertEqual(h.model.queuedMessages.count, 2)
        h.model.draft = "Unsubmitted new draft"
        feedback.release()
        try await eventually("Only the unsent tail may become an ordinary prompt") { prompt.hasRequest }
        XCTAssertEqual(promptTexts(h), ["Next ordinary prompt"])
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [tail])
        XCTAssertEqual(h.model.draft, "Unsubmitted new draft")
        prompt.release()
        try await eventually("Tail acceptance drains the queue") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testCompletionDuringFailedFeedbackPOSTRequiresExplicitRetryAndPreservesImages() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        let attachment = image()
        let id = try queue(h, "Inspect this image", images: [attachment])
        let feedback = try XCTUnwrap(h.server.enqueueFeedbackResponse(
            ["code": "task_execution_failed", "message": "Delivery outcome unknown"], httpStatus: 500, held: true))
        defer { feedback.release() }
        try boundary(h)
        try await eventually("Image feedback request must be held") { feedback.hasRequest }
        try assertBlocks(try XCTUnwrap(h.server.bodies("submit_session_feedback").first),
                         text: "Inspect this image", images: [attachment])
        try await complete(h)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        h.model.draft = "Keep editing"
        let staged = image("later.png")
        h.model.addAttachments([staged])
        feedback.release()
        try await eventually("Uncertain delivery must be retained with a retry-required failure") {
            h.model.queuedMessages.first?.failure != nil
        }
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [id])
        XCTAssertEqual(h.model.queuedMessages.first?.attachments, [attachment])
        XCTAssertEqual(h.model.queuedMessages.first?.isSending, false)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
        XCTAssertTrue(h.model.feedbackNotes.isEmpty)
        let prompt = h.server.holdNextPrompt()
        defer { prompt.release() }
        h.model.retryQueuedMessage(id)
        try await eventually("Explicit retry while idle submits the original blocks") { prompt.hasRequest }
        try assertBlocks(try XCTUnwrap(h.server.bodies("acp_prompt").first),
                         text: "Inspect this image", images: [attachment])
        XCTAssertEqual(h.model.draft, "Keep editing")
        XCTAssertEqual(h.model.attachments, [staged])
        prompt.release()
        try await eventually("Accepted retry removes the original entry") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testFeedbackFailureBlocksLaterBoundariesUntilRetry() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        let id = try queue(h, "Retry only when asked")
        try queue(h, "Second")
        h.server.enqueueFeedbackResponse(["message": "Uncertain result"], httpStatus: 500)
        try boundary(h)
        try await eventually("Feedback failure must settle") { h.model.queuedMessages.first?.failure != nil }
        try boundary(h, id: "tool-2")
        try await drainEvents(h)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
        XCTAssertEqual(h.model.queuedMessages.map(\.text), ["Retry only when asked", "Second"])
        h.model.retryQueuedMessage(id)
        XCTAssertNil(h.model.queuedMessages.first?.failure)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1, "Retry during a turn waits for its next boundary")
        try boundary(h, id: "tool-3")
        try await eventually("Explicitly retried head restores FIFO delivery") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        XCTAssertEqual(h.server.bodies("submit_session_feedback").compactMap { $0["text"] as? String },
                       ["Retry only when asked", "Retry only when asked", "Second"])
    }

    private func interruptDuringFeedback(teardown: Bool) async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "Already submitting")
        let tail = try queue(h, "Keep queued")
        let gate = try XCTUnwrap(h.server.enqueueFeedbackResponse(
            RecoveryFixtures.feedback(id: "accepted", text: "Already submitting", status: "delivered"), held: true))
        defer { gate.release() }
        try boundary(h)
        try await eventually("First POST must be in flight") { gate.hasRequest }
        let stream = try XCTUnwrap(h.streams.last)
        if teardown { h.model.teardown() } else { h.model.cancel() }
        XCTAssertTrue(stream.isClosed)
        gate.release()
        try await eventually("Acceptance still owns the exact submitted draft after interruption") {
            h.model.queuedMessages.map(\.id) == [tail]
        }
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        XCTAssertEqual(h.model.queuedMessages.first?.isSending, false)
        if !teardown {
            try await eventually("Manual cancel must reach the backend") { h.server.count("acp_cancel") == 1 }
            XCTAssertFalse(h.model.isInFlight)
        }
    }

    func testManualCancelDuringFeedbackPreventsAutomaticFollowups() async throws {
        try await interruptDuringFeedback(teardown: false)
    }

    func testTeardownDuringFeedbackPreventsAutomaticFollowups() async throws {
        try await interruptDuringFeedback(teardown: true)
    }

    func testAgentMentionAtQueueHeadWaitsForOrdinaryPromptAndPreservesFIFO() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        let mention = "Ask [Reviewer](codeg://agent/reviewer) to inspect this"
        try queue(h, mention)
        let tail = try queue(h, "After delegation")
        try boundary(h)
        try await drainEvents(h)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        XCTAssertEqual(h.model.queuedMessages.count, 2)
        let first = h.server.holdNextPrompt()
        defer { first.release() }
        try await complete(h)
        try await eventually("Mention must use the endpoint that performs agent routing") { first.hasRequest }
        XCTAssertEqual(promptTexts(h), [mention])
        first.release()
        try await eventually("Only the accepted queue head is removed") { h.model.queuedMessages.map(\.id) == [tail] }
        let second = h.server.holdNextPrompt()
        defer { second.release() }
        try await complete(h)
        try await eventually("The following draft gets its own ordinary turn") { second.hasRequest }
        XCTAssertEqual(promptTexts(h), [mention, "After delegation"])
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        second.release()
        try await eventually("Both ordinary turns are accepted") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testImageOnlyFeedbackHasImageBlocksAndNonemptySteeringText() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        let images = [image("first.png"), image("second.png", alternate: true)]
        try queue(h, "", images: images)
        let expectedText = try XCTUnwrap(h.model.queuedMessages.first?.steeringText)
        XCTAssertFalse(expectedText.isEmpty)
        try boundary(h)
        try await eventually("Image-only draft must be accepted as feedback") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        let body = try XCTUnwrap(h.server.bodies("submit_session_feedback").first)
        XCTAssertEqual(Set(body.keys), Set(["connectionId", "text", "blocks"]))
        XCTAssertEqual(body["text"] as? String, expectedText)
        try assertBlocks(body, text: "", images: images)
        XCTAssertEqual(h.model.feedbackNotes.first?.status, "delivered")
    }

    func testRejectedOrdinaryQueuedPromptRetainsImagesAndFreshComposerUntilRetry() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h, native: false)
        let attachment = image()
        let id = try queue(h, "Original draft", images: [attachment])
        h.model.draft = "New draft"
        let staged = image("new.png")
        h.model.addAttachments([staged])
        let rejected = h.server.holdNextPrompt(httpStatus: 400)
        defer { rejected.release() }
        try await complete(h)
        try await eventually("Ordinary queued POST must be held") { rejected.hasRequest }
        rejected.release()
        try await eventually("Rejected ordinary send must retain the queue entry") {
            h.model.queuedMessages.first?.failure != nil && !h.model.isSubmittingPrompt
        }
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [id])
        XCTAssertEqual(h.model.queuedMessages.first?.attachments, [attachment])
        XCTAssertEqual(h.model.draft, "New draft")
        XCTAssertEqual(h.model.attachments, [staged])
        XCTAssertTrue(h.model.pendingUserTurns.isEmpty)
        XCTAssertFalse(h.model.isInFlight)
        let accepted = h.server.holdNextPrompt()
        defer { accepted.release() }
        h.model.retryQueuedMessage(id)
        try await eventually("Retry must resubmit the original message") { accepted.hasRequest }
        for body in h.server.bodies("acp_prompt") {
            try assertBlocks(body, text: "Original draft", images: [attachment])
        }
        XCTAssertEqual(promptTexts(h), ["Original draft", "Original draft"])
        accepted.release()
        try await eventually("Successful retry drains only the queue") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        XCTAssertEqual(h.model.draft, "New draft")
        XCTAssertEqual(h.model.attachments, [staged])
    }

    func testPendingFeedbackResponseDowngradesNativeDeliveryAndStopsBatch() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "Cooperative note")
        let tail = try queue(h, "Must wait")
        h.server.enqueueFeedbackResponse(RecoveryFixtures.feedback(id: "pending", text: "Cooperative note"))
        try boundary(h)
        try await eventually("A pending response must stop the batch and downgrade the UI capability") {
            h.model.queuedMessages.map(\.id) == [tail] && !h.model.usesToolBoundaryDelivery
        }
        XCTAssertEqual(h.model.feedbackNotes.first?.status, "pending")
        try boundary(h, id: "tool-after-downgrade")
        try XCTUnwrap(h.streams.last).emit(.snapshot(try RecoveryFixtures.snapshot(
            text: "After downgrade", nativeSteeringAvailable: true)))
        try await drainEvents(h)
        XCTAssertFalse(h.model.usesToolBoundaryDelivery)
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [tail])
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
        let gate = h.server.holdNextPrompt()
        defer { gate.release() }
        try await complete(h)
        XCTAssertFalse(gate.hasRequest, "Unread feedback must not disappear when the queue advances")
        XCTAssertEqual(h.model.feedbackNotes.first?.id, "pending")
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [tail])
        h.model.dismissFeedbackNote("pending")
        try await eventually("Only the remaining unsent draft gets ordinary delivery") { gate.hasRequest }
        XCTAssertEqual(promptTexts(h), ["Must wait"])
        gate.release()
        try await eventually("Tail acceptance removes its entry") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testNonCodexAgentNeverUsesNativeFeedbackEvenWhenAdvertised() async throws {
        let h = try RecoveryHarness() // Existing fixture callers retain Claude Code.
        defer { finish(h) }
        try await running(h)
        XCTAssertEqual(h.model.agentTypeForUI, .claudeCode)
        XCTAssertFalse(h.model.usesToolBoundaryDelivery)
        try queue(h, "Claude follow-up")
        try boundary(h)
        try await drainEvents(h)
        XCTAssertEqual(h.server.count("get_feedback_settings"), 0)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        let gate = h.server.holdNextPrompt()
        defer { gate.release() }
        try await complete(h)
        try await eventually("Other agents retain ordinary queued delivery") { gate.hasRequest }
        XCTAssertEqual(promptTexts(h), ["Claude follow-up"])
        gate.release()
        try await eventually("Ordinary prompt is accepted") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testOldServerSnapshotDefaultsDoNotClaimNativeSupportOrInventFeedback() throws {
        let live = try RecoveryFixtures.snapshot(text: "Still running")
        let options: SessionSnapshot = try RecoveryFixtures.decode([:])
        XCTAssertFalse(live.nativeSteeringAvailable)
        XCTAssertTrue(live.feedback.isEmpty)
        XCTAssertFalse(options.nativeSteeringAvailable)
        let nullFields: LiveSessionSnapshot = try RecoveryFixtures.decode([
            "native_steering_available": NSNull(), "feedback": NSNull()
        ])
        XCTAssertFalse(nullFields.nativeSteeringAvailable)
        XCTAssertTrue(nullFields.feedback.isEmpty)
    }

    func testSnapshotAndFeedbackEventsDeduplicateAndConsumptionWinsInEitherOrder() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        let first = RecoveryFixtures.feedback(id: "first", text: "From snapshot")
        let second = RecoveryFixtures.feedback(id: "second", text: "Consumed before submission")
        try await running(h, feedback: [first, first])
        XCTAssertEqual(h.model.feedbackNotes.map(\.id), ["first"])
        try emit(h, "feedback_submitted", ["item": first])
        try emit(h, "feedback_consumed", ["ids": ["first", "second"]])
        try emit(h, "feedback_submitted", ["item": second])
        try await eventually("Consumed-before-submitted notes must appear delivered exactly once") {
            h.model.feedbackNotes.count == 2 && h.model.feedbackNotes.allSatisfy { $0.status == "delivered" }
        }
        try XCTUnwrap(h.streams.last).emit(.snapshot(try RecoveryFixtures.snapshot(
            text: "After stale snapshot", nativeSteeringAvailable: true, feedback: [second, first, first])))
        try emit(h, "feedback_submitted", ["item": first])
        try emit(h, "feedback_consumed", ["ids": ["second", "second"]])
        try await drainEvents(h)
        XCTAssertEqual(h.model.feedbackNotes.map(\.id), ["first", "second"])
        XCTAssertEqual(h.model.feedbackNotes.map(\.status), ["delivered", "delivered"])
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
    }

    func testConsumedEventBeforeHTTPResponseCannotRegressNoteToPending() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "A consumed note")
        let pending = RecoveryFixtures.feedback(id: "racing-note", text: "A consumed note")
        let gate = try XCTUnwrap(h.server.enqueueFeedbackResponse(pending, held: true))
        defer { gate.release() }
        try boundary(h)
        try await eventually("HTTP response must be held while events arrive") { gate.hasRequest }
        try emit(h, "feedback_consumed", ["ids": ["racing-note"]])
        try emit(h, "feedback_submitted", ["item": pending])
        try await eventually("Consumption must take precedence before HTTP acceptance") {
            h.model.feedbackNotes.first?.status == "delivered"
        }
        gate.release()
        try await eventually("Late HTTP response must remove the queue entry") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        XCTAssertEqual(h.model.feedbackNotes.map(\.id), ["racing-note"])
        XCTAssertEqual(h.model.feedbackNotes.first?.status, "delivered")
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
    }

    func testCompletionDuringCapabilityLookupFallsBackWithoutSubmittingStaleFeedback() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "Turn ended during lookup")
        let snapshot = h.server.holdNextConnectionSnapshot()
        defer { snapshot.release() }
        try boundary(h)
        try await eventually("Capability lookup must be pending") { snapshot.hasRequest }
        let prompt = h.server.holdNextPrompt()
        defer { prompt.release() }
        try await complete(h)
        XCTAssertFalse(prompt.hasRequest)
        snapshot.release()
        try await eventually("An ended turn must send the retained message normally") { prompt.hasRequest }
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        XCTAssertEqual(promptTexts(h), ["Turn ended during lookup"])
        prompt.release()
        try await eventually("Ordinary acceptance clears the queue") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testCompletedToolsInSnapshotDoNotDeliverUntilLiveBoundary() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        let id = try queue(h, "Wait for a live boundary")
        try XCTUnwrap(h.streams.last).emit(.snapshot(try RecoveryFixtures.snapshot(
            text: "Snapshot of completed tool", nativeSteeringAvailable: true,
            activeToolCalls: [["id": "snapshot-tool", "label": "Read file", "kind": "read", "status": "Completed"]])))
        try await drainEvents(h)
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [id])
        try boundary(h, id: "snapshot-tool")
        try await eventually("A live completion with the same ID can deliver") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
        XCTAssertEqual(h.server.count("submit_session_feedback"), 1)
    }

    func testAgentMentionStopsBatchBeforeLaterSteerableMessages() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "Steer first")
        let mention = "[Reviewer](codeg://agent/reviewer) inspect this"
        let delegated = try queue(h, mention)
        let tail = try queue(h, "Do not overtake delegation")
        try boundary(h)
        try await eventually("The steerable prefix sends before the delegation barrier") {
            h.model.feedbackNotes.count == 1
        }
        XCTAssertEqual(h.model.queuedMessages.map(\.id), [delegated, tail])
        XCTAssertEqual(h.server.bodies("submit_session_feedback").compactMap { $0["text"] as? String }, ["Steer first"])
        let prompt = h.server.holdNextPrompt()
        defer { prompt.release() }
        try await complete(h)
        try await eventually("Delegation must be next in ordinary FIFO delivery") { prompt.hasRequest }
        XCTAssertEqual(promptTexts(h), [mention])
        prompt.release()
        try await eventually("Only the delegation entry is accepted") { h.model.queuedMessages.map(\.id) == [tail] }
    }

    private func confirmedQueuedPromptSurvivesCancellation(teardown: Bool) async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h, native: false)
        try queue(h, "Already accepted")
        let gate = h.server.holdNextPrompt(httpStatus: 500)
        defer { gate.release() }
        try await complete(h)
        try await eventually("Queued prompt must reach the server") { gate.hasRequest }
        let messageID = try XCTUnwrap(h.server.submittedMessageID)
        try emit(h, "user_message", ["message_id": messageID, "blocks": [["type": "text", "text": "Already accepted"]]])
        try await eventually("An authoritative receipt retires the queued prompt before its HTTP acknowledgement") {
            h.model.queuedMessages.isEmpty
        }
        if teardown { h.model.teardown() } else { h.model.cancel() }
        gate.release()
        try await eventually("Cancelled send must finish") { !h.model.isSubmittingPrompt }
        XCTAssertTrue(h.model.queuedMessages.isEmpty)
        XCTAssertEqual(h.server.count("acp_prompt"), 1)
    }

    func testConfirmedQueuedPromptCannotBecomeRetryableAfterCancel() async throws {
        try await confirmedQueuedPromptSurvivesCancellation(teardown: false)
    }

    func testConfirmedQueuedPromptCannotBecomeRetryableAfterTeardown() async throws {
        try await confirmedQueuedPromptSurvivesCancellation(teardown: true)
    }

    func testConnectionGoneRecoveryDrainsQueueAfterPersistedCompletion() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h)
        try queue(h, "Follow up after recovery")
        let gate = h.server.holdNextPrompt()
        defer { gate.release() }
        h.server.setDetail(text: "Completed while disconnected", status: "completed")
        try XCTUnwrap(h.streams.last).emit(.detached(reason: "connection_gone"))
        try await eventually("Recovered completion must release the ordinary queue") { gate.hasRequest }
        XCTAssertEqual(promptTexts(h), ["Follow up after recovery"])
        gate.release()
        try await eventually("Queue drains on acknowledgement") { h.model.queuedMessages.isEmpty && !h.model.isDeliveringQueuedFeedback }
    }

    func testBusyOrdinaryFallbackRetriesWithoutLosingQueuedDraft() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        try await running(h, native: false)
        try queue(h, "Retry after idle settles")
        let gate = h.server.holdNextPrompt(httpStatus: 409)
        defer { gate.release() }
        try await complete(h)
        try await eventually("First prompt must be held") { gate.hasRequest }
        gate.release()
        try await eventually("An explicit busy rejection is retried after refreshing idle state") {
            h.server.count("acp_prompt") == 2 && h.model.queuedMessages.isEmpty
        }
        XCTAssertEqual(promptTexts(h), ["Retry after idle settles", "Retry after idle settles"])
    }

    func testRestoredOrDismissedFeedbackDoesNotReappearOnReplay() async throws {
        let h = try RecoveryHarness(agentType: .codex)
        defer { finish(h) }
        let pending = RecoveryFixtures.feedback(id: "pending", text: "Restore this")
        let delivered = RecoveryFixtures.feedback(id: "delivered", text: "Already used", status: "delivered")
        try await running(h, feedback: [pending, delivered])
        h.model.draft = "Existing draft"
        h.model.restoreFeedbackNote("delivered")
        XCTAssertEqual(h.model.draft, "Existing draft", "Delivered notes cannot be restored as unsent feedback")
        h.model.restoreFeedbackNote("pending")
        XCTAssertEqual(h.model.draft, "Existing draft\n\nRestore this")
        h.model.dismissFeedbackNote("delivered")
        try emit(h, "feedback_submitted", ["item": pending])
        try XCTUnwrap(h.streams.last).emit(.snapshot(try RecoveryFixtures.snapshot(
            text: "Replay", feedback: [pending, delivered])))
        try await drainEvents(h)
        XCTAssertTrue(h.model.feedbackNotes.isEmpty)
        XCTAssertEqual(h.model.draft, "Existing draft\n\nRestore this")
        XCTAssertEqual(h.server.count("submit_session_feedback"), 0)
    }
}
