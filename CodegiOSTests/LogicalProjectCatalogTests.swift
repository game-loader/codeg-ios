import Foundation
import XCTest
@testable import Codeg

@MainActor
final class LogicalProjectCatalogTests: XCTestCase {
    private func folder(_ id: Int = 7, _ path: String = "/repo", parent: Int? = nil, kind: FolderKind = .regular) -> FolderDetail {
        FolderDetail(id: id, name: "repo", path: path, gitBranch: nil, defaultAgentType: nil,
                     lastOpenedAt: .distantPast, sortOrder: id, color: "", parentId: parent, kind: kind)
    }
    private func identity(_ key: String = "github:owner/repo") -> RepositoryProjectIdentity {
        RepositoryProjectIdentity(projectKey: key, provider: "github", host: "github.com",
                                  repositoryPath: "owner/repo", remoteName: "upstream")
    }
    private func entry(_ folder: FolderDetail, key: String = "github:owner/repo") -> RepositoryProjectIdentityEntry {
        RepositoryProjectIdentityEntry(folderId: folder.id, path: folder.path, status: .resolved, identity: identity(key))
    }
    private func snapshot(_ server: UUID, folders: [FolderDetail], open: [FolderDetail]? = nil,
                          entries: [RepositoryProjectIdentityEntry] = []) -> ProjectCatalogSnapshot {
        ProjectCatalogSnapshot(serverID: server, configurationRevision: UUID(), generationID: UUID(),
                               folders: folders, openFolders: open ?? folders,
                               identities: Dictionary(uniqueKeysWithValues: entries.map {
            (ProjectFolderKey(folderID: $0.folderId, path: $0.path!), ProjectIdentityState(identity: $0.identity, availability: .resolved))
        }))
    }
    private func loader(_ fixture: CatalogFixture, lifetime: ServerBindingLifetime = ServerBindingLifetime()) -> ProjectCatalogModel {
        ProjectCatalogModel(lifetime: lifetime, loadFolders: { try await fixture.folders() },
                            loadOpenFolders: { try await fixture.openFolders() },
                            loadIdentities: { try await fixture.identities($0) })
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for test barrier")
    }

