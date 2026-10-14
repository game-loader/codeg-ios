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
