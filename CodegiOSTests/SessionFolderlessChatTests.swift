import Foundation
import XCTest
@testable import Codeg

@MainActor
final class SessionFolderlessChatTests: XCTestCase {
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
        if !predicate() { throw URLError(.timedOut) }
    }

    func testGeneralDraftDoesNotAutoSelectMostRecentProjectOrCreateRows() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        XCTAssertNil(h.model.folder)
        XCTAssertNil(h.model.projectFolder)
        XCTAssertEqual(h.model.availableFolders.map(\.id), [7])
        XCTAssertNotNil(h.model.selectedAgent)
        XCTAssertTrue(h.model.isDraftEditable)
        XCTAssertEqual(h.server.count("create_chat_dir"), 0)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        XCTAssertEqual(h.server.count("create_conversation"), 0)
    }

    func testOrdinaryChatSendsWithoutAnyRegisteredProject() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        h.server.setFolders([])
        await h.model.load()
        XCTAssertTrue(h.model.availableFolders.isEmpty)
        h.model.draft = "Hello without a project"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 1)
        XCTAssertEqual(h.server.count("create_conversation"), 0)
        XCTAssertEqual(h.server.bodies("create_chat_conversation").first?["existingDir"] as? String,
                       RecoveryFixtures.chatPath)
        XCTAssertNil(h.server.bodies("create_chat_conversation").first?["academicPaperId"])
        XCTAssertEqual(h.server.bodies("acp_connect").first?["workingDir"] as? String,
                       RecoveryFixtures.chatPath)
        XCTAssertEqual(h.server.bodies("acp_prompt").first?["folderId"] as? Int, 8)
        XCTAssertEqual(h.server.bodies("acp_prompt").first?["conversationId"] as? Int, 42)
        XCTAssertEqual(h.model.folder?.kind, .chat)
        XCTAssertNil(h.model.projectFolder)
        XCTAssertNil(h.model.displayFolderName)
        XCTAssertFalse(h.model.isDraftEditable)
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testExplicitProjectLaunchKeepsProjectCreationAPI() async throws {
        let h = try RecoveryHarness(newSession: true)
        defer { h.close() }
        await h.model.load()
        XCTAssertEqual(h.model.projectFolder?.id, 7)
        h.model.draft = "Work in this repository"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("create_conversation"), 1)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        XCTAssertEqual(h.server.count("create_chat_dir"), 0)
        XCTAssertEqual(h.server.bodies("acp_connect").first?["workingDir"] as? String, "/tmp/regression")
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testProjectDraftCanSwitchToOrdinaryChatAndBackBeforeSending() async throws {
        let h = try RecoveryHarness(newSession: true)
        defer { h.close() }
        await h.model.load()
        let project = try XCTUnwrap(h.model.folder)
        _ = try await h.model.resolveConnectionForOptions()
        h.model.selectFolder(nil)
        _ = try await h.model.resolveConnectionForOptions()
        XCTAssertNil(h.model.projectFolder)
        h.model.selectFolder(project)
        h.model.draft = "Use the selected project"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("create_conversation"), 1)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        XCTAssertEqual(h.server.bodies("acp_connect").compactMap { $0["workingDir"] as? String },
                       ["/tmp/regression", RecoveryFixtures.chatPath, "/tmp/regression"])
    }

    func testConcurrentOptionsShareScratchAndFirstSendReusesConnection() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        let gate = h.server.holdNext("create_chat_dir")
        defer { gate.release() }
        let first = Task { try await h.model.resolveConnectionForOptions() }
        try await eventually { gate.hasRequest }
        let second = Task { try await h.model.resolveConnectionForOptions() }
        gate.release()
        let firstID = try await first.value
        let secondID = try await second.value
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.count("acp_connect"), 1)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        h.model.draft = "Start with my selected options"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("acp_connect"), 1)
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.bodies("create_chat_conversation").first?["existingDir"] as? String,
                       RecoveryFixtures.chatPath)
    }

    func testFirstSendWaitsForPendingOptionsConnection() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        let gate = h.server.holdNext("acp_connect")
        defer { gate.release() }
        let options = Task { try await h.model.resolveConnectionForOptions() }
        try await eventually { gate.hasRequest }
        h.model.draft = "Send while options are connecting"
        h.model.send()
        try await eventually { h.server.count("create_chat_conversation") == 1 }
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        gate.release()
        _ = try await options.value
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("acp_connect"), 1)
    }

    func testStaleScratchResponseCannotConnectInOldContext() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        let gate = h.server.holdNext("create_chat_dir")
        defer { gate.release() }
        let options = Task { try await h.model.resolveConnectionForOptions() }
        try await eventually { gate.hasRequest }
        h.model.selectFolder(try XCTUnwrap(h.model.availableFolders.first))
        gate.release()
        do { _ = try await options.value; XCTFail("Superseded resolution must be cancelled") }
        catch is CancellationError {}
        XCTAssertEqual(h.server.count("acp_connect"), 0)
        _ = try await h.model.resolveConnectionForOptions()
        XCTAssertEqual(h.server.bodies("acp_connect").last?["workingDir"] as? String, "/tmp/regression")
    }

    func testStaleConnectionIsNotCachedAfterSwitchingToProject() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        let gate = h.server.holdNext("acp_connect")
        defer { gate.release() }
        let options = Task { try await h.model.resolveConnectionForOptions() }
        try await eventually { gate.hasRequest }
        h.model.selectFolder(try XCTUnwrap(h.model.availableFolders.first))
        gate.release()
        do { _ = try await options.value; XCTFail("Superseded connection must be cancelled") }
        catch is CancellationError {}
        h.model.draft = "Project after switching"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("acp_connect"), 2)
        XCTAssertEqual(h.server.bodies("acp_connect").last?["workingDir"] as? String, "/tmp/regression")
    }

    func testRapidProjectAndChatSwitchSharesPendingScratchWithNewResolution() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        let gate = h.server.holdNext("create_chat_dir")
        defer { gate.release() }
        let oldOptions = Task { try await h.model.resolveConnectionForOptions() }
        try await eventually { gate.hasRequest }
        h.model.selectFolder(try XCTUnwrap(h.model.availableFolders.first))
        h.model.selectFolder(nil)
        let newOptions = Task { try await h.model.resolveConnectionForOptions() }
        gate.release()
        do { _ = try await oldOptions.value; XCTFail("Old apply must be cancelled") }
        catch is CancellationError {}
        _ = try await newOptions.value
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.count("acp_connect"), 1)
        XCTAssertEqual(h.server.bodies("acp_connect").first?["workingDir"] as? String,
                       RecoveryFixtures.chatPath)
        XCTAssertNil(h.model.folder)
    }

    func testRejectedFirstPromptRestoresFolderlessDraftAndWaitsForDeletionBeforeRetry() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        let promptGate = h.server.holdNextPrompt(httpStatus: 503)
        let deleteGate = h.server.holdNext("delete_conversation")
        defer { promptGate.release(); deleteGate.release() }
        h.model.draft = "Retry this ordinary chat"
        h.model.send()
        try await eventually { promptGate.hasRequest }
        promptGate.release()
        try await eventually { deleteGate.hasRequest && !h.model.isSubmittingPrompt }
        XCTAssertNil(h.model.conversationID)
        XCTAssertNil(h.model.folder)
        XCTAssertTrue(h.model.isDraftEditable)
        XCTAssertEqual(h.model.draft, "Retry this ordinary chat")
        h.model.send()
        XCTAssertEqual(h.server.count("create_chat_conversation"), 1)
        deleteGate.release()
        try await eventually { h.server.count("acp_prompt") == 2 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("create_chat_conversation"), 2)
        XCTAssertEqual(h.server.count("create_conversation"), 0)
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.count("acp_connect"), 2)
        XCTAssertEqual(h.model.conversationID, 43)
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testFailedChatCreationCanRetryWithoutSelectingProject() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        let gate = h.server.holdNext("create_chat_conversation", httpStatus: 503)
        defer { gate.release() }
        h.model.draft = "Create ordinary chat"
        h.model.send()
        try await eventually { gate.hasRequest }
        gate.release()
        try await eventually { !h.model.isSubmittingPrompt }
        XCTAssertNil(h.model.folder)
        XCTAssertNil(h.model.conversationID)
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("create_chat_conversation"), 2)
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.count("create_conversation"), 0)
    }

    func testReopenedChatUsesHiddenFolderCwdWithoutShowingProjectControls() async throws {
        let h = try RecoveryHarness()
        defer { h.close() }
        var detail = RecoveryFixtures.detail(text: "Ordinary reply")
        var summary = detail["summary"] as! [String: Any]
        summary["folder_id"] = 8
        detail["summary"] = summary
        h.server.setDetailPayload(detail)
        h.server.setFolders([RecoveryFixtures.folder, RecoveryFixtures.chatFolder])
        await h.model.load()
        XCTAssertEqual(h.model.folder?.kind, .chat)
        XCTAssertNil(h.model.projectFolder)
        XCTAssertNil(h.model.currentBranch)
        XCTAssertNil(h.model.displayFolderName)
        let branches = await h.model.loadBranches()
        XCTAssertNil(branches)
        h.model.draft = "Continue ordinary chat"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.bodies("acp_connect").first?["workingDir"] as? String,
                       RecoveryFixtures.chatPath)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testPaperOnlyChatKeepsAcademicBindingAndExcludesHiddenFoldersFromPicker() async throws {
        let request = NewSessionRequest(academic: AcademicDraft(
            paperID: "paper-1", paperTitle: "Research", agent: .codex, chatMode: true))
        let h = try RecoveryHarness(newRequest: request)
        defer { h.close() }
        h.server.setFolders([RecoveryFixtures.folder, RecoveryFixtures.chatFolder])
        await h.model.load()
        XCTAssertEqual(h.model.availableFolders.map(\.id), [7])
        XCTAssertNil(h.model.projectFolder)
        XCTAssertFalse(h.model.isDraftEditable)
        h.model.draft = "Explain this paper"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.bodies("create_chat_conversation").first?["academicPaperId"] as? String, "paper-1")
        XCTAssertEqual(h.server.bodies("create_chat_conversation").first?["agentType"] as? String, "codex")
        XCTAssertEqual(h.model.boundPaper?.id, "paper-1")
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }
}
