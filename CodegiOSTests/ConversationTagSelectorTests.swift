import Foundation
import XCTest
@testable import Codeg

@MainActor
final class ConversationTagSelectorTests: XCTestCase {
    private func summary(_ id: Int, folder: Int = 7, tags: [Int], title: String = "match",
                         model: String? = nil, updated: Int = 0, pinned: Int? = nil) -> ConversationSummary {
        ConversationSummary(id: id, folderId: folder, title: title, agentType: .claudeCode,
                            status: .completed, model: model, gitBranch: nil, externalId: nil,
                            messageCount: 1, createdAt: Date(timeIntervalSince1970: 0),
                            updatedAt: Date(timeIntervalSince1970: Double(updated)),
                            pinnedAt: pinned.map { Date(timeIntervalSince1970: Double($0)) }, tagIds: tags)
    }

    private func tagReply(_ ids: [Int]) throws -> WorktreeTestReply {
        let rows: [[String: Any]] = ids.map {
            ["id": $0, "folder_id": NSNull(), "name": "tag \($0)", "color": "#3b82f6", "sort_order": $0]
        }
        return WorktreeTestReply(data: try WorktreeTestReply.json(rows))
    }

    private func enqueueSnapshot(_ fixture: WorktreeTestFixture, rows: [ConversationSummary],
                                 folders: [[String: Any]]? = nil) throws {
        let folders = folders ?? [WorktreeTestServer.folder("/repo", id: 7)]
        fixture.server.setFolders(folders)
        fixture.server.enqueue("list_open_folder_details", WorktreeTestReply(data: try WorktreeTestReply.json(folders)))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        fixture.server.enqueue("list_all_conversations", WorktreeTestReply(data: try encoder.encode(rows)))
    }

    func testAnyAllAndEmptySelectionUseTagSets() {
        let filter = SessionTagFilter()
        XCTAssertTrue(filter.matches(tagIDs: []))
        filter.selectedIDs = [1, 2]
        XCTAssertTrue(filter.matches(tagIDs: [2, 99]))
        XCTAssertFalse(filter.matches(tagIDs: []))
        filter.mode = .all
        XCTAssertFalse(filter.matches(tagIDs: [1, 1]))
        XCTAssertTrue(filter.matches(tagIDs: [2, 1, 99]))
        filter.clear()
        XCTAssertTrue(filter.matches(tagIDs: []))
    }

    func testServerSearchResultsKeepTheirOrderWhenTagFilterIsApplied() {
        let rows = [summary(7, tags: [1, 2]), summary(3, tags: [2]), summary(9, tags: []), summary(1, tags: [1, 2])]
        let filter = SessionTagFilter()
        XCTAssertEqual(filter.apply(to: rows).map(\.id), [7, 3, 9, 1])
        filter.selectedIDs = [1, 2]
        XCTAssertEqual(filter.apply(to: rows).map(\.id), [7, 3, 1])
        filter.mode = .all
        XCTAssertEqual(filter.apply(to: rows).map(\.id), [7, 1])
    }

    func testAnyAllSearchAndOrderingApplyToPinnedMergedGroupsAndUngrouped() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let folders = [WorktreeTestServer.folder("/repo", id: 7),
                       WorktreeTestServer.folder("/child", id: 8, parent: 7),
                       WorktreeTestServer.folder("/other", id: 9)]
        let rows = [summary(1, tags: [1], updated: 90, pinned: 10),
                    summary(2, tags: [1, 2], updated: 10, pinned: 20),
                    summary(3, tags: [2], updated: 40),
                    summary(4, folder: 8, tags: [1, 2], title: "branch", model: "needle", updated: 50),
                    summary(5, tags: [], updated: 100),
                    summary(6, folder: 100, tags: [1], updated: 20),
                    summary(7, folder: 100, tags: [1, 2], updated: 30),
                    summary(8, folder: 9, tags: [], updated: 60)]
        try enqueueSnapshot(fixture, rows: rows, folders: folders)
        let filter = SessionTagFilter(), list = SessionListViewModel(client: fixture.client, tagFilter: filter)
        await list.reload(client: fixture.client)
        XCTAssertNil(list.error)
        filter.selectedIDs = [1, 2]
        XCTAssertEqual(list.pinned(searchText: "").map(\.id), [2, 1], "pin order is independent of updatedAt")
        XCTAssertEqual(list.folderGroups(searchText: "").map(\.id), [7], "tag filter hides empty groups")
        XCTAssertEqual(list.folderGroups(searchText: "").first?.conversations.map(\.id), [4, 3])
        XCTAssertEqual(list.ungrouped(searchText: "").map(\.id), [7, 6])
        filter.mode = .all
        XCTAssertEqual(list.pinned(searchText: "").map(\.id), [2])
        XCTAssertEqual(list.folderGroups(searchText: "").first?.conversations.map(\.id), [4])
        XCTAssertEqual(list.ungrouped(searchText: "").map(\.id), [7])
        XCTAssertEqual(list.folderGroups(searchText: " NEEDLE ").first?.conversations.map(\.id), [4])
        XCTAssertTrue(list.pinned(searchText: "needle").isEmpty)
        XCTAssertTrue(list.ungrouped(searchText: "needle").isEmpty)
        filter.clear()
        XCTAssertEqual(list.folderGroups(searchText: "").map(\.id), [7, 9])
        XCTAssertEqual(list.folderGroups(searchText: "").first?.conversations.map(\.id), [5, 4, 3])
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testFreshListKeepsWorkspaceSelectionButEndpointReloadClearsIt() async throws {
        let a = try WorktreeTestFixture(), b = try WorktreeTestFixture()
        defer { a.close(); b.close() }
        try enqueueSnapshot(a, rows: [summary(1, tags: [1])])
        try enqueueSnapshot(b, rows: [summary(1, tags: [1])])
        let filter = SessionTagFilter()
        filter.selectedIDs = [1]
        filter.mode = .all
        let list = SessionListViewModel(client: a.client, tagFilter: filter)
        await list.reload(client: a.client)
        XCTAssertEqual(filter.selectedIDs, [1], "shell recreation retains this workspace's selection")
        XCTAssertEqual(filter.mode, .all)
        await list.reload(client: b.client)
        XCTAssertTrue(filter.selectedIDs.isEmpty, "matching IDs on another endpoint cannot inherit selection")
        XCTAssertEqual(filter.mode, .any)
    }

