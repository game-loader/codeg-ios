#!/usr/bin/env python3
"""Portable architecture probe using current AppModel/registry/navigation code.

Requires Docker and swift:6.2-jammy. SwiftUI imports are replaced with Foundation;
unavailable UI, transport, ActivityModel and SessionDetailViewModel dependencies
are explicit doubles. This does NOT run native XCTest, real first-send/stream
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
]
PARSE = SOURCES + [
    "CodegiOS/App/RootView.swift",
    "CodegiOS/Features/Sessions/SessionListView.swift",
    "CodegiOS/Features/SessionDetail/SessionDetailViewModel.swift",
    "CodegiOS/Features/Projects/MultiServerProjectListView.swift",
    "CodegiOSTests/ServerWorkspaceIsolationTests.swift",
    "CodegiOSTests/ServerWorkspaceArchitectureRecoveryTests.swift",
]

STUBS = r'''
import Foundation
typealias LocalizedStringKey = String
enum AgentType: String, Hashable { case claudeCode }
struct Machine: Hashable { let id: String }
enum SettingsLeaf: Hashable {
    case appearance
    init?(slug: String) { guard slug == "appearance" else { return nil }; self = .appearance }
}
protocol SessionEventStream {}
@MainActor final class ActivityModel { func reset() {} }
@MainActor final class CodegClient {
    let baseURL: URL
    let token: String
    let lifetime: ServerBindingLifetime?
    init(baseURL: URL, token: String, lifetime: ServerBindingLifetime? = nil) {
        self.baseURL = baseURL; self.token = token; self.lifetime = lifetime
    }
    func bound(to lifetime: ServerBindingLifetime) -> CodegClient {
        CodegClient(baseURL: baseURL, token: token, lifetime: lifetime)
    }
    func checkBinding() throws { try lifetime?.check() }
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
    struct QueueItem { let text: String }
    struct Snapshot { let recoveryText: String }
    var conversationID: Int?
    var newRequest: NewSessionRequest?
    var draft = ""
    var queuedMessages: [QueueItem] = []
    var teardownCount = 0
    init(client: CodegClient, conversationID: Int, eventStreamFactory: (() -> any SessionEventStream)? = nil) {
        self.conversationID = conversationID
    }
    init(client: CodegClient, newSession: NewSessionRequest, eventStreamFactory: (() -> any SessionEventStream)? = nil) {
        self.newRequest = newSession
    }
    var retirementSnapshot: Snapshot {
        Snapshot(recoveryText: ([draft] + queuedMessages.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
    func teardown() { teardownCount += 1 }
}
'''

PROBE = r'''
import Foundation
@main @MainActor struct ArchitectureProbe {
    static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); passed += 1; print("PASS \(label)")
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
        print("\(passed) portable architecture invariants passed; native recovery/UI not executed")
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
    print("PASS source wiring: healthy Chats/catalog exit, both layout callbacks, pending-turn snapshot before teardown", flush=True)


def main():
    check_wiring()
    subprocess.run([
        "docker", "run", "--rm", "-v", f"{ROOT}:/repo:ro", "-w", "/repo", IMAGE,
        "swiftc", "-frontend", "-parse", *PARSE,
    ], check=True)
    print(f"PASS Swift 6.2 syntax parse: {len(PARSE)} current source/test files", flush=True)
    with tempfile.TemporaryDirectory(prefix="codeg-ios-architecture-") as directory:
        path = Path(directory)
        for source in SOURCES:
            (path / Path(source).name).write_text((ROOT / source).read_text().replace("import SwiftUI", "import Foundation"))
        (path / "Stubs.swift").write_text(STUBS)
        (path / "Probe.swift").write_text(PROBE)
        files = sorted(p.name for p in path.glob("*.swift"))
        subprocess.run([
            "docker", "run", "--rm", "-v", f"{path}:/probe", "-w", "/probe", IMAGE,
            "swiftc", "-swift-version", "5", "-parse-as-library", *files, "-o", "probe",
        ], check=True)
        subprocess.run([
            "docker", "run", "--rm", "-v", f"{path}:/probe", "-w", "/probe", IMAGE, "./probe",
        ], check=True)


if __name__ == "__main__":
    main()
