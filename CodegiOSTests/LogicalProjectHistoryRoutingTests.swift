import Foundation
import XCTest
@testable import Codeg

/// HTTP fixtures exercise the retained Activity/catalog/registry boundary. The
/// projection tests separately compile the same production core on Linux.
@MainActor
final class LogicalProjectHistoryRoutingTests: XCTestCase {
    private var a: WorktreeTestFixture!
    private var b: WorktreeTestFixture!
    private var registry: ServerWorkspaceRegistry!
    private var ownerA: ServerWorkspace!
    private var ownerB: ServerWorkspace!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        a = try WorktreeTestFixture(); b = try WorktreeTestFixture()
        suite = "LogicalProjectHistoryRouting.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let pa = ServerProfile(name: "A", urlString: a.client.baseURL.absoluteString)
        let pb = ServerProfile(name: "B", urlString: b.client.baseURL.absoluteString)
        defaults.set(try JSONEncoder().encode([pa, pb]), forKey: "codeg.servers.v1")
        registry = ServerWorkspaceRegistry(store: ServerStore(defaults: defaults), defaults: defaults,
                                          clientProvider: { [a, b] in $0.id == pa.id ? a!.client : b!.client })
        ownerA = registry.workspace(for: pa.id); ownerB = registry.workspace(for: pb.id)
        try await catalog(a, owner: ownerA)
        try await catalog(b, owner: ownerB, path: "/b/repo")
    }

    override func tearDown() async throws {
        for owner in registry.workspaces { _ = owner.retire() }
        a.close(); b.close()
        defaults.removePersistentDomain(forName: suite)
        registry = nil; ownerA = nil; ownerB = nil; a = nil; b = nil
    }

    private func catalog(_ fixture: WorktreeTestFixture, owner: ServerWorkspace, path: String = "/repo") async throws {
        let folders = [WorktreeTestServer.folder(path, id: 7), WorktreeTestServer.folder(path + "-linked", id: 9, parent: 7)]
        fixture.server.setFolders(folders)
        fixture.server.enqueue("list_open_folder_details", .init(data: try WorktreeTestReply.json(folders)))
        let identity: [String: Any] = ["project_key": "github:owner/repo", "provider": "github", "host": "github.com",
                                       "repository_path": "owner/repo", "remote_name": "origin"]
        fixture.server.enqueue("list_repository_project_identities", .init(data: try WorktreeTestReply.json([
            ["folder_id": 7, "path": path, "status": "resolved", "identity": identity]
        ])))
        await owner.projectCatalog.refresh(force: true)
    }

    private func conversation(_ id: Int = 42, folder: Int = 7) -> ConversationSummary {
        ConversationSummary(id: id, folderId: folder, title: "Existing", agentType: .claudeCode,
                            status: .completed, model: nil, gitBranch: nil, externalId: nil, messageCount: 2,
                            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
    }

    private func queueHistory(_ fixture: WorktreeTestFixture, rows: [ConversationSummary],
                              gate: WorktreeTestGate? = nil, failure: Bool = false) throws {
        fixture.server.enqueue("list_open_folder_details", .init(data: Data("[]".utf8)))
        fixture.server.enqueue("list_all_conversations", failure
            ? .init(status: 401, data: Data(#"{"message":"Denied"}"#.utf8), gate: gate)
            : .init(data: try CodegJSON.encoder.encode(rows), gate: gate))
    }

    private func loadHistories() async throws {
        try queueHistory(a, rows: [conversation(), conversation(43, folder: 9)])
        try queueHistory(b, rows: [conversation(), conversation(43, folder: 9)])
        await ownerA.activity.refresh(client: ownerA.client)
        await ownerB.activity.refresh(client: ownerB.client)
    }

    func testMergedRowsOpenOriginalOwnerAndLocationMenusCreateOnlyExplicitDrafts() async throws {
        try await loadHistories()
        let project = try XCTUnwrap(registry.logicalProjects.first)
        let rows = registry.history(for: project)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map(\.id)).count, 4)
        let rowA = try XCTUnwrap(rows.first { $0.reference.location.serverID == ownerA.server.id && $0.conversation.id == 42 })
        let rowB = try XCTUnwrap(rows.first { $0.reference.location.serverID == ownerB.server.id && $0.conversation.id == 42 })
        let draftRequest = NewSessionRequest(), draft = try XCTUnwrap(ownerA.session(request: draftRequest))
        draft.draft = "folderless unsent"
        ownerA.model.open(.newSession(draftRequest))
        registry.selectedServerID = ownerA.server.id
        registry.openExistingSession(rowB.reference)
        XCTAssertEqual(registry.selectedServerID, ownerB.server.id)
        XCTAssertEqual(ownerB.model.selectedConversationID, 42)
        XCTAssertEqual(ownerA.model.pendingNewSession, draftRequest)
        registry.openExistingSession(rowA.reference)
        XCTAssertEqual(registry.selectedServerID, ownerA.server.id)
        XCTAssertEqual(ownerA.model.selectedConversationID, 42)
        XCTAssertFalse(ownerA.session(conversationID: 42) === ownerB.session(conversationID: 42))
        XCTAssertNil(ownerA.model.pendingNewSession)
        let worktree = try XCTUnwrap(LogicalProjectHistory.locations(for: project).first {
            $0.reference.serverID == ownerB.server.id && $0.folder.id == 9
        })
        registry.openProject(at: worktree.reference)
        XCTAssertEqual(registry.selectedServerID, ownerB.server.id)
        XCTAssertEqual(ownerB.model.contentPath.last, .project(9))
        XCTAssertNil(ownerB.model.pendingNewSession)
        registry.openNewSession(at: worktree.reference)
        XCTAssertEqual(ownerB.model.pendingNewSession?.preselectedFolderID, 9)
        XCTAssertEqual(ownerB.model.pendingNewSession?.preselectedFolderPath, worktree.folder.path)
        XCTAssertTrue(ownerA.session(request: draftRequest) === draft)
        XCTAssertEqual(draft.draft, "folderless unsent")
        XCTAssertNil(draft.newRequest?.preselectedFolderID)
        XCTAssertTrue(a.server.unexpected.isEmpty && b.server.unexpected.isEmpty)
    }

    func testCapturedHistoryAndOperationsRejectMovedPathRemovedConversationAndReplacement() async throws {
        try await loadHistories()
        let project = try XCTUnwrap(registry.logicalProjects.first)
        let row = try XCTUnwrap(registry.history(for: project).first { $0.reference.location.serverID == ownerA.server.id })
        registry.selectedServerID = ownerB.server.id
        a.server.setFolders([WorktreeTestServer.folder("/activity-moved", id: 7)])
        try queueHistory(a, rows: [conversation()])
        await ownerA.activity.refresh(client: ownerA.client)
        XCTAssertNil(registry.owner(of: row.reference.location), "newer Activity invalidates the unchanged catalog path")
        registry.openExistingSession(row.reference)
        XCTAssertEqual(registry.selectedServerID, ownerB.server.id, "mismatched Activity path cannot dispatch")
        try queueHistory(a, rows: [])
        await ownerA.activity.refresh(client: ownerA.client)
        registry.openExistingSession(row.reference)
        XCTAssertEqual(registry.selectedServerID, ownerB.server.id, "deleted history cannot dispatch")
        try await catalog(a, owner: ownerA, path: "/moved")
        registry.openExistingSession(row.reference)
        registry.openProject(at: row.reference.location)
        registry.openNewSession(at: row.reference.location)
        XCTAssertEqual(registry.selectedServerID, ownerB.server.id)
        XCTAssertNil(ownerA.model.pendingNewSession)
        XCTAssertTrue(ownerA.model.contentPath.isEmpty)
        let current = try XCTUnwrap(registry.logicalProjects.first?.setups.first { $0.serverID == ownerA.server.id }?.reference)
        var profile = ownerA.server
        profile.urlString = "https://replacement.invalid"
        XCTAssertTrue(registry.store.update(profile, token: nil))
        let replacement = try XCTUnwrap(registry.workspace(for: profile.id))
        registry.openProject(at: current)
        registry.openNewSession(at: current)
        registry.openExistingSession(row.reference)
        XCTAssertTrue(ownerA.isRetired)
        XCTAssertNil(registry.owner(of: current))
        XCTAssertTrue(replacement.model.contentPath.isEmpty)
        XCTAssertNil(replacement.model.pendingNewSession)
        XCTAssertEqual(registry.selectedServerID, ownerB.server.id)
    }

    func testActivityOnlyMoveAndRemovalRejectEveryCapturedRootAndWorktreeAction() async throws {
        try await loadHistories()
        let project = try XCTUnwrap(registry.logicalProjects.first)
        let captured = registry.history(for: project).filter { $0.reference.location.serverID == ownerA.server.id }
        XCTAssertEqual(captured.count, 2)
        let sheets = captured.map { row in
            WorktreeListViewModel(client: ownerA.client!, folder: row.folder,
                isCurrent: { [registry = registry!, owner = ownerA!] in registry.owner(of: row.reference.location) === owner })
        }
        for sheet in sheets {
            await sheet.load()
            XCTAssertTrue(sheet.allowsPresentation)
            XCTAssertTrue(sheet.canCreate)
        }
        let probes = a.server.count("list_repository_project_identities")
        for folders in [[WorktreeTestServer.folder("/moved", id: 7),
                         WorktreeTestServer.folder("/moved-linked", id: 9, parent: 7)], []] {
            a.server.setFolders(folders)
            try queueHistory(a, rows: [conversation(), conversation(43, folder: 9)])
            await ownerA.activity.refresh(client: ownerA.client)
            registry.selectedServerID = ownerB.server.id
            for row in captured {
                XCTAssertNil(registry.owner(of: row.reference.location), "also fences the worktree sheet's isCurrent callback")
                registry.openExistingSession(row.reference)
                registry.openProject(at: row.reference.location)
                registry.openNewSession(at: row.reference.location)
            }
            XCTAssertEqual(registry.selectedServerID, ownerB.server.id)
            XCTAssertTrue(ownerA.model.contentPath.isEmpty)
            XCTAssertNil(ownerA.model.pendingNewSession)
            for sheet in sheets {
                XCTAssertFalse(sheet.allowsPresentation)
                XCTAssertFalse(sheet.canCreate)
                await sheet.create(branchName: "blocked", worktreePath: "/blocked")
            }
            XCTAssertEqual(registry.history(for: project).count, 2, "only the healthy owner contributes")
            XCTAssertEqual(ownerA.projectCatalog.folder(id: 7)?.path, "/repo", "catalog remains unchanged")
        }
        XCTAssertEqual(a.server.count("list_repository_project_identities"), probes)
        XCTAssertEqual(a.server.count("git_add_worktree"), 0)
        XCTAssertTrue(a.server.unexpected.isEmpty && b.server.unexpected.isEmpty)
    }

    func testFreshCatalogRecoversFromOlderActivityMoveAndRemoval() async throws {
        try await loadHistories()
        for folders in [[WorktreeTestServer.folder("/activity-moved", id: 7)], []] {
            a.server.setFolders(folders)
            try queueHistory(a, rows: [conversation(), conversation(43, folder: 9)])
            await ownerA.activity.refresh(client: ownerA.client)
            try await catalog(a, owner: ownerA)
            let project = try XCTUnwrap(registry.logicalProjects.first)
            let rows = registry.history(for: project).filter { $0.reference.location.serverID == ownerA.server.id }
            XCTAssertEqual(rows.count, 2, "older Activity must not veto a fresh full catalog")
            XCTAssertTrue(registry.hasLoadedHistory(for: project))
            for location in LogicalProjectHistory.locations(for: project).filter({ $0.reference.serverID == ownerA.server.id }) {
                XCTAssertTrue(registry.owner(of: location.reference) === ownerA)
                registry.openProject(at: location.reference)
                registry.openNewSession(at: location.reference)
                XCTAssertEqual(ownerA.model.pendingNewSession?.preselectedFolderPath, location.folder.path)
            }
            registry.selectedServerID = ownerB.server.id
            registry.openExistingSession(try XCTUnwrap(rows.first).reference)
            XCTAssertEqual(registry.selectedServerID, ownerA.server.id)
        }
        XCTAssertTrue(a.server.unexpected.isEmpty && b.server.unexpected.isEmpty)
    }

    func testDelayedOlderActivityPublicationCannotVetoNewerCatalogRead() async throws {
        let gate = WorktreeTestGate()
        a.server.setFolders([])
        try queueHistory(a, rows: [conversation(), conversation(43, folder: 9)], gate: gate)
        let pending = Task { await self.ownerA.activity.refresh(client: self.ownerA.client) }
        defer { gate.release() }
        for _ in 0..<1000 where !gate.hasRequest { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.hasRequest)
        // Ensure the older full inventory has completed before restoring it.
        for _ in 0..<1000 where a.server.count("list_all_folder_details") < 2 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(a.server.count("list_all_folder_details"), 2)
        try await catalog(a, owner: ownerA)
        gate.release(); await pending.value
        XCTAssertTrue(ownerA.activity.hasLoadedFolders)
        XCTAssertTrue(ownerA.activity.folders.isEmpty)
        let project = try XCTUnwrap(registry.logicalProjects.first)
        XCTAssertEqual(registry.history(for: project).count, 2)
        XCTAssertTrue(registry.owner(of: project.setups[0].reference) === ownerA)
        XCTAssertTrue(a.server.unexpected.isEmpty)
    }

    func testValidNewTaskClickThenAsyncMoveOrRemovalRejectsDraftAndConnection() async throws {
        let reference = try XCTUnwrap(registry.logicalProjects.first?.setups.first?.reference)
        for folders in [[WorktreeTestServer.folder("/moved", id: 7)], []] {
            registry.openNewSession(at: reference)
            let request = try XCTUnwrap(ownerA.model.pendingNewSession)
            XCTAssertEqual(request.preselectedFolderPath, "/repo")
            let draft = try XCTUnwrap(ownerA.session(request: request))
            let gate = WorktreeTestGate()
            // A stale open result cannot resurrect a successful full removal.
            a.server.enqueue("list_open_folder_details", .init(data: try WorktreeTestReply.json([WorktreeTestServer.folder("/repo", id: 7)])))
            a.server.enqueue("list_all_folder_details", .init(data: try WorktreeTestReply.json(folders), gate: gate))
            a.server.enqueue("acp_list_agents", .init(data: Data("[]".utf8)))
            let pending = Task { await draft.load() }
            defer { gate.release() }
            for _ in 0..<1000 where !gate.hasRequest { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(gate.hasRequest)
            XCTAssertEqual(draft.phase, .loading)
            gate.release(); await pending.value
            if case .failed = draft.phase {} else { XCTFail("captured path was accepted after it moved or disappeared") }
            XCTAssertNil(draft.folder)
            draft.draft = "keep this unsent"
            draft.send()
            do { _ = try await draft.resolveConnectionForOptions(); XCTFail("failed draft accepted a connection") } catch {}
            XCTAssertEqual(draft.draft, "keep this unsent")
        }
        for route in ["acp_connect", "create_conversation", "create_chat_dir", "acp_prompt"] {
            XCTAssertEqual(a.server.count(route), 0)
        }
        XCTAssertTrue(a.server.unexpected.isEmpty)
    }

    func testExactCapturedWorktreeDraftAndLegacyIDOnlyAndFolderlessRequestsLoad() async throws {
        let project = try XCTUnwrap(registry.logicalProjects.first)
        let location = try XCTUnwrap(LogicalProjectHistory.locations(for: project).first {
            $0.reference.serverID == ownerA.server.id && $0.folder.id == 9
        })
        registry.openNewSession(at: location.reference)
        let captured = try XCTUnwrap(ownerA.model.pendingNewSession)
        let cases: [(NewSessionRequest, [String: Any], String?)] = [
            (captured, WorktreeTestServer.folder(location.folder.path, id: 9, parent: 7), location.folder.path),
            (NewSessionRequest(preselectedFolderID: 7), WorktreeTestServer.folder("/legacy-moved", id: 7), "/legacy-moved"),
            (NewSessionRequest(), WorktreeTestServer.folder("/available", id: 7), nil)
        ]
        for (request, folder, expected) in cases {
            a.server.setFolders([folder])
            a.server.enqueue("list_open_folder_details", .init(data: try WorktreeTestReply.json([folder])))
            a.server.enqueue("acp_list_agents", .init(data: Data("[]".utf8)))
            let draft = try XCTUnwrap(ownerA.session(request: request))
            await draft.load()
            XCTAssertEqual(draft.phase, .loaded)
            XCTAssertEqual(draft.folder?.path, expected)
            XCTAssertEqual(draft.newRequest, request)
            XCTAssertTrue(ownerA.session(request: request) === draft)
        }
        XCTAssertEqual(a.server.count("acp_connect"), 0)
        XCTAssertEqual(a.server.count("create_conversation"), 0)
        XCTAssertTrue(a.server.unexpected.isEmpty)
    }

    func testConversationSuccessWithFailedActivityInventoryUsesIndependentCatalog() async throws {
        a.server.enqueue("list_all_folder_details", .failure(status: 401, message: "Denied"))
        try queueHistory(a, rows: [conversation(), conversation(43, folder: 9)])
        await ownerA.activity.refresh(client: ownerA.client)
        XCTAssertFalse(ownerA.activity.hasLoadedFolders)
        XCTAssertTrue(ownerA.activity.hasLoadedConversations)
        let rows = registry.history(for: registry.logicalProjects[0])
        XCTAssertEqual(rows.count, 2)
        registry.selectedServerID = ownerB.server.id
        registry.openExistingSession(rows[0].reference)
        XCTAssertEqual(registry.selectedServerID, ownerA.server.id)
        XCTAssertTrue(a.server.unexpected.isEmpty)
    }

    func testPendingAndFailedHistoryKeepsCatalogOtherOwnerAndIndependentRetry() async throws {
        let gate = WorktreeTestGate()
        try queueHistory(a, rows: [], gate: gate, failure: true)
        let pending = Task { await self.ownerA.activity.refresh(client: self.ownerA.client) }
        defer { gate.release() }
        for _ in 0..<1000 where !gate.hasRequest { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.hasRequest)
        try queueHistory(b, rows: [conversation()])
        await ownerB.activity.refresh(client: ownerB.client)
        let project = try XCTUnwrap(registry.logicalProjects.first)
        XCTAssertEqual(project.setups.count, 2)
        XCTAssertEqual(registry.history(for: project).count, 1)
        XCTAssertFalse(ownerA.activity.hasLoadedConversations)
        XCTAssertFalse(registry.hasLoadedHistory(for: project))
        registry.openProject(at: project.setups[0].reference)
        XCTAssertEqual(registry.selectedServerID, ownerA.server.id, "folder navigation does not wait for sessions")
        gate.release(); await pending.value
        XCTAssertTrue(ownerA.activity.hasLoaded, "folder success is accepted")
        XCTAssertFalse(ownerA.activity.hasLoadedConversations, "folder success cannot imply empty history")
        XCTAssertNotNil(ownerA.activity.conversationsError)
        XCTAssertFalse(registry.hasLoadedHistory(for: project))
        XCTAssertEqual(registry.logicalProjects.first?.setups.count, 2)
        XCTAssertEqual(registry.history(for: project).count, 1)
        let probes = a.server.count("list_repository_project_identities")
        try queueHistory(a, rows: [conversation()])
        await ownerA.activity.refresh(client: ownerA.client)
        XCTAssertNil(ownerA.activity.conversationsError)
        XCTAssertEqual(registry.history(for: project).count, 2)
        XCTAssertTrue(registry.hasLoadedHistory(for: project))
        XCTAssertEqual(a.server.count("list_repository_project_identities"), probes, "history retry never probes Git")
        XCTAssertTrue(a.server.unexpected.isEmpty && b.server.unexpected.isEmpty)
    }

    func testCatalogModeAndCombinedSelectionRetainProjectGitTerminalAndDrafts() async throws {
        try await loadHistories()
        let runtime = try XCTUnwrap(ProjectWorkspaceCache.shared.runtime(client: ownerA.client!, folder: a.folder))
        let terminal = runtime.terminal, git = runtime.git, emulator = terminal.view
        runtime.tab = .terminal
        let session = try XCTUnwrap(ownerA.session(conversationID: 42))
        session.draft = "unsent conversation"
        let row = try XCTUnwrap(registry.history(for: registry.logicalProjects[0]).first {
            $0.reference.location.serverID == ownerA.server.id && $0.conversation.id == 42
        })
        registry.projectCatalogViewMode = .servers
        registry.projectCatalogViewMode = .projects
        registry.selectedServerID = ownerB.server.id
        registry.openExistingSession(row.reference)
        let retained = try XCTUnwrap(ProjectWorkspaceCache.shared.runtime(client: ownerA.client!, folder: a.folder))
        XCTAssertTrue(retained === runtime && retained.git === git && retained.terminal === terminal)
        XCTAssertTrue(retained.terminal.view === emulator)
        XCTAssertEqual(retained.tab, .terminal)
        XCTAssertTrue(ownerA.session(conversationID: 42) === session)
        XCTAssertEqual(session.draft, "unsent conversation")
    }
}
