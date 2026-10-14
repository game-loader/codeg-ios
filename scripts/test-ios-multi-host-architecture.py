#!/usr/bin/env python3
"""Portable architecture probe using current AppModel/registry/navigation code.

Requires Docker and swift:6.2-jammy. SwiftUI imports are replaced with Foundation;
unavailable UI, transport and SessionDetailViewModel dependencies are explicit
doubles. Catalog, history projection and ActivityModel are production code;
the session double also executes the unchanged production loadDraftOptions body.
This does NOT run native XCTest, real first-send/stream
adoption, RecoveryServer barriers, or a SwiftUI typecheck. Those regressions live
in ServerWorkspaceArchitectureRecoveryTests.swift for the native CI handoff.
"""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
IMAGE = "swift:6.2-jammy"
SOURCES = [
    "CodegiOS/App/AppModel.swift",
    "CodegiOS/App/Route.swift",
    "CodegiOS/App/ServerWorkspaceRegistry.swift",
    "CodegiOS/App/SavedServerNavigation.swift",
    "CodegiOS/Persistence/ServerProfile.swift",
    "CodegiOS/Networking/ServerBindingLifetime.swift",
    "CodegiOS/Models/LogicalProject.swift",
    "CodegiOS/Features/Projects/ProjectCatalogModel.swift",
    "CodegiOS/Features/Activity/ActivityModel.swift",
    "CodegiOS/Models/FolderVisibility.swift",
    "CodegiOS/Networking/CodegClient+ProjectIdentity.swift",
    "CodegiOS/Networking/APIError.swift",
]
PARSE = SOURCES + [
    "CodegiOS/App/RootView.swift",
    "CodegiOS/Features/Sessions/SessionListView.swift",
    "CodegiOS/Features/SessionDetail/SessionDetailViewModel.swift",
    "CodegiOS/Features/Projects/MultiServerProjectListView.swift",
    "CodegiOS/Features/Projects/ProjectDetailView.swift",
    "CodegiOS/Features/Worktrees/WorktreeListView.swift",
    "CodegiOSTests/LogicalProjectCatalogTests.swift",
    "CodegiOSTests/LogicalProjectHistoryRoutingTests.swift",
    "CodegiOSTests/ServerWorkspaceIsolationTests.swift",
    "CodegiOSTests/ServerWorkspaceArchitectureRecoveryTests.swift",
]