    func testPickerDeltasPreserveUnknownAndUntouchedTags() {
        var selection = ConversationTagAssignmentSelection(tagIDs: [1, 99, 100])
        selection.toggle(1)
        selection.toggle(2)
        let delta = selection.delta(availableIDs: [1, 2, 3])
        XCTAssertEqual(delta.add, [2])
        XCTAssertEqual(delta.remove, [1])
        XCTAssertTrue(selection.selectedIDs.isSuperset(of: [99, 100]))
        selection.toggle(1)
        selection.toggle(2)
        XCTAssertTrue(selection.delta(availableIDs: [1, 2, 3]).add.isEmpty)
        XCTAssertTrue(selection.delta(availableIDs: [1, 2, 3]).remove.isEmpty)
    }

    func testSameEndpointReplacementBindingCannotInheritSelection() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let oldLifetime = ServerBindingLifetime(), newLifetime = ServerBindingLifetime()
        let first = fixture.client.bound(to: oldLifetime), replacement = fixture.client.bound(to: newLifetime)
        try enqueueSnapshot(fixture, rows: [summary(1, tags: [1])])
        let filter = SessionTagFilter(), list = SessionListViewModel(client: first, tagFilter: filter)
        await list.reload(client: first)
        filter.selectedIDs = [1]
        oldLifetime.invalidate()
        try enqueueSnapshot(fixture, rows: [summary(1, tags: [1])])
        await list.reload(client: replacement)
        XCTAssertTrue(filter.selectedIDs.isEmpty)
    }

    func testPickerRechecksCurrentScopeBeforeSaving() {
        var selection = ConversationTagAssignmentSelection(tagIDs: [1, 99])
        selection.toggle(1)
        selection.toggle(2)
        XCTAssertEqual(selection.delta(availableIDs: [1, 2]).remove, [1])
        let delta = selection.delta(availableIDs: [3])
        XCTAssertTrue(delta.add.isEmpty)
        XCTAssertTrue(delta.remove.isEmpty, "scope loss or catalog removal must not remove invisible assignments")
    }

    func testCatalogFailuresAndMutationsDoNotPruneUntilAuthoritativeReload() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let suite = "ConversationTagSelectorTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "A", urlString: fixture.client.baseURL.absoluteString)
        let workspace = ServerWorkspace(server: profile, client: fixture.client, store: ServerStore(defaults: defaults))
        let tags = try XCTUnwrap(workspace.conversationTags)
        fixture.server.enqueue("list_conversation_tags", try tagReply([1, 2]))
        await workspace.refreshConversationTags()
        workspace.conversationTagFilter.selectedIDs = [1, 2]
        fixture.server.enqueue("list_conversation_tags", .failure(status: 401))
        await workspace.refreshConversationTags()
        XCTAssertEqual(workspace.conversationTagFilter.selectedIDs, [1, 2])
        XCTAssertNotNil(tags.errorMessage)
        fixture.server.enqueue("delete_conversation_tag", WorktreeTestReply(data: Data("null".utf8)))
        let deleted = await tags.delete(tagID: 2)
        XCTAssertTrue(deleted)
        workspace.synchronizeConversationTagFilter()
        XCTAssertEqual(workspace.conversationTagFilter.selectedIDs, [1, 2], "mutation alone cannot prune")
        fixture.server.enqueue("list_conversation_tags", try tagReply([1]))
        await workspace.refreshConversationTags()
        XCTAssertEqual(workspace.conversationTagFilter.selectedIDs, [1])
        fixture.server.enqueue("list_conversation_tags", try tagReply([]))
        await workspace.refreshConversationTags()
        XCTAssertTrue(workspace.conversationTagFilter.selectedIDs.isEmpty, "successful empty catalog is authoritative")
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testPruningConsumesAuthoritativeSnapshotWhenMutationPrecedesObservation() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let suite = "ConversationTagSelectorTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "A", urlString: fixture.client.baseURL.absoluteString)
        let workspace = ServerWorkspace(server: profile, client: fixture.client, store: ServerStore(defaults: defaults))
        let tags = try XCTUnwrap(workspace.conversationTags)
        workspace.conversationTagFilter.selectedIDs = [1, 2, 3]
        fixture.server.enqueue("list_conversation_tags", try tagReply([1, 2]))
        await tags.load() // SwiftUI has not observed the successful revision yet.
        fixture.server.enqueue("delete_conversation_tag", WorktreeTestReply(data: Data("null".utf8)))
        let deleted = await tags.delete(tagID: 2)
        XCTAssertTrue(deleted)
        workspace.synchronizeConversationTagFilter()
        XCTAssertEqual(workspace.conversationTagFilter.selectedIDs, [1, 2])
    }

    func testWorkspaceFocusAndReplacementKeepEqualIDsIsolated() async throws {
        let fixtureA = try WorktreeTestFixture(), fixtureB = try WorktreeTestFixture()
        defer { fixtureA.close(); fixtureB.close() }
        let suite = "ConversationTagSelectorTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ServerProfile(name: "A", urlString: fixtureA.client.baseURL.absoluteString)
        let b = ServerProfile(name: "B", urlString: fixtureB.client.baseURL.absoluteString)
        defaults.set(try JSONEncoder().encode([a, b]), forKey: "codeg.servers.v1")
        let registry = ServerWorkspaceRegistry(store: ServerStore(defaults: defaults), defaults: defaults,
                                              clientProvider: { profile in
            let fixture = profile.id == a.id ? fixtureA : fixtureB
            return CodegClient(baseURL: profile.baseURL!, token: fixture.client.token,
                               session: fixture.session, readSession: fixture.session, probeSession: fixture.session)
        })
        let first = try XCTUnwrap(registry.workspace(for: a.id)), second = try XCTUnwrap(registry.workspace(for: b.id))
        let firstTags = try XCTUnwrap(first.conversationTags), secondTags = try XCTUnwrap(second.conversationTags)
        XCTAssertFalse(firstTags === secondTags)
        first.conversationTagFilter.selectedIDs = [1]
        second.conversationTagFilter.selectedIDs = [1, 2]
        first.session(conversationID: 1)?.draft = "A draft"
        second.session(conversationID: 1)?.draft = "B draft"
        registry.selectedServerID = b.id
        registry.selectedServerID = a.id
        XCTAssertTrue(registry.workspace(for: a.id)?.conversationTags === firstTags)
        XCTAssertEqual(first.conversationTagFilter.selectedIDs, [1])
        XCTAssertEqual(second.conversationTagFilter.selectedIDs, [1, 2])
        var edited = a
        edited.urlString = "https://replacement.invalid"
        XCTAssertTrue(registry.store.update(edited, token: nil))
        let replacement = try XCTUnwrap(registry.workspace(for: a.id))
        XCTAssertTrue(firstTags.isRetired)
        XCTAssertTrue(first.conversationTagFilter.selectedIDs.isEmpty)
        XCTAssertTrue(replacement.conversationTagFilter.selectedIDs.isEmpty)
        XCTAssertFalse(replacement.conversationTags === firstTags)
        XCTAssertEqual(second.conversationTagFilter.selectedIDs, [1, 2])
        XCTAssertEqual(second.session(conversationID: 1)?.draft, "B draft")
        XCTAssertEqual(registry.recoveredDrafts.map(\.text), ["A draft"])
    }

    func testUnsupportedEndpointClearsFilterWithoutPruningOnAuthenticationFailure() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let suite = "ConversationTagSelectorTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = ServerWorkspace(server: ServerProfile(name: "A", urlString: fixture.client.baseURL.absoluteString),
                                        client: fixture.client, store: ServerStore(defaults: defaults))
        workspace.conversationTagFilter.selectedIDs = [1]
        fixture.server.enqueue("list_conversation_tags", .failure(status: 401))
        await workspace.refreshConversationTags()
        XCTAssertEqual(workspace.conversationTagFilter.selectedIDs, [1])
        fixture.server.enqueue("list_conversation_tags", .failure(status: 404, code: nil, message: "Not Found"))
        await workspace.refreshConversationTags()
        XCTAssertEqual(workspace.conversationTags?.isUnsupported, true)
        XCTAssertTrue(workspace.conversationTagFilter.selectedIDs.isEmpty)
    }
}
