import Foundation
import XCTest
@testable import Codeg

/// Exercises registry-created models with the existing HTTP/stream recovery
/// fixtures. The client injected into the registry is bound again by the
/// workspace, so editing the actual profile invalidates the sending client.
@MainActor
private final class WorkspaceRecoveryFixture {
    let transport: RecoveryHarness
    let replacement: RecoveryHarness
    let registry: ServerWorkspaceRegistry
    let serverID: UUID
    private let defaults: UserDefaults
    private let suite: String

    init(request: NewSessionRequest? = nil) throws {
        let transport = try RecoveryHarness(newRequest: request)
        let replacement = try RecoveryHarness()
        self.transport = transport
        self.replacement = replacement
        suite = "ServerWorkspaceArchitectureRecoveryTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let profile = ServerProfile(name: "Original", urlString: transport.client.baseURL.absoluteString)
        serverID = profile.id
        defaults.set(try JSONEncoder().encode([profile]), forKey: "codeg.servers.v1")
        registry = ServerWorkspaceRegistry(
            store: ServerStore(defaults: defaults), defaults: defaults,
            clientProvider: { profile in
                profile.baseURL == transport.client.baseURL ? transport.client : replacement.client
            },
            eventStreamFactory: { [unowned transport] in
                let stream = RecoveryEventStream(snapshot: transport.nextSnapshot,
                                                 deliversSnapshot: transport.nextDeliversSnapshot)
                transport.streams.append(stream)
                return stream
            }
        )
        transport.model.teardown()
        if let request { transport.model = workspace.session(request: request)! }
        else { transport.model = workspace.session(conversationID: 42)! }
    }

    var workspace: ServerWorkspace { registry.workspace(for: serverID)! }

    func replaceProfile() {
        var edited = registry.store.servers.first { $0.id == serverID }!
        edited.urlString = replacement.client.baseURL.absoluteString
        XCTAssertTrue(registry.store.update(edited, token: nil))
    }

    func close() {
        transport.close()
        replacement.close()
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(transport.server.unexpectedRequests, [])
        XCTAssertEqual(replacement.server.unexpectedRequests, [])
    }
}