STUBS = r'''
import Foundation
typealias LocalizedStringKey = String
extension String { init(localized: String) { self = localized } }
enum AgentType: String, Codable, Hashable, Sendable { case claudeCode }
struct DraftAgent { let available = true, enabled = true, sortOrder = 0; let agentType = AgentType.claudeCode }
struct Machine: Hashable { let id: String }
enum SettingsLeaf: Hashable {
    case appearance
    init?(slug: String) { guard slug == "appearance" else { return nil }; self = .appearance }
}
protocol SessionEventStream {}
// Tags are independent of navigation in this architecture-only harness.
// Real HTTP/generation/tag semantics run in ConversationTagIsolationTests.
@MainActor final class ConversationTagsModel {
    init(client: CodegClient) {}
    var isUnsupported = false
    var isRetired = false
    var catalogRevision = 0
    var catalogTagIDs: [Int] = []
    func load() async {}
    func retire() { isRetired = true }
}
@MainActor final class SessionTagFilter {
    init() {}
    func clear() {}
    func acceptCatalog(tagIDs: [Int]) {}
    func retire() {}
}

// Only transport is doubled: bound clients share an initiating fixture. The
// real catalog, ActivityModel and merged projection consume its endpoint data.
@MainActor final class SnapshotFixture {
    var folders: [FolderDetail] = []
    var openFolders: [FolderDetail]?
    var failFolders = false
    var failOpenFolders = false
    var conversations: [ConversationSummary]? = []
    var conversationsError: String?
    var identityReads = 0
    var holdHistory = false
    var historyContinuation: CheckedContinuation<Void, Never>?
    var holdDraftFolders = false
    var draftContinuation: CheckedContinuation<Void, Never>?
}
@MainActor final class CodegClient {
    let baseURL: URL
    let token: String
    let lifetime: ServerBindingLifetime?
    let fixture: SnapshotFixture
    init(baseURL: URL, token: String, lifetime: ServerBindingLifetime? = nil,
         fixture: SnapshotFixture? = nil) {
        self.baseURL = baseURL; self.token = token; self.lifetime = lifetime
        self.fixture = fixture ?? SnapshotFixture()
    }
    func bound(to lifetime: ServerBindingLifetime) -> CodegClient {
        CodegClient(baseURL: baseURL, token: token, lifetime: lifetime, fixture: fixture)
    }
    func checkBinding() throws { try lifetime?.check() }
    func listFolders() async throws -> [FolderDetail] {
        try checkBinding()
        if fixture.holdDraftFolders {
            await withCheckedContinuation { fixture.draftContinuation = $0 }
        }
        if fixture.failFolders { throw APIError.unauthorized }
        return fixture.folders
    }
    func listOpenFolders() async throws -> [FolderDetail] {
        try checkBinding()
        if fixture.failOpenFolders { throw APIError.unauthorized }
        return fixture.openFolders ?? fixture.folders
    }
    func listAgents() async throws -> [DraftAgent] { [DraftAgent()] }
    func postReadJSON<T: Decodable, B: Encodable>(_ endpoint: String, _ body: B) async throws -> T {
        try checkBinding()
        precondition(endpoint == "list_repository_project_identities")
        fixture.identityReads += 1
        let identity = RepositoryProjectIdentity(projectKey: "github:owner/repo", provider: "github",
            host: "github.com", repositoryPath: "owner/repo", remoteName: "origin")
        return fixture.folders.filter { $0.parentId == nil }.map {
            RepositoryProjectIdentityEntry(folderId: $0.id, path: $0.path, status: .resolved, identity: identity)
        } as! T
    }
    func loadServerSnapshot() async -> ServerSnapshotLoad {
        let folders = fixture.failFolders ? nil : fixture.folders
        let open = fixture.failOpenFolders ? nil : (fixture.openFolders ?? fixture.folders)
        if fixture.holdHistory {
            await withCheckedContinuation { fixture.historyContinuation = $0 }
        }
        return ServerSnapshotLoad(folders: folders, openFolders: open,
            conversations: fixture.conversations, conversationsError: fixture.conversationsError,
            message: fixture.conversationsError, cancelled: false)
    }
}
@MainActor final class ServerStore {
    var servers: [ServerProfile]
    var onProfilesChanged: (() -> Void)?
    init(defaults: UserDefaults = .standard) {
        servers = defaults.data(forKey: "codeg.servers.v1")
            .flatMap { try? JSONDecoder().decode([ServerProfile].self, from: $0) } ?? []
    }
    func client(for server: ServerProfile) -> CodegClient? {
        server.baseURL.map { CodegClient(baseURL: $0, token: "fixture") }
    }
    func replace(_ profile: ServerProfile) {
        guard let index = servers.firstIndex(where: { $0.id == profile.id }) else { return }
        servers[index] = profile; onProfilesChanged?()
    }
}
@MainActor final class SessionDetailViewModel {
    let client: CodegClient
    var folder: FolderDetail?
    var projectFolder: FolderDetail? { folder?.kind == .chat ? nil : folder }
    var allFolders: [FolderDetail] = [], availableFolders: [FolderDetail] = []
    var availableAgents: [AgentType] = [.claudeCode]
    var selectedAgent: AgentType?
    var currentBranch: String?
    var didSelectDraftFolder = false, hasStartedFirstSend = false
    struct InsertModel { var agentType: AgentType = .claudeCode }
    var insertModel = InsertModel()
    struct QueueItem { let text: String }
    struct Snapshot { let recoveryText: String }
    var conversationID: Int?
    var newRequest: NewSessionRequest?
    var draft = ""
    var queuedMessages: [QueueItem] = []
    var teardownCount = 0
    init(client: CodegClient, conversationID: Int, eventStreamFactory: (() -> any SessionEventStream)? = nil) {
        self.client = client
        self.conversationID = conversationID
    }
    init(client: CodegClient, newSession: NewSessionRequest, eventStreamFactory: (() -> any SessionEventStream)? = nil) {
        self.client = client
        self.newRequest = newSession
    }
    var retirementSnapshot: Snapshot {
        Snapshot(recoveryText: ([draft] + queuedMessages.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
    func teardown() { teardownCount += 1 }
    func loadDraftOptionsForProbe() async throws {
        try await loadDraftOptions(preselectedFolderID: newRequest?.preselectedFolderID)
    }
    // PRODUCTION_DRAFT_LOADER
}
'''