    func testCanonicalProjectsRetainEveryHostAndLocalCheckout() {
        let a = UUID(), b = UUID(), root = folder(), second = folder(8, "/checkout"), remote = folder(7, "/other")
        let projects = LogicalProjectProjection.projects([
            snapshot(a, folders: [root, second], entries: [entry(root), entry(second)]),
            snapshot(b, folders: [remote], entries: [entry(remote)])
        ])
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].setups.count, 3)
        XCTAssertEqual(Set(projects[0].setups.map(\.reference)).count, 3)
        XCTAssertEqual(Set(projects[0].setups.map(\.serverID)), [a, b])
        XCTAssertEqual(Set(projects[0].setups.map(\.path)), ["/repo", "/checkout", "/other"])
    }

    func testUnknownAndDifferentSourcesNeverGroupByNameIDOrPath() {
        let a = UUID(), b = UUID(), root = folder()
        XCTAssertEqual(LogicalProjectProjection.projects([snapshot(a, folders: [root]), snapshot(b, folders: [root])]).count, 2)
        XCTAssertEqual(LogicalProjectProjection.projects([
            snapshot(a, folders: [root], entries: [entry(root, key: "git:forge/Owner/Repo")]),
            snapshot(b, folders: [root], entries: [entry(root, key: "git:forge/owner/repo")])
        ]).count, 2)
    }

    func testWorktreesUseOnlyTheirOwningInventoryAndIncludeKnownClosedRoot() {
        let root = folder(), child = folder(9, "/linked", parent: 7), otherChild = folder(9, "/foreign", parent: 7)
        let projects = LogicalProjectProjection.projects([
            snapshot(UUID(), folders: [root, child], open: [child], entries: [entry(root)]),
            snapshot(UUID(), folders: [root, otherChild], entries: [entry(root)])
        ])
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].setups.count, 2)
        XCTAssertEqual(Set(projects[0].setups.flatMap { $0.worktrees.map(\.path) }), ["/linked", "/foreign"])
        for setup in projects[0].setups { XCTAssertEqual(setup.worktrees.count, 1) }
        let orphan = LogicalProjectProjection.projects([snapshot(UUID(), folders: [child])])
        XCTAssertEqual(orphan[0].setups[0].folder.id, 9)
        XCTAssertTrue(LogicalProjectProjection.projects([snapshot(UUID(), folders: [folder(kind: .chat)])]).isEmpty)
    }

    func testBootstrapAndDuplicateLoadsHaveNoConversationDependency() async throws {
        let fixture = CatalogFixture(rows: [folder()])
        let gate = CatalogGate<[FolderDetail]>()
        fixture.folderGate = gate
        let model = loader(fixture)
        let first = Task { await model.refresh() }
        try await wait { gate.waiting }
        let second = Task { await model.refresh() }
        await Task.yield()
        gate.release([folder()])
        await first.value; await second.value
        XCTAssertEqual(fixture.folderCalls, 1)
        XCTAssertEqual(fixture.identityBatches, [[7]])
        XCTAssertEqual(model.folder(id: 7)?.path, "/repo")
        XCTAssertFalse(model.isLoading)
    }

    func testChunkingAndPartialEndpointsRetainTheirSuccessfulSnapshots() async throws {
        let rows = (1...260).map { folder($0, "/repo/\($0)") }
        let fixture = CatalogFixture(rows: rows), model = loader(fixture)
        await model.refresh()
        XCTAssertEqual(fixture.identityBatches.map(\.count), [128, 128, 4])
        fixture.openError = .unauthorized
        fixture.rows = [folder(1, "/moved")]
        await model.refresh(force: true)
        XCTAssertEqual(model.folders.map(\.path), ["/moved"])
        XCTAssertEqual(model.openFolders.count, 260, "failed endpoint keeps its accepted snapshot")
        XCTAssertEqual(model.setupFolders.map(\.path), ["/moved"], "successful inventory prunes stale paths")
        XCTAssertNotNil(model.folderIssue)
        fixture.openError = nil; fixture.folderError = .unauthorized; fixture.rows = []
        await model.refresh(force: true)
        XCTAssertEqual(model.folders.count, 1)
        XCTAssertTrue(model.setupFolders.isEmpty, "successful empty open snapshot is authoritative")
    }

    func testUnavailableOmittedAndFailedEntriesRetainIdentityButNullRemovesIt() async throws {
        let fixture = CatalogFixture(rows: [folder()]), model = loader(fixture)
        await model.refresh()
        let key = ProjectFolderKey(folderID: 7, path: "/repo")
        XCTAssertEqual(model.identities[key]?.identity?.projectKey, "github:owner/repo")
        fixture.identityReply = []
        await model.refresh(force: true)
        XCTAssertEqual(model.identities[key]?.availability, .unavailable)
        XCTAssertNotNil(model.identities[key]?.identity)
        fixture.identityReply = [.init(folderId: 7, path: nil, status: .unavailable, identity: nil)]
        await model.refresh(force: true)
        XCTAssertNotNil(model.identities[key]?.identity)
        fixture.identityError = .unauthorized
        await model.refresh(force: true)
        XCTAssertNotNil(model.identities[key]?.identity)
        fixture.identityError = nil
        fixture.identityReply = [.init(folderId: 7, path: "/repo", status: .resolved, identity: nil)]
        await model.refresh(force: true)
        XCTAssertNil(model.identities[key]?.identity)
        XCTAssertEqual(model.identities[key]?.availability, .resolved)
    }

    func testPathChangeAndRemovalPruneAcceptedIdentity() async throws {
        let fixture = CatalogFixture(rows: [folder()]), model = loader(fixture)
        await model.refresh()
        fixture.rows = [folder(7, "/moved")]
        fixture.identityReply = [entry(folder())] // wrong exact path cannot attach
        await model.refresh(force: true)
        XCTAssertNil(model.identities[ProjectFolderKey(folderID: 7, path: "/repo")])
        XCTAssertNil(model.identities[ProjectFolderKey(folderID: 7, path: "/moved")]?.identity)
        fixture.rows = []
        await model.refresh(force: true)
        XCTAssertTrue(model.identities.isEmpty)
    }

    func testOlderSuccessFailureAndLoadingCannotOverwriteNewRefresh() async throws {
        for failOld in [false, true] {
            let fixture = CatalogFixture(rows: [folder()]), model = loader(fixture)
            let gate = CatalogGate<[RepositoryProjectIdentityEntry]>()
            fixture.identityGate = gate
            let old = Task { await model.refresh() }
            try await wait { gate.waiting }
            fixture.identityGate = nil
            fixture.rows = [folder(7, "/new")]
            await model.refresh(force: true)
            XCTAssertFalse(model.isLoading)
            gate.release(failOld ? .failure(APIError.unauthorized) : .success([entry(folder())]))
            await old.value
            XCTAssertEqual(model.folder(id: 7)?.path, "/new")
            XCTAssertNil(model.identityIssue)
            XCTAssertFalse(model.isLoading)
            XCTAssertNil(model.identities[ProjectFolderKey(folderID: 7, path: "/repo")])
        }
    }

    func testSlowFolderBootstrapCannotPublishItsFailureOverANewerSnapshot() async throws {
        let fixture = CatalogFixture(rows: [folder()]), model = loader(fixture)
        let gate = CatalogGate<[FolderDetail]>()
        fixture.folderGate = gate
        let old = Task { await model.refresh() }
        try await wait { gate.waiting }
        fixture.folderGate = nil
        fixture.rows = [folder(7, "/current")]
        await model.refresh(force: true)
        gate.release(.failure(APIError.unauthorized))
        await old.value
        XCTAssertNil(model.folderIssue)
        XCTAssertEqual(model.folder(id: 7)?.path, "/current")
        XCTAssertFalse(model.isLoading)
    }

    func testLifetimeInvalidationDuringHeldResponseCannotPublishMetadata() async throws {
        let fixture = CatalogFixture(rows: [folder()]), lifetime = ServerBindingLifetime()
        let model = loader(fixture, lifetime: lifetime), gate = CatalogGate<[RepositoryProjectIdentityEntry]>()
        fixture.identityGate = gate
        let old = Task { await model.refresh() }
        try await wait { gate.waiting }
        lifetime.invalidate()
        gate.release([entry(folder())])
        await old.value
        XCTAssertTrue(model.identities.isEmpty)
        model.retire()
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.folders.isEmpty)
    }

    func testSuccessfulOpenSnapshotCanMoveAPathWhileFullInventoryFails() async throws {
        let fixture = CatalogFixture(rows: [folder()]), model = loader(fixture)
        await model.refresh()
        fixture.folderError = .unauthorized
        fixture.rows = [folder(7, "/moved")]
        await model.refresh(force: true)
        XCTAssertEqual(model.folder(id: 7)?.path, "/moved")
        XCTAssertEqual(model.setupFolders.map(\.path), ["/moved"])
        XCTAssertNil(model.identities[ProjectFolderKey(folderID: 7, path: "/repo")])
    }

    func testWireDTOUsesExactRequestAndSafeResponseFields() throws {
        let data = Data(#"[{"folder_id":7,"path":"/repo","status":"resolved","identity":{"project_key":"github:owner/repo","provider":"github","host":"github.com","repository_path":"owner/repo","remote_name":"upstream"}},{"folder_id":8,"path":"/plain","status":"resolved","identity":null},{"folder_id":9,"path":null,"status":"unavailable","identity":null}]"#.utf8)
        let entries = try CodegJSON.decoder.decode([RepositoryProjectIdentityEntry].self, from: data)
        XCTAssertEqual(entries[0].identity?.projectKey, "github:owner/repo")
        XCTAssertEqual(entries[0].identity?.remoteName, "upstream")
        XCTAssertEqual(entries[1].status, .resolved)
        XCTAssertNil(entries[1].identity)
        XCTAssertEqual(entries[2].status, .unavailable)
        XCTAssertNil(entries[2].path)
        let encoded = try CodegJSON.encoder.encode(RepositoryProjectIdentityRequest(folderIds: [7, 8, 9]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["folderIds"])
        XCTAssertEqual(object["folderIds"] as? [Int], [7, 8, 9])
        let safe = try CodegJSON.encoder.encode(entries[0].identity!)
        XCTAssertFalse(String(decoding: safe, as: UTF8.self).contains("url"))
    }

    func testHistoryKeepsRootWorktreeCompletedPinnedAndFolderlessScopesDistinct() {
        let root = folder(), child = folder(9, "/linked", parent: 7)
        func session(_ id: Int, _ folderID: Int, pinned: Bool = false) -> ConversationSummary {
            ConversationSummary(id: id, folderId: folderID, title: "existing", agentType: .claudeCode,
                                status: .completed, model: "original-model", gitBranch: nil, externalId: nil,
                                messageCount: 2, createdAt: .distantPast, updatedAt: .distantPast,
                                pinnedAt: pinned ? Date() : nil)
        }
        let rows = [session(1, 7), session(2, 7, pinned: true), session(3, 9), session(4, 88)]
        XCTAssertEqual(ProjectSessionHistory.folders(for: root, inventory: [root, child]).map(\.id), [7, 9])
        XCTAssertEqual(ProjectSessionHistory.sessions(in: 7, conversations: rows).map(\.id), [2, 1])
        XCTAssertEqual(ProjectSessionHistory.sessions(in: 9, conversations: rows).map(\.id), [3])
        XCTAssertEqual(ProjectSessionHistory.sessions(in: 9, conversations: rows)[0].model, "original-model")
        XCTAssertEqual(ProjectSessionHistory.folders(for: child, inventory: [root, child]).map(\.id), [9])
    }

    func testRetirementClearsSynchronouslyAndRejectsLateResultsInEveryState() async throws {
        let fixture = CatalogFixture(rows: [folder()]), lifetime = ServerBindingLifetime(), model = loader(fixture, lifetime: lifetime)
        await model.refresh()
        let gate = CatalogGate<[RepositoryProjectIdentityEntry]>()
        fixture.identityGate = gate
        let pending = Task { await model.refresh(force: true) }
        try await wait { gate.waiting }
        model.retire(); lifetime.invalidate()
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertTrue(model.identities.isEmpty)
        XCTAssertFalse(model.isLoading)
        gate.release(.failure(APIError.unauthorized))
        await pending.value
        XCTAssertNil(model.identityIssue)
        XCTAssertTrue(model.folders.isEmpty)
        await model.refresh(force: true)
        XCTAssertTrue(model.identities.isEmpty)
    }

    func testOldServerCapabilityIsScopedAndExplicitRefreshReprobes() async throws {
        for status in [404, 405, 501] {
            let fixture = CatalogFixture(rows: [folder()]), model = loader(fixture)
            fixture.identityError = .server(status: status, code: nil, message: "missing", detail: nil)
            await model.refresh()
            XCTAssertEqual(model.identityIssue, .upgradeRequired)
            XCTAssertEqual(model.setupFolders.count, 1)
            await model.refresh()
            XCTAssertEqual(fixture.identityBatches.count, 1)
            fixture.identityError = nil
            await model.refresh(force: true)
            XCTAssertEqual(fixture.identityBatches.count, 2)
            XCTAssertNil(model.identityIssue)
            XCTAssertNotNil(model.identities.values.first?.identity)
        }
        let fixture = CatalogFixture(rows: [folder()]), model = loader(fixture)
        fixture.identityError = .server(status: 404, code: "not_found", message: "folder missing", detail: nil)
        await model.refresh()
        XCTAssertEqual(model.identityIssue, .unavailable)
        await model.refresh()
        XCTAssertEqual(fixture.identityBatches.count, 2)
    }
}

@MainActor
final class CatalogGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    var waiting: Bool { continuation != nil }
    func hold() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release(_ value: Value) { release(.success(value)) }
    func release(_ result: Result<Value, Error>) {
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
}

@MainActor
final class CatalogFixture {
    var rows: [FolderDetail]
    var folderError: APIError?, openError: APIError?, identityError: APIError?
    var identityReply: [RepositoryProjectIdentityEntry]?
    var folderGate: CatalogGate<[FolderDetail]>?
    var identityGate: CatalogGate<[RepositoryProjectIdentityEntry]>?
    var folderCalls = 0
    var identityBatches: [[Int]] = []
    init(rows: [FolderDetail]) { self.rows = rows }
    func folders() async throws -> [FolderDetail] {
        folderCalls += 1
        if let gate = folderGate { return try await gate.hold() }
        if let error = folderError { throw error }
        return rows
    }
    func openFolders() async throws -> [FolderDetail] {
        if let error = openError { throw error }
        return rows
    }
    func identities(_ ids: [Int]) async throws -> [RepositoryProjectIdentityEntry] {
        identityBatches.append(ids)
        if let gate = identityGate { return try await gate.hold() }
        if let error = identityError { throw error }
        if let reply = identityReply { return reply }
        return rows.filter { ids.contains($0.id) }.map {
            RepositoryProjectIdentityEntry(folderId: $0.id, path: $0.path, status: .resolved,
                identity: RepositoryProjectIdentity(projectKey: "github:owner/repo", provider: "github", host: "github.com",
                                                    repositoryPath: "owner/repo", remoteName: "origin"))
        }
    }
}