@MainActor
final class ServerWorkspaceArchitectureRecoveryTests: XCTestCase {
    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), message, file: file, line: line)
        if !predicate() { throw URLError(.timedOut) }
    }

    func testActualFolderlessFirstSendAdoptionReopensOriginalDraftAndQueueAndRetiresOnce() async throws {
        let request = NewSessionRequest()
        let f = try WorkspaceRecoveryFixture(request: request)
        defer { f.close() }
        let workspace = f.workspace
        let model = f.transport.model!
        await model.load()
        model.draft = "First real folderless prompt"
        model.send()
        try await eventually("The first send must create, adopt, and submit") {
            model.conversationID == 42 && f.transport.server.count("acp_prompt") == 1 && !model.isSubmittingPrompt
        }
        XCTAssertEqual(f.transport.server.count("create_chat_conversation"), 1)
        XCTAssertEqual(f.transport.server.count("create_conversation"), 0)
        model.draft = "Queued next prompt"
        model.send()
        model.draft = "Unsent next draft"
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Queued next prompt"])
        XCTAssertTrue(workspace.session(conversationID: 42) === model)
        XCTAssertTrue(workspace.session(request: request) === model)
        XCTAssertEqual(workspace.session(conversationID: 42)?.draft, "Unsent next draft")
        XCTAssertEqual(workspace.session(conversationID: 42)?.queuedMessages.map(\.text), ["Queued next prompt"])

        f.replaceProfile()
        XCTAssertEqual(f.registry.recoveredDrafts.count, 1, "The draft token and conversation alias share one retirement")
        let text = try XCTUnwrap(f.registry.recoveredDrafts.first?.text)
        XCTAssertTrue(text.contains("Unsent next draft"))
        XCTAssertTrue(text.contains("Queued next prompt"))
        XCTAssertTrue(workspace.isRetired)
        XCTAssertEqual(f.transport.server.count("acp_prompt"), 1)
        XCTAssertEqual(f.replacement.server.count("acp_prompt"), 0)
    }

    func testFirstSendRollbackInvalidatesCachedConversationAlias() async throws {
        let request = NewSessionRequest()
        let f = try WorkspaceRecoveryFixture(request: request)
        defer { f.close() }
        let workspace = f.workspace
        let model = f.transport.model!
        await model.load()
        let gate = f.transport.server.holdNextPrompt(httpStatus: 500)
        defer { gate.release() }
        model.draft = "Rejected first prompt"
        model.send()
        try await eventually("Creation must adopt an ID before prompt acknowledgement") {
            gate.hasRequest && model.conversationID == 42
        }
        XCTAssertTrue(workspace.session(conversationID: 42) === model)
        gate.release()
        try await eventually("A rejected first send must clear its adopted identity") {
            model.conversationID == nil && model.draft == "Rejected first prompt"
                && f.transport.server.count("delete_conversation") == 1
        }
        let reopened = try XCTUnwrap(workspace.session(conversationID: 42))
        XCTAssertFalse(reopened === model, "The cached alias must not reopen the unlinked draft")
        XCTAssertEqual(reopened.conversationID, 42)
        XCTAssertTrue(workspace.session(request: request) === model)
        XCTAssertEqual(model.draft, "Rejected first prompt")
    }

    func testRetirementRecoversDirectSendHeldBeforePromptSubmission() async throws {
        let f = try WorkspaceRecoveryFixture()
        defer { f.close() }
        let old = f.workspace
        let model = f.transport.model!
        await model.load()
        let gate = f.transport.server.holdNext("acp_find_connection_for_conversation")
        defer { gate.release() }
        model.draft = "Definitely not submitted"
        model.send()
        try await eventually("Send must stop in connection discovery") { gate.hasRequest }
        XCTAssertEqual(f.transport.server.count("acp_prompt"), 0)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.retirementSnapshot.unconfirmedTexts, ["Definitely not submitted"])
        model.draft = "Queued during setup"
        model.send()
        model.draft = "Composer during setup"
        f.replaceProfile()
        XCTAssertTrue(old.isRetired)
        XCTAssertThrowsError(try old.client!.checkBinding()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(f.workspace === old)
        let record = try XCTUnwrap(f.registry.recoveredDrafts.first)
        XCTAssertEqual(record.serverID, f.serverID)
        XCTAssertEqual(record.endpoint, old.client?.baseURL.absoluteString)
        XCTAssertTrue(record.text.contains("Definitely not submitted"))
        XCTAssertTrue(record.text.contains("Queued during setup"))
        XCTAssertTrue(record.text.contains("Composer during setup"))
        XCTAssertTrue(record.text.contains(String(localized: "Delivery unconfirmed. Check the conversation before retrying.")))
        gate.release()
        await Task.yield()
        XCTAssertEqual(f.transport.server.count("acp_prompt"), 0)
        XCTAssertEqual(f.replacement.server.count("acp_prompt"), 0)
        XCTAssertEqual(f.workspace.session(conversationID: 42)?.draft, "")
    }

    func testRetirementRecoversDirectSendWithUnknownPromptAcknowledgementWithoutResubmit() async throws {
        let f = try WorkspaceRecoveryFixture()
        defer { f.close() }
        let old = f.workspace
        let model = f.transport.model!
        await model.load()
        let gate = f.transport.server.holdNextPrompt()
        defer { gate.release() }
        model.draft = "Prompt with unknown acknowledgement"
        model.send()
        try await eventually("POST must reach the fixture while its response is held") { gate.hasRequest }
        XCTAssertEqual(f.transport.server.count("acp_prompt"), 1)
        XCTAssertTrue(model.isSubmittingPrompt)
        XCTAssertEqual(model.retirementSnapshot.unconfirmedTexts, ["Prompt with unknown acknowledgement"])
        f.replaceProfile()
        XCTAssertTrue(old.isRetired)
        XCTAssertThrowsError(try old.client!.checkBinding()) { XCTAssertTrue($0 is CancellationError) }
        let text = try XCTUnwrap(f.registry.recoveredDrafts.first?.text)
        XCTAssertTrue(text.contains("Prompt with unknown acknowledgement"))
        XCTAssertTrue(text.contains(String(localized: "Delivery unconfirmed. Check the conversation before retrying.")))
        gate.release()
        try await eventually("The retired send must finish without a second POST") { !model.isSubmittingPrompt }
        XCTAssertEqual(f.transport.server.count("acp_prompt"), 1)
        XCTAssertEqual(f.replacement.server.count("acp_prompt"), 0)
        XCTAssertEqual(f.workspace.session(conversationID: 42)?.draft, "")
    }

    func testRetirementKeepsSubmittingQueueTextOnceDespiteItsPendingTurnAlias() async throws {
        let f = try WorkspaceRecoveryFixture()
        defer { f.close() }
        let model = f.transport.model!
        f.transport.server.setDetail(text: "Partial running reply", status: "in_progress")
        f.transport.server.setConnected(true)
        f.transport.nextSnapshot = try RecoveryFixtures.snapshot(text: "Running reply")
        await model.load()
        try await eventually("The existing turn must attach before queueing") { model.isInFlight }
        model.draft = "Queued recovery text"
        model.send()
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Queued recovery text"])
        let gate = f.transport.server.holdNextPrompt()
        defer { gate.release() }
        f.transport.server.setDetail(text: "Completed first reply", status: "completed")
        try XCTUnwrap(f.transport.streams.last).emit(try RecoveryFixtures.event(
            "turn_complete", fields: ["stop_reason": "end_turn"]))
        try await eventually("The queue head must submit with its acknowledgement held") { gate.hasRequest }
        XCTAssertTrue(model.queuedMessages.first?.isSending == true)
        XCTAssertTrue(model.pendingUserTurns.contains { $0.id.hasPrefix("queued-") })
        let snapshot = model.retirementSnapshot
        XCTAssertEqual(snapshot.queuedTexts, ["Queued recovery text"])
        XCTAssertFalse(snapshot.unconfirmedTexts.contains("Queued recovery text"))
        f.replaceProfile()
        let text = try XCTUnwrap(f.registry.recoveredDrafts.first?.text)
        XCTAssertEqual(text.components(separatedBy: "Queued recovery text").count - 1, 1)
        gate.release()
        XCTAssertEqual(f.transport.server.count("acp_prompt"), 1)
        XCTAssertEqual(f.replacement.server.count("acp_prompt"), 0)
    }
}