PROBE = r'''
import Foundation
@main @MainActor struct ArchitectureProbe {
    static func main() async throws {
        var passed = 0
        var failed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            if condition() { passed += 1; print("PASS \(label)") }
            else { failed += 1; print("FAIL \(label)") }
        }
        let suite = "PortableArchitectureProbe.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ServerProfile(name: "A", urlString: "https://a.invalid")
        let b = ServerProfile(name: "B", urlString: "https://b.invalid")
        defaults.set(try JSONEncoder().encode([a, b]), forKey: "codeg.servers.v1")
        let store = ServerStore(defaults: defaults)
        let registry = ServerWorkspaceRegistry(store: store, defaults: defaults)
        let workspace = registry.workspace(for: a.id)!
        let other = registry.workspace(for: b.id)!
        let model = workspace.model
        let session = workspace.session(conversationID: 42)!
        session.draft = "conversation draft"
        model.open(.conversation(42))
        registry.secondaryServerID = b.id
        model.transitionShell(isCompact: true)
        check(model.paths[.chats] == [.conversation(42)], "actual AppModel split entry keeps conversation")
        registry.showSingleServer()
        model.transitionShell(isCompact: false)
        check(registry.secondaryServerID == nil && model.selectedConversationID == 42,
              "actual registry split exit and AppModel regular selection")
        model.transitionShell(isCompact: true)
        model.transitionShell(isCompact: false)
        check(workspace.session(conversationID: 42) === session && session.draft == "conversation draft",
              "width transition retains registry model and draft (session double)")

        let request = NewSessionRequest()
        let draft = workspace.session(request: request)!
        draft.draft = "folderless draft"
        model.selectedConversationID = nil
        model.open(.project(7)); model.open(.project(8)); model.open(.newSession(request))
        model.transitionShell(isCompact: true)
        check(model.selectedTab == .projects && model.paths[.projects] == [.project(7), .project(8), .newSession(request)],
              "actual AppModel compact entry keeps project stack and request token")
        let splitRequest = NewSessionRequest(preselectedFolderID: 8)
        model.open(.newSession(splitRequest))
        model.transitionShell(isCompact: false)
        check(model.pendingNewSession == splitRequest && model.contentPath == [.project(7), .project(8)],
              "actual AppModel maps draft opened in compact to regular detail")
        model.open(.newSession(request))
        model.transitionShell(isCompact: true); model.transitionShell(isCompact: true)
        check(model.paths[.projects] == [.project(7), .project(8), .newSession(request)]
              && workspace.session(request: request) === draft && draft.draft == "folderless draft"
              && draft.newRequest?.preselectedFolderID == nil,
              "idempotent shell callbacks preserve folderless token/model/draft")
        model.paths[.projects] = [.project(7), .project(8)]
        model.transitionShell(isCompact: false)
        check(model.pendingNewSession == nil && model.selectedConversationID == nil
              && model.contentPath == [.project(7), .project(8)], "compact Back clears obsolete detail")

        model.transitionShell(isCompact: true)
        registry.saveNavigation(workspace)
        let restoredRegistry = ServerWorkspaceRegistry(store: ServerStore(defaults: defaults), defaults: defaults)
        let restored = restoredRegistry.workspace(for: a.id)!
        restored.model.transitionShell(isCompact: true)
        check(restored.model.selectedTab == .projects && restored.model.paths[.projects] == [.project(7), .project(8)],
              "actual saved compact navigation survives initial width callback")

        // These are registry-only alias checks with a mutable session double;
        // real first-send/rollback is covered ONLY by the native recovery tests.
        draft.conversationID = 99
        draft.queuedMessages = [.init(text: "queued draft")]
        check(workspace.session(conversationID: 99) === draft && draft.queuedMessages.first?.text == "queued draft",
              "actual registry adopts conversation alias (session double)")
        draft.conversationID = nil
        check(workspace.session(conversationID: 99) !== draft && workspace.session(request: request) === draft,
              "actual registry rejects rolled-back alias (session double)")
        draft.conversationID = 100
        _ = workspace.session(conversationID: 100)
        let recovery = workspace.retire()
        check(draft.teardownCount == 1 && recovery.filter { $0.text.contains("folderless draft") }.count == 1,
              "actual registry retires aliased instance once (session double)")
        check(other.session(conversationID: 42) !== session && !other.isRetired,
              "equal IDs remain isolated across actual workspaces")

        // Fresh actual registry owners consume the real catalog + ActivityModel.
        let merged = ServerWorkspaceRegistry(store: ServerStore(defaults: defaults), defaults: defaults)
        let ownerA = merged.workspace(for: a.id)!, ownerB = merged.workspace(for: b.id)!
        func folder(_ id: Int = 7, _ path: String = "/repo", parent: Int? = nil) -> FolderDetail {
            FolderDetail(id: id, name: "repo", path: path, gitBranch: "topic", defaultAgentType: nil,
                lastOpenedAt: .distantPast, sortOrder: id, color: "", parentId: parent)
        }
        func conversation(_ id: Int = 42, _ folderID: Int = 7) -> ConversationSummary {
            ConversationSummary(id: id, folderId: folderID, title: "Existing", agentType: .claudeCode,
                status: .completed, model: nil, gitBranch: nil, externalId: nil, messageCount: 2,
                createdAt: .distantPast, updatedAt: .distantPast)
        }
        let fa = ownerA.client!.fixture, fb = ownerB.client!.fixture
        fa.folders = [folder(), folder(9, "/a/worktree", parent: 7)]
        fb.folders = [folder(7, "/b/repo"), folder(9, "/b/worktree", parent: 7)]
        fa.conversations = [conversation(), conversation(43, 9)]
        fb.conversations = [conversation(), conversation(43, 9)]
        fa.holdHistory = true
        fb.failFolders = true
        let pending = Task { await ownerA.activity.refresh(client: ownerA.client) }
        for _ in 0..<1000 where fa.historyContinuation == nil { try await Task.sleep(for: .milliseconds(1)) }
        check(fa.historyContinuation != nil, "actual Activity history can be held independently")
        await ownerA.projectCatalog.refresh(); await ownerB.projectCatalog.refresh()
        await ownerB.activity.refresh(client: ownerB.client)
        let project = merged.logicalProjects[0]
        check(merged.logicalProjects.count == 1 && project.setups.count == 2,
              "actual catalog projects publish while another history is pending")
        check(merged.history(for: project).count == 2, "other owner's root and worktree histories remain visible")
        check(!ownerB.activity.hasLoadedFolders && ownerB.activity.hasLoadedConversations,
              "successful histories use independent catalog when initial Activity inventory fails")
        check(!merged.hasLoadedHistory(for: project), "pending contributor cannot produce No Sessions Yet")
        fb.failFolders = false
        let rootA = project.setups[0].reference
        merged.openProject(at: rootA)
        check(merged.selectedServerID == a.id && ownerA.model.contentPath.last == .project(7),
              "folder-only captured navigation does not await histories")
        fa.conversations = nil; fa.conversationsError = "Couldn’t load sessions. Retry to refresh history."
        fa.historyContinuation!.resume(); fa.historyContinuation = nil; fa.holdHistory = false
        await pending.value
        check(ownerA.activity.hasLoaded && !ownerA.activity.hasLoadedConversations && ownerA.activity.conversationsError != nil,
              "actual Activity folder success never fakes an empty successful history")
        check(!merged.hasLoadedHistory(for: project), "failed contributor cannot produce No Sessions Yet")
        fa.conversations = [conversation(), conversation(43, 9)]; fa.conversationsError = nil
        let probes = fa.identityReads
        await ownerA.activity.refresh(client: ownerA.client)
        check(fa.identityReads == probes && ownerA.activity.conversationsError == nil,
              "history retry changes no Git identity reads")
        check(merged.hasLoadedHistory(for: project), "all successful exact locations yield authoritative history")
        let rows = merged.history(for: project)
        check(rows.count == 4 && Set(rows.map(\.id)).count == 4,
              "actual registry projects colliding conversation IDs with distinct owner/path identities")
        let rowA = rows.first { $0.reference.location.serverID == a.id && $0.conversation.id == 42 }!
        let rowB = rows.first { $0.reference.location.serverID == b.id && $0.conversation.id == 42 }!
        let retainedRequest = NewSessionRequest()
        let retainedDraft = ownerA.session(request: retainedRequest)!
        retainedDraft.draft = "unsent folderless"
        ownerA.model.open(.newSession(retainedRequest))
        merged.projectCatalogViewMode = .servers; merged.projectCatalogViewMode = .projects
        merged.selectedServerID = a.id
        merged.openExistingSession(rowB.reference)
        check(merged.selectedServerID == b.id && ownerB.model.selectedConversationID == 42
              && ownerA.model.pendingNewSession == retainedRequest,
              "combined selection dispatches on captured B owner and preserves A pending draft")
        merged.openExistingSession(rowA.reference)
        check(merged.selectedServerID == a.id && ownerA.model.selectedConversationID == 42
              && ownerA.session(request: retainedRequest) === retainedDraft && retainedDraft.draft == "unsent folderless"
              && retainedDraft.newRequest?.preselectedFolderID == nil,
              "combined selection reuses captured A owner and retains its folderless model")
        let worktreeB = LogicalProjectHistory.locations(for: project).first {
            $0.reference.serverID == b.id && $0.folder.id == 9
        }!.reference
        merged.openProject(at: worktreeB)
        check(merged.selectedServerID == b.id && ownerB.model.contentPath.last == .project(9)
              && ownerB.model.pendingNewSession == nil, "Open Folder uses concrete B worktree without a draft")
        merged.openNewSession(at: worktreeB)
        check(ownerB.model.pendingNewSession?.preselectedFolderID == 9,
              "only explicit New Task creates destination-qualified draft")
        let exactDraft = ownerB.session(request: ownerB.model.pendingNewSession!)!
        try await exactDraft.loadDraftOptionsForProbe()
        check(exactDraft.newRequest?.preselectedFolderPath == "/b/worktree" && exactDraft.folder?.path == "/b/worktree",
              "captured New Task preserves exact worktree path through production loader")
        // Execute the actual asynchronous production loader after a valid click.
        for changed in [[folder(9, "/b/moved", parent: 7)], []] {
            merged.openNewSession(at: worktreeB)
            let capturedRequest = ownerB.model.pendingNewSession!
            let capturedDraft = ownerB.session(request: capturedRequest)!
            fb.openFolders = [folder(9, "/b/worktree", parent: 7)]
            fb.holdDraftFolders = true
            let loading = Task { () -> Bool in
                do { try await capturedDraft.loadDraftOptionsForProbe(); return false }
                catch { return true }
            }
            for _ in 0..<1000 where fb.draftContinuation == nil { try await Task.sleep(for: .milliseconds(1)) }
            check(fb.draftContinuation != nil, "actual draft loader waits for asynchronous full inventory")
            fb.folders = changed
            fb.draftContinuation!.resume(); fb.draftContinuation = nil; fb.holdDraftFolders = false
            let rejected = await loading.value
            check(rejected && capturedDraft.folder == nil,
                  "valid New Task click rejects async move/removal despite stale open inventory")
        }
        fb.openFolders = nil
        fb.folders = [folder(7, "/b/repo"), folder(9, "/b/worktree", parent: 7)]
        let legacy = ownerB.session(request: NewSessionRequest(preselectedFolderID: 9))!
        try await legacy.loadDraftOptionsForProbe()
        let chat = ownerB.session(request: NewSessionRequest())!
        try await chat.loadDraftOptionsForProbe()
        check(legacy.folder?.path == "/b/worktree" && chat.folder == nil,
              "actual draft loader preserves legacy ID-only and folderless requests")
        let savedPending = ownerB.model.pendingNewSession
        fa.folders = [folder(7, "/moved")]
        await ownerA.projectCatalog.refresh(force: true)
        merged.openExistingSession(rowA.reference); merged.openProject(at: rootA); merged.openNewSession(at: rootA)
        check(merged.selectedServerID == b.id && ownerB.model.pendingNewSession == savedPending,
              "captured session/Open Folder/New Task reject path reuse")
        for changed in [[folder(7, "/b/moved"), folder(9, "/b/moved-worktree", parent: 7)], []] {
            fb.folders = changed
            await ownerB.activity.refresh(client: ownerB.client)
            merged.selectedServerID = a.id
            ownerB.model.selectedConversationID = nil
            let content = ownerB.model.contentPath, draftRequest = ownerB.model.pendingNewSession
            merged.openExistingSession(rowB.reference)
            merged.openProject(at: rowB.reference.location); merged.openNewSession(at: rowB.reference.location)
            merged.openProject(at: worktreeB); merged.openNewSession(at: worktreeB)
            check(merged.selectedServerID == a.id && ownerB.model.selectedConversationID == nil
                  && ownerB.model.contentPath == content && ownerB.model.pendingNewSession == draftRequest
                  && merged.owner(of: rowB.reference.location) == nil && merged.owner(of: worktreeB) == nil,
                  "Activity-only move/removal fences existing/new/folder/worktree actions with unchanged catalog")
        }
        check(!merged.hasLoadedHistory(for: project), "changed Activity path cannot produce No Sessions Yet")
        fb.folders = [folder(7, "/b/repo"), folder(9, "/b/worktree", parent: 7)]
        fb.failFolders = true; fb.failOpenFolders = true
        await ownerB.projectCatalog.refresh(force: true)
        check(merged.owner(of: worktreeB) == nil,
              "failed catalog reads cannot renew old paths over successful Activity removal")
        fb.failFolders = false; fb.failOpenFolders = false
        await ownerB.projectCatalog.refresh(force: true)
        check(merged.owner(of: rowB.reference.location) === ownerB && merged.owner(of: worktreeB) === ownerB
              && merged.history(for: project).filter { $0.reference.location.serverID == b.id }.count == 2,
              "newer successful catalog recovers locations/history despite older Activity removal")
        fb.failFolders = true; fb.failOpenFolders = true
        let recoveredProbes = fb.identityReads
        await ownerB.activity.refresh(client: ownerB.client)
        check(merged.owner(of: worktreeB) === ownerB && fb.identityReads == recoveredProbes,
              "failed Activity inventory cannot renew older removal or trigger Git probes")
        fb.failFolders = false; fb.failOpenFolders = false
        // An older Activity read may publish after a newer catalog due to history latency.
        fb.folders = []; fb.holdHistory = true
        let delayed = Task { await ownerB.activity.refresh(client: ownerB.client) }
        for _ in 0..<1000 where fb.historyContinuation == nil { try await Task.sleep(for: .milliseconds(1)) }
        check(fb.historyContinuation != nil, "older Activity inventory held behind conversations")
        fb.folders = [folder(7, "/b/repo"), folder(9, "/b/worktree", parent: 7)]
        await ownerB.projectCatalog.refresh(force: true)
        fb.historyContinuation!.resume(); fb.historyContinuation = nil; fb.holdHistory = false
        await delayed.value
        check(ownerB.activity.folders.isEmpty && merged.owner(of: worktreeB) === ownerB
              && merged.history(for: project).filter { $0.reference.location.serverID == b.id }.count == 2,
              "delayed older Activity success never vetoes a newer catalog read")
        fb.folders = [folder(7, "/b/repo"), folder(9, "/b/worktree", parent: 7)]
        fb.conversations = []; await ownerB.activity.refresh(client: ownerB.client)
        ownerB.model.selectedConversationID = nil
        merged.openExistingSession(rowB.reference)
        check(ownerB.model.selectedConversationID == nil, "removed session cannot reopen from captured history")
        var replacementProfile = a; replacementProfile.configurationRevision = UUID()
        merged.store.replace(replacementProfile)
        merged.openExistingSession(rowA.reference); merged.openNewSession(at: rootA); merged.openProject(at: rootA)
        check(ownerA.isRetired && ownerA.projectCatalog.catalogFolders.isEmpty && merged.owner(of: rootA) == nil
              && merged.workspace(for: a.id)!.model.pendingNewSession == nil,
              "retirement/replacement reject captured actions without touching replacement")
        print("\(passed) portable architecture invariants passed; native recovery/UI not executed")
        precondition(failed == 0, "\(failed) portable architecture invariants failed")
    }
}
'''


