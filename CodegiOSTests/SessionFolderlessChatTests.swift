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
        h.server.setConnectionSnapshot(["status": "connected"])
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
        // Let the retry pipeline actually run while deletion is still held.
        // Without the wait it would already request a fresh directory/row.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 1)
        deleteGate.release()
        try await eventually { h.server.count("acp_prompt") == 2 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("create_chat_conversation"), 2)
        XCTAssertEqual(h.server.count("create_conversation"), 0)
        XCTAssertEqual(h.server.count("create_chat_dir"), 2)
        XCTAssertEqual(h.server.count("acp_connect"), 2)
        XCTAssertEqual(h.model.conversationID, 43)
        XCTAssertEqual(h.model.folder?.path, "\(RecoveryFixtures.chatPath)-2")
        XCTAssertEqual(h.server.bodies("create_chat_conversation").compactMap { $0["existingDir"] as? String },
                       [RecoveryFixtures.chatPath, "\(RecoveryFixtures.chatPath)-2"])
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
        XCTAssertEqual(h.server.count("create_chat_dir"), 2)
        XCTAssertEqual(h.server.count("create_conversation"), 0)
        XCTAssertEqual(h.server.bodies("acp_connect").last?["workingDir"] as? String,
                       "\(RecoveryFixtures.chatPath)-2")
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
        let root = try XCTUnwrap(h.model.folder?.path)
        let preview = try await h.client.readFilePreview(rootPath: root, path: "notes.txt")
        XCTAssertEqual(preview.content, "Chat file")
        XCTAssertEqual(h.server.bodies("read_file_preview").first?["rootPath"] as? String, RecoveryFixtures.chatPath)
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

    func testExplicitProjectUsesOpenFolderIfFullFolderLookupFails() async throws {
        let h = try RecoveryHarness(newSession: true)
        defer { h.close() }
        let gate = h.server.holdNext("list_all_folder_details", httpStatus: 503)
        defer { gate.release() }
        let load = Task { await h.model.load() }
        try await eventually { gate.hasRequest }
        h.model.selectAgent(.codex)
        h.model.draft = "Don't send in the wrong directory"
        h.model.send()
        XCTAssertEqual(h.model.phase, .loading)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        XCTAssertEqual(h.server.count("create_conversation"), 0)
        gate.release()
        await load.value
        XCTAssertEqual(h.model.projectFolder?.id, 7)
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("create_conversation"), 1)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
    }

    func testUnavailableExplicitProjectFailsLoadAndCanRetrySafely() async throws {
        let h = try RecoveryHarness(newSession: true)
        defer { h.close() }
        h.server.setFolders([])
        await h.model.load()
        guard case .failed = h.model.phase else { return XCTFail("Missing project must fail load") }
        h.model.draft = "Keep the project binding"
        h.model.send()
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        XCTAssertEqual(h.model.draft, "Keep the project binding")
        h.server.setFolders([RecoveryFixtures.folder])
        await h.model.load()
        XCTAssertEqual(h.model.phase, .loaded)
        XCTAssertEqual(h.model.projectFolder?.id, 7)
    }

    func testDeadDraftOptionsConnectionIsReplacedWithoutChangingScratch() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        _ = try await h.model.resolveConnectionForOptions()
        h.server.setConnectionSnapshot(nil)
        _ = try await h.model.resolveConnectionForOptions()
        XCTAssertEqual(h.server.count("acp_connect"), 2)
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        h.server.setConnectionSnapshot(["status": "connected"])
        _ = try await h.model.resolveConnectionForOptions()
        XCTAssertEqual(h.server.count("acp_connect"), 2)
        h.server.setConnectionSnapshot(["status": "disconnected"])
        _ = try await h.model.resolveConnectionForOptions()
        XCTAssertEqual(h.server.count("acp_connect"), 3)
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testOptionsProbeAndModeApplyUseOrdinaryChatScratchAndFirstSendReusesIt() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        let preferences = UserDefaults.standard.object(forKey: "codeg.selectorPrefs.v1")
        defer { UserDefaults.standard.set(preferences, forKey: "codeg.selectorPrefs.v1") }
        await h.model.load()
        h.model.agentOptions.prepare(agentType: .claudeCode, workingDir: nil)
        try await eventually { h.model.agentOptions.phase == .loaded }
        XCTAssertEqual(h.server.bodies("acp_describe_agent_options").first?["workingDir"] as? String,
                       RecoveryFixtures.chatPath)
        let mode = h.model.agentOptions.selectedModeId == "plan" ? "default" : "plan"
        h.model.agentOptions.selectMode(mode)
        try await eventually {
            h.server.count("acp_set_mode") == 1 && h.model.agentOptions.applying.isEmpty
        }
        XCTAssertEqual(h.model.agentOptions.selectedModeId, mode)
        h.model.draft = "Use the applied mode"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.count("acp_connect"), 1)
        XCTAssertEqual(h.server.count("create_chat_dir"), 1)
        XCTAssertEqual(h.server.bodies("create_chat_conversation").first?["existingDir"] as? String,
                       RecoveryFixtures.chatPath)
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testReopenedChatProbesOptionsInHiddenFolderDirectory() async throws {
        let h = try RecoveryHarness()
        defer { h.close() }
        var detail = RecoveryFixtures.detail(text: "Chat reply")
        var summary = detail["summary"] as! [String: Any]
        summary["folder_id"] = 8; detail["summary"] = summary
        h.server.setDetailPayload(detail)
        h.server.setFolders([RecoveryFixtures.chatFolder])
        await h.model.load()
        // Even a stale/missing UI context must resolve the real prompt cwd.
        h.model.agentOptions.prepare(agentType: .claudeCode, workingDir: nil)
        try await eventually { h.model.agentOptions.phase == .loaded }
        XCTAssertEqual(h.server.bodies("acp_describe_agent_options").first?["workingDir"] as? String,
                       RecoveryFixtures.chatPath)
        XCTAssertEqual(h.server.count("create_chat_dir"), 0)
        XCTAssertNil(h.model.projectFolder)
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testSwitchingProjectDuringOptionsProbeRestartsInCorrectDirectory() async throws {
        let h = try RecoveryHarness(newRequest: NewSessionRequest())
        defer { h.close() }
        await h.model.load()
        let gate = h.server.holdNext("acp_describe_agent_options")
        defer { gate.release() }
        h.model.agentOptions.prepare(agentType: .claudeCode, workingDir: nil)
        try await eventually { gate.hasRequest }
        let project = try XCTUnwrap(h.model.availableFolders.first)
        h.model.selectFolder(project)
        h.model.agentOptions.prepare(agentType: .claudeCode, workingDir: project.path)
        try await eventually { h.model.agentOptions.phase == .loaded }
        XCTAssertEqual(h.server.count("acp_describe_agent_options"), 2)
        XCTAssertEqual(h.server.bodies("acp_describe_agent_options").last?["workingDir"] as? String, project.path)
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testProjectBackedAcademicDraftRetainsFolderAndPaperBinding() async throws {
        let request = NewSessionRequest(preselectedFolderID: 7, academic: AcademicDraft(
            paperID: "paper-2", paperTitle: "Repository paper", agent: .codex, chatMode: false))
        let h = try RecoveryHarness(newRequest: request)
        defer { h.close() }
        await h.model.load()
        XCTAssertEqual(h.model.projectFolder?.id, 7)
        h.model.draft = "Explain the repository"
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.server.bodies("create_conversation").first?["academicPaperId"] as? String, "paper-2")
        XCTAssertEqual(h.server.count("create_chat_conversation"), 0)
        XCTAssertEqual(h.server.count("create_chat_dir"), 0)
        XCTAssertEqual(h.server.bodies("acp_connect").first?["workingDir"] as? String, "/tmp/regression")
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
