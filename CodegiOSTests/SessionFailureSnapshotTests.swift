import Foundation
import XCTest
@testable import Codeg

@MainActor
final class SessionFailureSnapshotTests: XCTestCase {
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
        XCTAssertEqual(h.server.count("acp_prompt"), 0, file: file, line: line)
        XCTAssertEqual(h.server.count("acp_connect"), 0, file: file, line: line)
    }

    private func failure(_ title: String, revision: Int = 1, severity: String = "error",
                         category: String = "service", resolved: Bool = false) -> [String: Any] {
        ["id": "turn-incident", "revision": revision, "severity": severity,
         "category": category, "title": title, "resolved": resolved]
    }

    private func snapshot(text: String? = nil, status: String? = nil,
                          connectionID: String = "connection-42", failures: [[String: Any]] = [],
                          lastError: [String: Any]? = nil) throws -> LiveSessionSnapshot {
        var json: [String: Any] = ["connection_id": connectionID, "conversation_id": 42,
                                   "status": status ?? (text == nil ? "connected" : "prompting"),
                                   "event_seq": 12, "session_failures": failures]
        if let text { json["live_message"] = ["content": [["kind": "text", "text": text]]] }
        if let lastError { json["last_error"] = lastError }
        return try RecoveryFixtures.decode(json)
    }

    private func running(_ h: RecoveryHarness, failures: [[String: Any]] = []) async throws {
        h.server.setDetail(text: "Partial reply", status: "in_progress")
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(text: "Partial reply", failures: failures)
        await h.model.load()
        try await eventually("Attach restores an active reply") { h.liveText == "Partial reply" && h.model.isInFlight }
    }

    // A frame after the event under test proves the consumer processed it.
    private func drain(_ stream: RecoveryEventStream, h: RecoveryHarness, token: UInt64,
                       connectionID: String = "connection-42") async throws {
        let envelope: EventEnvelope = try RecoveryFixtures.decode([
            "type": "usage_update", "connection_id": connectionID, "seq": token,
            "used": token, "size": 1000
        ])
        stream.emit(.event(envelope))
        try await eventually("Consumer processes the event barrier") { h.model.sessionStats?.totalTokens == Int(token) }
    }

    func testSnapshotDefaultsAndOptionalErrorDiagnosticsDecode() throws {
        let old: LiveSessionSnapshot = try RecoveryFixtures.decode(["connection_id": "connection-42"])
        XCTAssertNil(old.lastError)
        XCTAssertTrue(old.sessionFailures.isEmpty)
        let restored = try snapshot(lastError: ["message": "Empty reply", "code": "turn_failed_empty",
                                               "details": "Redacted stderr tail"])
        XCTAssertEqual(restored.lastError?.message, "Empty reply")
        XCTAssertEqual(restored.lastError?.code, "turn_failed_empty")
        XCTAssertEqual(restored.lastError?.details, "Redacted stderr tail")
        XCTAssertNil(try snapshot(lastError: ["message": "No diagnostics"]).lastError?.details)
    }

    func testCompletedConversationRecoversMissedPlainErrorWithoutSuccessfulEndTurn() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Previous reply", status: "completed")
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(lastError: ["message": "Agent returned no reply",
                                                "code": "turn_failed_empty",
                                                "details": "Redacted stderr tail"])
        await h.model.load()
        try await eventually("Idle completed snapshot exposes the missed failure and settles") {
            h.model.liveTurn?.errorMessage == "Agent returned no reply" && !h.model.isInFlight
        }
        XCTAssertEqual(h.model.liveTurn?.stopReason, "error")
        XCTAssertEqual(h.model.liveTurn?.isStreaming, false)
        XCTAssertEqual(h.model.errorDetails, "Redacted stderr tail")
        XCTAssertTrue(try XCTUnwrap(h.streams.last).isClosed)
    }

    func testForegroundRecoveryHydratesMissedTypedFailureBeforeFinalizing() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h)
        let live = try XCTUnwrap(h.model.liveTurn)
        let oldStream = try XCTUnwrap(h.streams.last)
        var record = failure("Service rejected the turn", revision: 3)
        record["details"] = "Try again later"
        h.nextSnapshot = try snapshot(failures: [record])
        h.server.setDetail(text: "Final partial reply", status: "pending_review")
        await h.model.resume()
        try await eventually("A missed typed error remains visible after idle recovery") {
            h.model.liveTurn?.errorMessage == "Service rejected the turn\nTry again later" && !h.model.isInFlight
        }
        XCTAssertEqual(live.stopReason, "error")
        XCTAssertFalse(live.isStreaming)
        XCTAssertTrue(oldStream.isClosed)
        XCTAssertTrue(try XCTUnwrap(h.streams.last).isClosed)
    }

    func testRetrySnapshotKeepsSameGenerationReplyStreamingAndProgressClearsBanner() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h, failures: [failure("Retrying service", revision: 2, severity: "warning")])
        try await eventually("Retry warning hydrates") { h.model.notice == "Retrying service" }
        XCTAssertNil(h.model.liveTurn?.errorMessage)
        let live = try XCTUnwrap(h.model.liveTurn)
        h.nextSnapshot = try snapshot(text: "Recovered full reply", failures: [
            failure("Retrying service", revision: 2, severity: "warning")
        ])
        await h.model.resume()
        try await eventually("Same connection restores content and warning") {
            h.liveText == "Recovered full reply" && h.model.notice == "Retrying service"
        }
        XCTAssertTrue(h.model.liveTurn === live)
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("content_delta", fields: ["text": "!"]))
        try await eventually("Progress clears only the retry banner") {
            h.liveText == "Recovered full reply!" && h.model.notice == nil
        }
        XCTAssertTrue(h.model.isInFlight)
        XCTAssertTrue(live.isStreaming)
        XCTAssertNil(live.errorMessage)
    }

    func testResolvedHigherRevisionDropsOlderAndEqualLiveFailuresAfterSameConnectionReattach() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h, failures: [failure("Retrying", revision: 2, severity: "warning")])
        h.nextSnapshot = try snapshot(text: "Recovered", failures: [failure("Settled", revision: 4, resolved: true)])
        await h.model.resume()
        try await eventually("Resolved snapshot clears the retry warning") {
            h.liveText == "Recovered" && h.model.notice == nil
        }
        // A further attach to the same ID must retain the resolved watermark,
        // even when this snapshot predates the resolution.
        h.nextSnapshot = try snapshot(text: "Still recovered", failures: [failure("Stale snapshot", revision: 3)])
        await h.model.resume()
        try await eventually("Same connection attaches again") { h.liveText == "Still recovered" }
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("session_failure", fields: ["record": failure("Old error", revision: 3)]))
        stream.emit(try RecoveryFixtures.event("session_failure", fields: ["record": failure("Equal replay", revision: 4)]))
        try await drain(stream, h: h, token: 41)
        XCTAssertNil(h.model.liveTurn?.errorMessage)
        XCTAssertNil(h.model.notice)
        stream.emit(try RecoveryFixtures.event("session_failure", fields: ["record": failure("New failure", revision: 5)]))
        try await eventually("A genuinely higher revision rearms the failure") {
            h.model.liveTurn?.errorMessage == "New failure"
        }
        XCTAssertTrue(h.model.isInFlight)
    }

    func testSameRevisionResolvedSnapshotClearsTerminalErrorWithoutRearmingOnReplay() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h, failures: [failure("Failed", revision: 2)])
        try await eventually("Initial terminal explanation is hydrated") { h.model.liveTurn?.errorMessage == "Failed" }
        h.nextSnapshot = try snapshot(text: "New prompt in progress", failures: [failure("Failed", revision: 2, resolved: true)])
        await h.model.resume()
        try await eventually("Resolution can advance without a revision increment") {
            h.liveText == "New prompt in progress" && h.model.liveTurn?.errorMessage == nil
        }
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("session_failure", fields: ["record": failure("Failed", revision: 2)]))
        try await drain(stream, h: h, token: 42)
        XCTAssertNil(h.model.liveTurn?.errorMessage)
        XCTAssertTrue(h.model.isInFlight)
    }

    func testIdleReleasePreservesResolvedWatermarkWhenTheSameConnectionReturns() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(failures: [failure("Settled", revision: 6, resolved: true)])
        await h.model.load()
        try await eventually("Idle attach releases its socket") { h.streams.last?.isClosed == true }
        h.nextSnapshot = try snapshot(failures: [failure("Old failure", revision: 5)])
        await h.model.resume()
        try await eventually("The same idle connection is probed again") {
            h.streams.count == 2 && h.streams.last?.isClosed == true
        }
        XCTAssertNil(h.model.liveTurn)
        XCTAssertNil(h.model.notice)
        XCTAssertFalse(h.model.isInFlight)
    }

    func testActualConnectionIdentityChangeResetsFailureRevisions() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        // Discovery varies its server-owned ID while all other requests still
        // use the real RecoveryServer. RecoverySupport remains parent-owned.
        let discovery = FailureSnapshotDiscovery(server: h.server)
        FailureSnapshotURLProtocol.register(discovery, host: h.host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailureSnapshotURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            FailureSnapshotURLProtocol.remove(host: h.host)
        }
        let lifetime = ServerBindingLifetime()
        defer { lifetime.invalidate() }
        let client = CodegClient(baseURL: h.client.baseURL, token: h.client.token,
                                 session: session, readSession: session, probeSession: session,
                                 bindingLifetime: lifetime)
        h.model = SessionDetailViewModel(client: client, conversationID: 42, eventStreamFactory: { [unowned h] in
            let stream = RecoveryEventStream(snapshot: h.nextSnapshot)
            h.streams.append(stream)
            return stream
        })
        try await running(h, failures: [failure("Old connection watermark", revision: 9, resolved: true)])
        let original = try XCTUnwrap(h.streams.last)
        original.emit(try RecoveryFixtures.event("error", fields: ["message": "Old connection error", "code": "turn_failed_empty"]))
        try await drain(original, h: h, token: 40)
        XCTAssertEqual(h.model.liveTurn?.errorMessage, "Old connection error")
        discovery.setConnectionID("connection-99")
        h.nextSnapshot = try snapshot(text: "New connection reply", connectionID: "connection-99",
                                      failures: [failure("New connection failure", revision: 1)])
        await h.model.resume()
        try await eventually("A new connection may restart revisions from one") {
            h.liveText == "New connection reply" && h.model.liveTurn?.errorMessage == "New connection failure"
        }
        XCTAssertTrue(original.isClosed)
        let current = try XCTUnwrap(h.streams.last)
        // An old connection's event cannot supersede the newly scoped failure.
        current.emit(try RecoveryFixtures.event("session_failure", fields: ["record": failure("Wrong connection", revision: 10)]))
        try await drain(current, h: h, token: 45, connectionID: "connection-99")
        XCTAssertEqual(h.model.liveTurn?.errorMessage, "New connection failure")
        XCTAssertTrue(h.model.isInFlight)
    }

    func testDeadSnapshotWithPartialContentStopsSpinnerAndPreservesTypedReason() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Partial reply", status: "in_progress")
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(text: "Final partial", status: "disconnected",
                                      failures: [failure("Access revoked")],
                                      lastError: ["message": "Generic failure", "code": "turn_failed_empty",
                                                  "details": "Diagnostic evidence"])
        await h.model.load()
        try await eventually("A dead connection with content cannot remain streaming") {
            h.model.liveTurn?.errorMessage == "Access revoked" && !h.model.isInFlight
        }
        XCTAssertEqual(h.liveText, "Final partial")
        XCTAssertEqual(h.model.liveTurn?.stopReason, "error")
        XCTAssertEqual(h.model.errorDetails, "Diagnostic evidence")
    }

    func testSnapshotFailureAlreadyPersistedForCurrentPromptDoesNotAddLiveFooter() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        var detail = RecoveryFixtures.detail(text: "Previous reply", status: "completed")
        var turns = detail["turns"] as! [[String: Any]]
        turns.append(["id": "user-2", "role": "user", "timestamp": RecoveryFixtures.date,
                      "blocks": [["type": "text", "text": "A failed prompt"]]])
        turns.append(["id": "failure-2", "role": "system", "timestamp": RecoveryFixtures.date,
                      "blocks": [["type": "turn_error", "message": "Empty reply"]]])
        detail["turns"] = turns
        h.server.setDetailPayload(detail)
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(lastError: ["message": "Empty reply", "code": "turn_failed_empty"])
        await h.model.load()
        try await eventually("Persisted failure settles without an added footer") {
            h.streams.last?.isClosed == true && !h.model.isInFlight
        }
        XCTAssertNil(h.model.liveTurn?.errorMessage)
        XCTAssertEqual(h.model.turns.last?.blocks, [.turnError(message: "Empty reply")])
        XCTAssertNotEqual(h.model.liveTurn?.stopReason, "end_turn")
    }

    func testSnapshotAdvisoryAndLiveErrorDetailsKeepExistingTerminalSemantics() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        try await running(h, failures: [failure("Model fallback", severity: "warning", category: "unknown")])
        try await eventually("Unknown-category warnings remain advisories") { h.model.notice == "Model fallback" }
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("content_delta", fields: ["text": " continues"]))
        try await eventually("Progress keeps the advisory") { h.liveText == "Partial reply continues" }
        XCTAssertEqual(h.model.notice, "Model fallback")
        stream.emit(try RecoveryFixtures.event("error", fields: ["message": "Image was dropped", "code": "image_dropped",
                                                                "details": "Image evidence", "terminal": true]))
        try await drain(stream, h: h, token: 43)
        XCTAssertEqual(h.model.errorDetails, "Image evidence")
        XCTAssertEqual(h.model.notice, "Image was dropped")
        XCTAssertNil(h.model.liveTurn?.errorMessage)
        XCTAssertTrue(h.model.isInFlight)
        stream.emit(try RecoveryFixtures.event("error", fields: ["message": "Empty reply", "code": "turn_failed_empty",
                                                                "details": "Bounded stderr"] ))
        try await drain(stream, h: h, token: 44)
        XCTAssertEqual(h.model.liveTurn?.errorMessage, "Empty reply")
        XCTAssertEqual(h.model.errorDetails, "Bounded stderr")
        XCTAssertTrue(h.model.isInFlight)
        let live = try XCTUnwrap(h.model.liveTurn)
        stream.emit(try RecoveryFixtures.event("turn_complete", fields: ["stop_reason": "end_turn"]))
        try await eventually("Only the terminal event settles the live turn") { !h.model.isInFlight }
        XCTAssertFalse(live.isStreaming)
        XCTAssertEqual(live.errorMessage, "Empty reply")
    }

    private func assertNewPromptRetiresPlainError(code: String?, throughResume: Bool) async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Previous partial", status: "in_progress")
        h.server.setConnected(true)
        var error = ["message": "Previous failure", "details": "Previous diagnostic"]
        if let code { error["code"] = code }
        h.nextSnapshot = try snapshot(text: "Previous partial", lastError: error)
        await h.model.load()
        try await eventually("The old snapshot hydrates its plain error") {
            h.model.errorDetails == "Previous diagnostic"
                && (h.model.liveTurn?.errorMessage == "Previous failure" || h.model.notice == "Previous failure")
        }
        let live = try XCTUnwrap(h.model.liveTurn)
        let fresh = try snapshot(text: "New prompt reply")
        if throughResume {
            h.nextSnapshot = fresh
            await h.model.resume()
        } else {
            try XCTUnwrap(h.streams.last).emit(.snapshot(fresh))
        }
        try await eventually("Authoritative absence retires the previous plain presentation") {
            h.liveText == "New prompt reply" && h.model.errorDetails == nil
        }
        XCTAssertTrue(h.model.liveTurn === live)
        XCTAssertNil(live.errorMessage)
        XCTAssertNil(h.model.notice)
        XCTAssertTrue(h.model.isInFlight)
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("error", fields: ["message": "Current prompt failure", "code": "turn_failed_empty"]))
        try await drain(stream, h: h, token: 53)
        XCTAssertEqual(live.errorMessage, "Current prompt failure")
        stream.emit(.snapshot(fresh))
        try await drain(stream, h: h, token: 54)
        XCTAssertNil(live.errorMessage)
        if code != nil {
            stream.emit(try RecoveryFixtures.event("turn_complete", fields: ["stop_reason": "end_turn"]))
        } else {
            // The missed-completion path must not turn the old session-level
            // error into this prompt's failure through lastStreamError.
            stream.emit(.snapshot(try snapshot()))
        }
        try await eventually("The new prompt settles successfully") { !h.model.isInFlight }
        XCTAssertEqual(live.stopReason, "end_turn")
        XCTAssertNil(live.errorMessage)
        XCTAssertNil(h.model.errorDetails)
        XCTAssertNil(h.model.notice)
    }

    func testSameConnectionNewPromptClearsPlainFailureAndDiagnosticsOnResume() async throws {
        try await assertNewPromptRetiresPlainError(code: "turn_failed_empty", throughResume: true)
    }

    func testSameConnectionNewPromptClearsCodeLessErrorAndLastStreamErrorOnResume() async throws {
        try await assertNewPromptRetiresPlainError(code: nil, throughResume: true)
    }

    func testReattachConsumerClearsObsoletePlainFailureOnFreshSnapshot() async throws {
        try await assertNewPromptRetiresPlainError(code: "turn_failed_empty", throughResume: false)
    }

    func testFreshSnapshotPreservesTypedFailureAndUnrelatedAdvisory() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Partial reply", status: "in_progress")
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(text: "Partial reply",
                                      lastError: ["message": "Old raw failure", "code": "turn_failed_empty",
                                                  "details": "Obsolete raw diagnostic"])
        await h.model.load()
        try await eventually("The plain snapshot error initially owns the explanation") {
            h.model.liveTurn?.errorMessage == "Old raw failure" && h.model.errorDetails != nil
        }
        let live = try XCTUnwrap(h.model.liveTurn)
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("session_failure", fields: ["record": failure("Current typed failure")]))
        stream.emit(try RecoveryFixtures.event("session_notice", fields: [
            "notice": ["severity": "warning", "title": "Keep this advisory"]
        ]))
        try await drain(stream, h: h, token: 51)
        XCTAssertEqual(live.errorMessage, "Current typed failure")
        h.nextSnapshot = try snapshot(text: "Recovered reply")
        await h.model.resume()
        try await eventually("Only the obsolete raw diagnostic is retired") {
            h.liveText == "Recovered reply" && h.model.errorDetails == nil
        }
        XCTAssertTrue(h.model.liveTurn === live)
        XCTAssertEqual(live.errorMessage, "Current typed failure")
        XCTAssertEqual(h.model.notice, "Keep this advisory")
        let current = try XCTUnwrap(h.streams.last)
        current.emit(try RecoveryFixtures.event("session_failure", fields: ["record": failure("Resolved", resolved: true)]))
        current.emit(try RecoveryFixtures.event("error", fields: ["message": "New plain failure", "code": "turn_failed_empty"]))
        try await drain(current, h: h, token: 52)
        XCTAssertEqual(live.errorMessage, "New plain failure")
    }

    func testFreshSnapshotKeepsAdvisoryThatReplacedPlainNoticeWithTheSameText() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Partial reply", status: "in_progress")
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(text: "Partial reply",
                                      lastError: ["message": "Shared explanation", "details": "Old diagnostic"])
        await h.model.load()
        try await eventually("The plain session error owns the initial notice") {
            h.model.notice == "Shared explanation" && h.model.errorDetails == "Old diagnostic"
        }
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("session_notice", fields: [
            "notice": ["severity": "warning", "title": "Shared explanation"]
        ]))
        try await drain(stream, h: h, token: 55)
        h.nextSnapshot = try snapshot(text: "New prompt reply")
        await h.model.resume()
        try await eventually("The new prompt clears the raw diagnostic") {
            h.liveText == "New prompt reply" && h.model.errorDetails == nil
        }
        XCTAssertEqual(h.model.notice, "Shared explanation")
        XCTAssertNil(h.model.liveTurn?.errorMessage)
        let live = try XCTUnwrap(h.model.liveTurn)
        try XCTUnwrap(h.streams.last).emit(.snapshot(try snapshot()))
        try await eventually("The old lastStreamError cannot fail the new turn") { !h.model.isInFlight }
        XCTAssertEqual(live.stopReason, "end_turn")
        XCTAssertNil(live.errorMessage)
        XCTAssertEqual(h.model.notice, "Shared explanation")
    }

    private func assertPendingPromptKeepsIdenticalFailure(status: String,
                                                         connectionAvailableOnLaggingResume: Bool = true) async throws {
        let h = try RecoveryHarness()
        defer {
            h.close()
            XCTAssertEqual(h.server.unexpectedRequests, [])
            XCTAssertEqual(h.server.count("acp_prompt"), 1)
            XCTAssertEqual(h.server.count("acp_connect"), 0)
        }
        var detail = RecoveryFixtures.detail(text: "Unused", status: "completed")
        var turns = detail["turns"] as! [[String: Any]]
        turns.removeLast()
        turns.append(["id": "old-failure", "role": "system", "timestamp": RecoveryFixtures.date,
                      "blocks": [["type": "turn_error", "message": "Empty reply"]]])
        detail["turns"] = turns
        h.server.setDetailPayload(detail)
        await h.model.load()
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(lastError: ["message": "Empty reply", "code": "turn_failed_empty"])
        h.model.draft = "A new prompt"
        h.model.send()
        try await eventually("The new prompt is accepted while its user turn is optimistic") {
            h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt
        }
        XCTAssertEqual(h.model.pendingUserTurns.count, 1)
        let pendingUser = try XCTUnwrap(h.model.pendingUserTurns.first)
        let live = try XCTUnwrap(h.model.liveTurn)
        h.nextDeliversSnapshot = false
        await h.model.resume()
        let stream = try XCTUnwrap(h.streams.last)
        try await eventually("Recovery attaches before receiving its snapshot") { stream.attachCount == 1 }
        turns.append(["id": "new-user", "role": "user", "timestamp": RecoveryFixtures.date,
                      "blocks": [["type": "text", "text": "A new prompt"]]])
        detail["turns"] = turns
        if status == "connected" {
            var lagging = detail
            lagging["turns"] = Array(turns.dropLast()) + [
                ["id": "late-old-note", "role": "system", "timestamp": RecoveryFixtures.date,
                 "blocks": [["type": "text", "text": "Late metadata from the old prompt"]]]
            ]
            h.server.setDetailPayload(lagging)
        } else {
            h.server.setDetailPayload(detail)
        }
        let gate = h.server.holdNextDetail()
        defer { gate.release() }
        stream.emit(.snapshot(try snapshot(status: status,
                                            lastError: ["message": "Empty reply", "code": "turn_failed_empty"])))
        try await eventually("The new identical failure settles while the old transcript remains loaded") {
            !h.model.isInFlight && stream.isClosed
        }
        XCTAssertTrue(h.model.liveTurn === live)
        XCTAssertEqual(live.errorMessage, "Empty reply")
        XCTAssertEqual(h.model.pendingUserTurns.count, 1)
        XCTAssertEqual(h.model.turns.last?.id, "old-failure")
        // A dead connection does not launch refreshAfterTurn; resume explicitly
        // to exercise that branch's subsequent reconciliation as well.
        var recovery: Task<Void, Never>?
        if status == "disconnected" {
            h.nextDeliversSnapshot = true
            h.nextSnapshot = try snapshot(status: status,
                                           lastError: ["message": "Empty reply", "code": "turn_failed_empty"])
            recovery = Task { await h.model.resume() }
        }
        defer { recovery?.cancel() }
        try await eventually("Post-settlement detail is held before the new failure persists") { gate.hasRequest }
        gate.release()
        await recovery?.value
        if status == "connected" {
            try await eventually("History growth for the old prompt cannot deduplicate the new failure") {
                h.model.turns.last?.id == "late-old-note" && h.model.liveTurn?.errorMessage == "Empty reply"
            }
            XCTAssertEqual(h.model.pendingUserTurns.count, 1)
            // Resume once more while only old-prompt metadata has persisted.
            // A connected snapshot must replay without losing the optimistic
            // prompt; a discovery miss must retain its finalized explanation.
            h.nextDeliversSnapshot = true
            h.nextSnapshot = try snapshot(lastError: ["message": "Empty reply", "code": "turn_failed_empty"])
            h.server.setConnected(connectionAvailableOnLaggingResume)
            let streamCount = h.streams.count
            let discoveryCount = h.server.count("acp_find_connection_for_conversation")
            await h.model.resume()
            if connectionAvailableOnLaggingResume {
                try await eventually("The same connected failure replays against still-lagging history") {
                    h.streams.count == streamCount + 1 && h.streams.last?.isClosed == true
                        && h.model.liveTurn?.errorMessage == "Empty reply" && !h.model.isInFlight
                }
                XCTAssertEqual(h.streams.last?.attachCount, 1)
            } else {
                XCTAssertEqual(h.streams.count, streamCount)
            }
            XCTAssertEqual(h.server.count("acp_find_connection_for_conversation"), discoveryCount + 1)
            XCTAssertEqual(h.model.turns.last?.id, "late-old-note")
            XCTAssertEqual(h.model.pendingUserTurns, [pendingUser])
            XCTAssertEqual(h.model.liveTurn?.errorMessage, "Empty reply")
            XCTAssertEqual(h.model.liveTurn?.stopReason, "error")
            XCTAssertEqual(h.model.liveTurn?.isStreaming, false)
            XCTAssertEqual(h.model.liveTurn?.hasContent, false)
            if !connectionAvailableOnLaggingResume {
                h.server.setConnected(true)
                h.nextSnapshot = try snapshot(text: "Recovered active reply")
                await h.model.resume()
                try await eventually("An active snapshot replaces the retained failure after discovery recovers") {
                    h.liveText == "Recovered active reply" && h.model.isInFlight
                        && h.model.liveTurn?.errorMessage == nil
                }
                XCTAssertEqual(h.model.pendingUserTurns, [pendingUser])
                // This variant now owns a streamed reply, whose content must
                // survive a user-only disk read. The error-only persistence
                // controls below belong to the connected/dead variants.
                XCTAssertTrue(h.model.liveTurn?.hasContent == true)
                return
            }
            h.server.setDetailPayload(detail)
            h.nextSnapshot = try snapshot(lastError: ["message": "Empty reply", "code": "turn_failed_empty"])
            await h.model.resume()
        }
        try await eventually("Persisting only the new user must keep its failure visible") {
            h.model.turns.last?.id == "new-user" && h.model.liveTurn?.errorMessage == "Empty reply" && !h.model.isInFlight
        }
        XCTAssertTrue(h.model.pendingUserTurns.isEmpty)
        turns.append(["id": "new-failure", "role": "system", "timestamp": RecoveryFixtures.date,
                      "blocks": [["type": "turn_error", "message": "Empty reply"]]])
        detail["turns"] = turns
        h.server.setDetailPayload(detail)
        h.nextDeliversSnapshot = true
        h.nextSnapshot = try snapshot(status: status,
                                       lastError: ["message": "Empty reply", "code": "turn_failed_empty"])
        await h.model.resume()
        try await eventually("The same current persisted failure owns the final presentation") {
            h.model.turns.last?.id == "new-failure" && h.streams.last?.isClosed == true && !h.model.isInFlight
        }
        XCTAssertNil(h.model.liveTurn?.errorMessage)
        let prompt = try XCTUnwrap(h.model.turns.lastIndex(where: { $0.role == .user }))
        XCTAssertEqual(h.model.turns.dropFirst(prompt + 1).flatMap(\.blocks), [.turnError(message: "Empty reply")])
    }

    func testPendingAcceptedPromptKeepsIdenticalFailureUntilItsOwnErrorPersists() async throws {
        try await assertPendingPromptKeepsIdenticalFailure(status: "connected")
    }

    func testDeadSnapshotDoesNotDeduplicateAgainstPreviousPromptWhileNewPromptIsPending() async throws {
        try await assertPendingPromptKeepsIdenticalFailure(status: "disconnected")
    }

    func testPendingAcceptedPromptPreservesFailureWithoutConnectionAndRecoversActiveSnapshot() async throws {
        try await assertPendingPromptKeepsIdenticalFailure(status: "connected", connectionAvailableOnLaggingResume: false)
    }

    private func assertIdleProbeReleases(_ frame: EventStream.Frame) async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Completed reply", status: "completed")
        h.server.setConnected(true)
        h.nextDeliversSnapshot = false
        h.model.draft = "Unsent draft"
        await h.model.load()
        let stream = try XCTUnwrap(h.streams.last)
        try await eventually("Completed-history discovery attaches without a snapshot") { stream.attachCount == 1 }
        let turns = h.model.turns
        XCTAssertNil(h.model.liveTurn)
        XCTAssertFalse(h.model.isInFlight)
        XCTAssertEqual(h.model.sendState, .idle)
        stream.emit(frame)
        try await eventually("An unconfirmed idle probe releases quietly") { stream.isClosed }
        XCTAssertNil(h.model.liveTurn)
        XCTAssertFalse(h.model.isInFlight)
        XCTAssertEqual(h.model.sendState, .idle)
        XCTAssertEqual(h.model.turns, turns)
        XCTAssertEqual(h.model.draft, "Unsent draft")
        XCTAssertTrue(h.model.pendingUserTurns.isEmpty)
        XCTAssertTrue(h.model.queuedMessages.isEmpty)
        XCTAssertNil(h.model.notice)
        XCTAssertNil(h.model.errorDetails)
        XCTAssertEqual(h.streams.count, 1)
        XCTAssertEqual(h.server.count("get_folder_conversation"), 1)
        // A later explicit resume can probe again; the failed probe left no
        // stream/reconnect owner behind.
        h.nextDeliversSnapshot = true
        await h.model.resume()
        try await eventually("A subsequent empty idle snapshot also releases") {
            h.streams.count == 2 && h.streams.last?.isClosed == true
        }
        XCTAssertNil(h.model.liveTurn)
        XCTAssertEqual(h.model.draft, "Unsent draft")
    }

    func testCompletedHistoryProbeReleasesConnectionGoneBeforeFirstSnapshot() async throws {
        try await assertIdleProbeReleases(.detached(reason: "connection_gone"))
    }

    func testCompletedHistoryProbeReleasesTransientDetachBeforeFirstSnapshot() async throws {
        try await assertIdleProbeReleases(.detached(reason: "server_shutdown"))
    }

    func testCompletedHistoryProbeReleasesTransportCloseBeforeFirstSnapshot() async throws {
        try await assertIdleProbeReleases(.closed(reason: "Transport dropped"))
    }

    func testActiveHistoryStillReconnectsAfterTransportCloseBeforeFirstSnapshot() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Partial reply", status: "in_progress")
        h.server.setConnected(true)
        h.nextDeliversSnapshot = false
        await h.model.load()
        let stream = try XCTUnwrap(h.streams.last)
        try await eventually("An expected live stream attaches") { stream.attachCount == 1 }
        let live = try XCTUnwrap(h.model.liveTurn)
        XCTAssertTrue(h.model.isInFlight)
        h.nextDeliversSnapshot = true
        h.nextSnapshot = try snapshot(text: "Recovered active reply")
        stream.emit(.closed(reason: "Transport dropped"))
        try await eventually("An active row retains pre-snapshot reconnect recovery") {
            h.streams.count == 2 && h.liveText == "Recovered active reply" && h.model.isInFlight
        }
        XCTAssertTrue(h.model.liveTurn === live)
        XCTAssertNil(live.errorMessage)
    }

    func testActiveHistoryStillReconcilesConnectionGoneBeforeFirstSnapshot() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Partial reply", status: "in_progress")
        h.server.setConnected(true)
        h.nextDeliversSnapshot = false
        await h.model.load()
        let stream = try XCTUnwrap(h.streams.last)
        try await eventually("An expected live stream attaches") { stream.attachCount == 1 }
        let live = try XCTUnwrap(h.model.liveTurn)
        stream.emit(.detached(reason: "connection_gone"))
        try await eventually("A missing real active connection still reconciles and reports failure") {
            !h.model.isInFlight && live.errorMessage != nil
        }
        XCTAssertTrue(h.model.liveTurn === live)
        XCTAssertEqual(live.errorMessage, "Lost the connection. Your reply may still be running — reopen the session to check.")
        XCTAssertEqual(h.server.count("get_folder_conversation"), 2)
    }

    func testCompletedHistoryProbeBecomesRecoverableAfterActiveSnapshot() async throws {
        let h = try RecoveryHarness()
        defer { finish(h) }
        h.server.setDetail(text: "Completed reply", status: "completed")
        h.server.setConnected(true)
        h.nextDeliversSnapshot = false
        await h.model.load()
        let stream = try XCTUnwrap(h.streams.last)
        try await eventually("Idle probe attaches") { stream.attachCount == 1 }
        XCTAssertNil(h.model.liveTurn)
        stream.emit(.snapshot(try snapshot(text: "Started elsewhere")))
        try await eventually("The snapshot proves a real turn is active") {
            h.liveText == "Started elsewhere" && h.model.isInFlight
        }
        let live = try XCTUnwrap(h.model.liveTurn)
        h.nextDeliversSnapshot = true
        h.nextSnapshot = try snapshot(text: "Recovered after confirmation")
        stream.emit(.closed(reason: "Transport dropped"))
        try await eventually("The confirmed turn uses ordinary reconnect recovery") {
            h.streams.count == 2 && h.liveText == "Recovered after confirmation" && h.model.isInFlight
        }
        XCTAssertTrue(h.model.liveTurn === live)
        XCTAssertNil(live.errorMessage)
    }

    func testPrePromptHandshakeSeedsWatermarksWithoutApplyingPreviousTurnError() async throws {
        let h = try RecoveryHarness()
        defer {
            h.close()
            XCTAssertEqual(h.server.unexpectedRequests, [])
            XCTAssertEqual(h.server.count("acp_prompt"), 1)
            XCTAssertEqual(h.server.count("acp_connect"), 0)
        }
        await h.model.load()
        h.server.setConnected(true)
        h.nextSnapshot = try snapshot(failures: [failure("Previous typed failure", revision: 6)],
                                      lastError: ["message": "Previous plain failure", "code": "turn_failed_empty",
                                                  "details": "Previous diagnostics"])
        h.model.draft = "A new prompt"
        h.model.send()
        try await eventually("Only the explicitly submitted prompt is accepted") {
            h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt
        }
        let stream = try XCTUnwrap(h.streams.last)
        stream.emit(try RecoveryFixtures.event("session_failure", fields: ["record": failure("Previous typed failure", revision: 6)]))
        try await drain(stream, h: h, token: 46)
        XCTAssertNil(h.model.liveTurn?.errorMessage)
        XCTAssertNil(h.model.errorDetails)
        XCTAssertNil(h.model.notice)
        XCTAssertTrue(h.model.isInFlight)
    }
}

private final class FailureSnapshotDiscovery: @unchecked Sendable {
    let server: RecoveryServer
    private let lock = NSLock()
    private var connectionID = "connection-42"

    init(server: RecoveryServer) { self.server = server }
    func setConnectionID(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        connectionID = id
    }
    func respond(to request: URLRequest, completion: @escaping (Int, Data) -> Void) {
        guard request.url?.lastPathComponent == "acp_find_connection_for_conversation" else {
            server.respond(to: request, completion: completion)
            return
        }
        lock.lock()
        let id = connectionID
        lock.unlock()
        let data = try! JSONSerialization.data(withJSONObject: ["connection_id": id, "event_seq": 12])
        completion(200, data)
    }
}

private final class FailureSnapshotURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var discoveries: [String: FailureSnapshotDiscovery] = [:]

    static func register(_ discovery: FailureSnapshotDiscovery, host: String) {
        lock.lock(); defer { lock.unlock() }
        discoveries[host] = discovery
    }
    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }
        discoveries.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let discovery = Self.discoveries[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let discovery else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        discovery.respond(to: request) { [weak self] status, data in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