def check_wiring():
    root = (ROOT / "CodegiOS/App/RootView.swift").read_text()
    chats = root.split("private var chatsRoot: some View {", 1)[1].split("private var projectsTab:", 1)[0]
    sessions = (ROOT / "CodegiOS/Features/Sessions/SessionListView.swift").read_text()
    projects = (ROOT / "CodegiOS/Features/Projects/MultiServerProjectListView.swift").read_text()
    detail = (ROOT / "CodegiOS/Features/SessionDetail/SessionDetailViewModel.swift").read_text()
    registry = (ROOT / "CodegiOS/App/ServerWorkspaceRegistry.swift").read_text()
    assert "onSingleServer: registry.secondaryServerID == nil ? nil : { registry.showSingleServer() }" in chats
    assert "var onSingleServer: (() -> Void)? = nil" in sessions
    assert 'Button("Single Server", action: onSingleServer)' in sessions
    assert 'Button("Single Server") { registry.showSingleServer() }' in projects
    assert root.count("model.transitionShell(isCompact:") == 2 and "model.isCompact =" not in root
    assert "let pendingTexts = pendingUserTurns.filter" in detail
    assert "!queuedTurnIDs.contains($0.id)" in detail
    assert 'String(localized: "Delivery unconfirmed. Check the conversation before retrying.")' in detail
    assert registry.index("let text = session.retirementSnapshot.recoveryText") < registry.index("session.teardown()")
    projects_mode = projects.split('Section("Projects") {', 1)[1].split('ForEach(registry.workspaces)', 1)[0]
    assert "projectRow(project)" in projects_mode and "setupRow(" not in projects_mode
    assert "registry.openExistingSession(session.reference)" in projects
    assert "registry.openNewSession(at: location.reference)" in projects
    assert "registry.openProject(at: location.reference)" in projects
    assert "isCurrent: { registry.owner(of: target.reference) === target.workspace }" in projects
    assert 'Menu("New Task")' in projects and 'Menu("Open Folder")' in projects and 'Menu("Manage Worktrees")' in projects
    print("PASS source wiring: healthy Chats/catalog exit, both layout callbacks, pending-turn snapshot before teardown", flush=True)


