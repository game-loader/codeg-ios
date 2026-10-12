import Foundation
import XCTest
@testable import Codeg

@MainActor
final class ServerWorkspaceIsolationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var a: ServerProfile!
    private var b: ServerProfile!

    override func setUp() async throws {
        suite = "ServerWorkspaceIsolationTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        a = ServerProfile(name: "A", urlString: "https://a.invalid")
        b = ServerProfile(name: "B", urlString: "https://b.invalid")
        defaults.set(try JSONEncoder().encode([a, b]), forKey: "codeg.servers.v1")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func registry() -> ServerWorkspaceRegistry {
        ServerWorkspaceRegistry(store: ServerStore(defaults: defaults), defaults: defaults,
                                clientProvider: { CodegClient(baseURL: $0.baseURL!, token: "fixture-\($0.id)") })
    }

    func testSelectionRetainsEqualIDModelsDraftsAndActivityOwners() {
        let window = registry()
        let first = window.workspace(for: a.id)!, second = window.workspace(for: b.id)!
        let firstSession = first.session(conversationID: 1)!, secondSession = second.session(conversationID: 1)!
        XCTAssertFalse(firstSession === secondSession)
        firstSession.draft = "A unsent"
        secondSession.draft = "B unsent"
        first.model.paths[.projects] = [.project(1)]
        second.model.paths[.projects] = [.project(1)]
        window.selectedServerID = b.id
        window.selectedServerID = a.id
        XCTAssertTrue(first.session(conversationID: 1) === firstSession)
        XCTAssertEqual(firstSession.draft, "A unsent")
        XCTAssertEqual(secondSession.draft, "B unsent")
        XCTAssertFalse(first.activity === second.activity)
        XCTAssertFalse(first.isRetired)
        XCTAssertFalse(second.isRetired)
    }

    func testEndpointEditArchivesOnlyAAndRetiresOldClientBeforeReturning() throws {
        let window = registry()
        let first = window.workspace(for: a.id)!, second = window.workspace(for: b.id)!
        first.session(conversationID: 1)!.draft = "Recover A"
        second.session(conversationID: 1)!.draft = "Keep B"
        var edited = a!
        edited.urlString = "https://replacement.invalid"
        XCTAssertTrue(window.store.update(edited, token: nil))
        XCTAssertTrue(first.isRetired)
        XCTAssertThrowsError(try first.client!.checkBinding()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(window.workspace(for: b.id) === second)
        XCTAssertEqual(second.session(conversationID: 1)!.draft, "Keep B")
        let replacement = window.workspace(for: a.id)!
        XCTAssertFalse(replacement === first)
        XCTAssertEqual(replacement.session(conversationID: 1)!.draft, "")
        XCTAssertEqual(window.recoveredDrafts.map(\.text), ["Recover A"])
        XCTAssertEqual(window.recoveredDrafts[0].serverID, a.id)
    }

    func testRenameAndReorderPreserveGenerationsAndNavigation() {
        let window = registry()
        let first = window.workspace(for: a.id)!, second = window.workspace(for: b.id)!
        first.model.paths[.projects] = [.project(1)]
        var renamed = a!
        renamed.name = "A renamed"
        XCTAssertTrue(window.store.update(renamed, token: nil))
        window.store.move(from: IndexSet(integer: 0), to: 2)
        XCTAssertTrue(window.workspace(for: a.id) === first)
        XCTAssertTrue(window.workspace(for: b.id) === second)
        XCTAssertEqual(first.server.name, "A renamed")
        XCTAssertEqual(first.model.paths[.projects], [.project(1)])
    }

    func testOldTargetCannotOpenSameFolderIDOnReplacement() {
        let window = registry()
        let old = window.workspace(for: a.id)!
        var edited = a!
        edited.urlString = "https://replacement.invalid"
        XCTAssertTrue(window.store.update(edited, token: nil))
        window.selectedServerID = b.id
        window.openProject(1, on: old)
        XCTAssertEqual(window.selectedServerID, b.id)
        XCTAssertTrue(window.workspace(for: b.id)!.model.contentPath.isEmpty)
    }

    func testNavigationRestoresOnlyMatchingOpaqueProfileRevision() {
        let window = registry()
        let first = window.workspace(for: a.id)!
        first.model.paths[.projects] = [.project(1)]
        first.model.selectedConversationID = 1
        window.saveNavigation(first)
        let restored = registry()
        XCTAssertEqual(restored.workspace(for: a.id)!.model.paths[.projects], [.project(1)])
        var edited = a!
        edited.urlString = "https://replacement.invalid"
        XCTAssertTrue(restored.store.update(edited, token: nil))
        XCTAssertTrue(restored.workspace(for: a.id)!.model.paths.isEmpty)
        XCTAssertNil(restored.workspace(for: a.id)!.model.selectedConversationID)
    }

    func testUnboundDraftKeepsNilFolderAcrossSelection() {
        let window = registry()
        let first = window.workspace(for: a.id)!
        let request = NewSessionRequest()
        let draft = first.session(request: request)!
        draft.draft = "ordinary chat"
        window.selectedServerID = b.id
        window.selectedServerID = a.id
        XCTAssertNil(draft.newRequest?.preselectedFolderID)
        XCTAssertTrue(first.session(request: request) === draft)
        XCTAssertEqual(draft.draft, "ordinary chat")
    }

    func testScopedDeepLinkDoesNotClearOtherHostsDraft() {
        let window = registry()
        let first = window.workspace(for: a.id)!, second = window.workspace(for: b.id)!
        first.model.paths[.projects] = [.project(1)]
        first.session(conversationID: 1)!.draft = "A unsent"
        second.model.isCompact = true
        window.handle(url: URL(string: "codeg://conversation/1?server_id=\(b.id.uuidString)")!, compact: true)
        XCTAssertEqual(window.selectedServerID, b.id)
        XCTAssertEqual(second.model.paths[.chats], [.conversation(1)])
        XCTAssertEqual(first.model.paths[.projects], [.project(1)])
        XCTAssertEqual(first.session(conversationID: 1)!.draft, "A unsent")
    }

    func testSplitEntryExitAndWidthChangesPreserveConversationAndDraftIdentity() {
        let window = registry()
        let workspace = window.workspace(for: a.id)!
        let session = workspace.session(conversationID: 42)!
        session.draft = "conversation draft"
        workspace.model.open(.conversation(42))
        window.secondaryServerID = b.id
        workspace.model.transitionShell(isCompact: true)
        XCTAssertEqual(workspace.model.paths[.chats], [.conversation(42)])
        window.showSingleServer()
        workspace.model.transitionShell(isCompact: false)
        XCTAssertNil(window.secondaryServerID)
        XCTAssertEqual(workspace.model.selectedConversationID, 42)
        workspace.model.transitionShell(isCompact: true)
        workspace.model.open(.conversation(43))
        workspace.model.paths[.chats]?.removeLast() // Native Back binding.
        workspace.model.transitionShell(isCompact: false)
        XCTAssertEqual(workspace.model.selectedConversationID, 42)
        XCTAssertTrue(workspace.session(conversationID: 42) === session)
        XCTAssertEqual(session.draft, "conversation draft")
        let compactSession = workspace.session(conversationID: 43)!
        compactSession.draft = "opened in compact"
        window.secondaryServerID = b.id
        workspace.model.transitionShell(isCompact: true)
        workspace.model.open(.conversation(43))
        window.showSingleServer()
        workspace.model.transitionShell(isCompact: false)
        XCTAssertEqual(workspace.model.selectedConversationID, 43)
        XCTAssertTrue(workspace.session(conversationID: 43) === compactSession)
        XCTAssertEqual(compactSession.draft, "opened in compact")
    }

    func testNewTaskTokenAndProjectStackSurviveBothShellDirections() {
        let window = registry()
        let workspace = window.workspace(for: a.id)!
        let request = NewSessionRequest() // Ordinary folderless chat.
        let session = workspace.session(request: request)!
        session.draft = "new task draft"
        workspace.model.open(.project(7))
        workspace.model.open(.project(8))
        workspace.model.open(.newSession(request))
        window.secondaryServerID = b.id
        workspace.model.transitionShell(isCompact: true)
        XCTAssertEqual(workspace.model.selectedTab, .projects)
        XCTAssertEqual(workspace.model.paths[.projects], [.project(7), .project(8), .newSession(request)])
        window.showSingleServer()
        workspace.model.transitionShell(isCompact: false)
        XCTAssertEqual(workspace.model.pendingNewSession, request)
        XCTAssertEqual(workspace.model.contentPath, [.project(7), .project(8)])
        XCTAssertTrue(workspace.session(request: request) === session)
        XCTAssertEqual(session.draft, "new task draft")
        XCTAssertNil(session.newRequest?.preselectedFolderID)

        workspace.model.transitionShell(isCompact: true)
        let splitRequest = NewSessionRequest(preselectedFolderID: 8)
        let splitSession = workspace.session(request: splitRequest)!
        splitSession.draft = "started in compact"
        workspace.model.open(.newSession(splitRequest))
        workspace.model.transitionShell(isCompact: false)
        XCTAssertEqual(workspace.model.pendingNewSession, splitRequest)
        XCTAssertEqual(workspace.model.contentPath, [.project(7), .project(8)])
        workspace.model.transitionShell(isCompact: true)
        XCTAssertEqual(workspace.model.paths[.projects]?.last, .newSession(splitRequest))
        XCTAssertTrue(workspace.session(request: splitRequest) === splitSession)
        XCTAssertEqual(splitSession.draft, "started in compact")
    }

    func testCompactBackToProjectRootClearsObsoleteDetailSelection() {
        let workspace = registry().workspace(for: a.id)!
        workspace.model.open(.newSession(NewSessionRequest()))
        workspace.model.transitionShell(isCompact: true)
        workspace.model.paths[.chats] = []
        workspace.model.transitionShell(isCompact: false)
        XCTAssertNil(workspace.model.pendingNewSession)
        XCTAssertNil(workspace.model.selectedConversationID)
        workspace.model.open(.project(7))
        workspace.model.open(.project(8))
        workspace.model.transitionShell(isCompact: true)
        workspace.model.transitionShell(isCompact: true) // Callback overlap is idempotent.
        XCTAssertEqual(workspace.model.paths[.projects], [.project(7), .project(8)])
        workspace.model.transitionShell(isCompact: false)
        XCTAssertEqual(workspace.model.sidebarSection, .projects)
        XCTAssertEqual(workspace.model.contentPath, [.project(7), .project(8)])
    }

    func testRestoredCompactNavigationSurvivesInitialWidthTransition() {
        let window = registry()
        let first = window.workspace(for: a.id)!
        first.model.transitionShell(isCompact: true)
        first.model.selectedTab = .projects
        first.model.open(.project(7))
        first.model.open(.project(8))
        window.saveNavigation(first)
        let restoredWindow = registry()
        let restored = restoredWindow.workspace(for: a.id)!
        XCTAssertEqual(restored.model.sidebarSection, .projects)
        XCTAssertEqual(restored.model.contentPath, [.project(7), .project(8)])
        restored.model.transitionShell(isCompact: true)
        XCTAssertEqual(restored.model.selectedTab, .projects)
        XCTAssertEqual(restored.model.paths[.projects], [.project(7), .project(8)])
    }
}