def main():
    check_wiring()
    subprocess.run([
        "docker", "run", "--rm", "--network", "none", "-v", f"{ROOT}:/repo:ro", "-w", "/repo", IMAGE,
        "swiftc", "-frontend", "-parse", *PARSE,
    ], check=True)
    print(f"PASS Swift 6.2 syntax parse: {len(PARSE)} current source/test files", flush=True)
    with tempfile.TemporaryDirectory(prefix="codeg-ios-architecture-") as directory:
        path = Path(directory)
        for source in SOURCES:
            (path / Path(source).name).write_text((ROOT / source).read_text().replace("import SwiftUI", "import Foundation"))
        conversation = (ROOT / "CodegiOS/Models/Conversation.swift").read_text()
        folder = conversation.split("/// Lifecycle status of a conversation row.")[0]
        status = conversation.split("enum ConversationStatus:", 1)[1].split("/// Posted (no payload)", 1)[0]
        status = status.split("    var label:", 1)[0] + "    var isLive:" + status.split("    var isLive:", 1)[1]
        summary = conversation.split("struct ConversationSummary:", 1)[1].split("/// Aggregate token/timing stats", 1)[0]
        (path / "Folder.swift").write_text((folder + "enum ConversationStatus:" + status + "struct ConversationSummary:" + summary)
                                          .replace("import SwiftUI", "import Foundation"))
        snapshot = (ROOT / "CodegiOS/Networking/CodegClient.swift").read_text().split("struct ServerSnapshotLoad {", 1)[1]
        (path / "Snapshot.swift").write_text("import Foundation\nstruct ServerSnapshotLoad {" + snapshot.split("extension CodegClient {", 1)[0])
        resolution = (ROOT / "CodegiOS/Models/GitHistory.swift").read_text().split("struct WorktreeResolution:", 1)[1].split("/// A configured git remote", 1)[0]
        (path / "Resolution.swift").write_text("import Foundation\nstruct WorktreeResolution:" + resolution)
        detail = (ROOT / "CodegiOS/Features/SessionDetail/SessionDetailViewModel.swift").read_text()
        loader = "    private func loadDraftOptions(" + detail.split("    private func loadDraftOptions(", 1)[1].split("    // MARK: - Academic", 1)[0]
        (path / "Stubs.swift").write_text(STUBS.replace("    // PRODUCTION_DRAFT_LOADER", loader))
        (path / "Probe.swift").write_text(PROBE)
        files = sorted(p.name for p in path.glob("*.swift"))
        subprocess.run([
            "docker", "run", "--rm", "--network", "none", "-v", f"{path}:/probe", "-w", "/probe", IMAGE,
            "swiftc", "-swift-version", "5", "-parse-as-library", *files, "-o", "probe",
        ], check=True)
        subprocess.run([
            "docker", "run", "--rm", "--network", "none", "-v", f"{path}:/probe", "-w", "/probe", IMAGE, "stdbuf", "-oL", "./probe",
        ], check=True)


if __name__ == "__main__":
    main()
