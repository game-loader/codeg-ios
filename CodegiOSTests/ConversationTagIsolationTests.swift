import Foundation
import XCTest
@testable import Codeg

@MainActor
final class ConversationTagIsolationTests: XCTestCase {
    private func folder(_ id: Int, parent: Int? = nil, kind: FolderKind = .regular) -> FolderDetail {
        FolderDetail(id: id, name: "Folder \(id)", path: "/same-path", gitBranch: nil,
            defaultAgentType: nil, lastOpenedAt: .distantPast, sortOrder: 0,
            color: "#0969da", parentId: parent, kind: kind)
    }

    func testSameIDsOnABStayOnCapturedEndpointForEveryMutation() async throws {
        let a = ConversationTagTestFixture(label: "A"), b = ConversationTagTestFixture(label: "B")
        defer { a.close(); b.close() }
        a.server.setTags([ConversationTagTestServer.tag(1, folder: nil, name: "A")])
        b.server.setTags([ConversationTagTestServer.tag(1, folder: nil, name: "B")])
        let modelA = ConversationTagsModel(client: a.client, conversationID: 42)
        let modelB = ConversationTagsModel(client: b.client, conversationID: 42)
        await modelA.load(); await modelB.load()
        XCTAssertEqual(modelA.tags.first?.name, "A")
        XCTAssertEqual(modelB.tags.first?.name, "B")
        _ = await modelA.update(tagID: 1, name: "A changed")
        let created = await modelA.create(name: "Only A", color: "#123456")
        let newID = try XCTUnwrap(created?.id)
        _ = await modelA.reorder(tagIDs: [newID, 1])
        let summary = await modelA.assign(conversationID: 42, add: [1], remove: [])
        XCTAssertEqual(summary?.tagIds, [1, 900])
        _ = await modelA.delete(tagID: newID)
        await modelA.loadBranchSettings()
        _ = await modelA.updateBranchSettings(enabled: false, color: "#123456")
        await modelB.load()
        XCTAssertEqual(modelB.tags.first?.name, "B")
        XCTAssertTrue(b.server.requests.allSatisfy { $0.path == "list_conversation_tags" && $0.authorization == "Bearer B" })
        XCTAssertTrue(a.server.requests.allSatisfy { $0.authorization == "Bearer A" })
        XCTAssertEqual(modelA.conversationSummary?.tagIds, [1, 900])
    }

    func testScopeUsesActualAncestryAndHiddenChatOffersGlobals() async throws {
        let fixture = ConversationTagTestFixture(label: "scope")
        defer { fixture.close() }
        fixture.server.setTags([
            ConversationTagTestServer.tag(1, folder: nil, name: "Global"),
            ConversationTagTestServer.tag(2, folder: 7, name: "Root"),
            ConversationTagTestServer.tag(3, folder: 8, name: "Other same path"),
            ConversationTagTestServer.tag(4, folder: 9, name: "Child must not own"),
            ConversationTagTestServer.tag(5, folder: 99, name: "Surviving worktree family")
        ])
        let folders = [folder(7), folder(8), folder(9, parent: 7), folder(10, parent: 9),
                       folder(11, parent: 7, kind: .chat), folder(12, kind: .other),
                       folder(13, parent: 14), folder(14, parent: 13), folder(15, parent: 99)]
        let model = ConversationTagsModel(client: fixture.client, folders: folders)
        await model.load()
        for id in [7, 9, 10] { XCTAssertEqual(model.availableTags(folderID: id, folders: folders).map(\.id), [1, 2]) }
        XCTAssertEqual(model.availableTags(folderID: 8).map(\.id), [1, 3])
        XCTAssertEqual(model.availableTags(folderID: 15).map(\.id), [1, 5])
        for id in [nil, 11, 12, 13, 99] as [Int?] {
            XCTAssertEqual(model.availableTags(folderID: id).map(\.id), [1])
        }
        let created = await model.create(name: "Nested", color: "#aabbcc", folderID: 10)
        XCTAssertEqual(created?.folderId, 7)
        XCTAssertEqual(fixture.server.bodies("create_conversation_tag").first?["folderId"] as? Int, 7)
        let refused = await model.create(name: "Chat", color: "#aabbcc", folderID: 11)
        XCTAssertNil(refused)
        XCTAssertEqual(fixture.server.bodies("create_conversation_tag").count, 1)
    }

    func testCreateScopeIncludesOneSurvivingWorktreeWhenRootIsAbsent() {
        let orphanA = folder(15, parent: 99), orphanB = folder(16, parent: 99)
        let invalid = [folder(11, kind: .chat), folder(12, kind: .other),
                       folder(13, parent: 14), folder(14, parent: 13)]
        let missing = [orphanB, orphanA] + invalid
        let scopes = ConversationTagsModel.creationScopes(folders: missing)
        XCTAssertEqual(scopes.map(\.id), [15])
        XCTAssertEqual(ConversationTagsModel.scopeFolderID(scopes[0].id, folders: missing), 99)
        XCTAssertEqual(ConversationTagsModel.creationScopes(folders: missing + [folder(99)]).map(\.id), [99])
        XCTAssertEqual(ConversationTagsModel.creationScopes(folders: [folder(7), folder(8, parent: 7)]).map(\.id), [7])
    }

    func testDelayedRetiredLoadAndMutationPublishNothingAndBRemainsUsable() async throws {
        let a = ConversationTagTestFixture(label: "retired-A"), b = ConversationTagTestFixture(label: "live-B")
        defer { a.close(); b.close() }
        a.server.setTags([ConversationTagTestServer.tag(1, folder: nil, name: "A")])
        b.server.setTags([ConversationTagTestServer.tag(1, folder: nil, name: "B")])
        let modelA = ConversationTagsModel(client: a.client), modelB = ConversationTagsModel(client: b.client)
        a.server.holdNext("list_conversation_tags")
        let pending = Task { await modelA.load() }
        try await a.waitForHeld("list_conversation_tags")
        await modelB.load()
        a.lifetime.invalidate()
        a.server.release("list_conversation_tags")
        await pending.value
        XCTAssertTrue(modelA.tags.isEmpty)
        XCTAssertNil(modelA.errorMessage)
        _ = await modelA.create(name: "Retired", color: "#123456")
        XCTAssertEqual(a.server.requests.count, 1)
        XCTAssertEqual(modelB.tags.first?.name, "B")

        b.server.holdNext("update_conversation_tags")
        let assignment = Task { await modelB.assign(conversationID: 42, add: [1]) }
        try await b.waitForHeld("update_conversation_tags")
        b.lifetime.invalidate()
        b.server.release("update_conversation_tags")
        let result = await assignment.value
        XCTAssertNil(result)
        XCTAssertNil(modelB.conversationSummary)
        XCTAssertFalse(modelB.isBusy)
        XCTAssertNil(modelB.errorMessage)
    }

    func testStaleRefreshCannotResurrectDeletedOrOverwrittenTag() async throws {
        let fixture = ConversationTagTestFixture(label: "stale")
        defer { fixture.close() }
        fixture.server.setTags([ConversationTagTestServer.tag(1, folder: nil, name: "Original")])
        let model = ConversationTagsModel(client: fixture.client)
        await model.load()
        fixture.server.holdNext("list_conversation_tags")
        let stale = Task { await model.load() }
        try await fixture.waitForHeld("list_conversation_tags")
        let changed = await model.update(tagID: 1, name: "Changed")
        XCTAssertEqual(changed?.name, "Changed")
        fixture.server.release("list_conversation_tags")
        await stale.value
        XCTAssertEqual(model.tags.first?.name, "Changed")

        fixture.server.holdNext("list_conversation_tags")
        let staleDelete = Task { await model.load() }
        try await fixture.waitForHeld("list_conversation_tags")
        let deleted = await model.delete(tagID: 1)
        XCTAssertTrue(deleted)
        fixture.server.release("list_conversation_tags")
        await staleDelete.value
        XCTAssertTrue(model.tags.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testLatestLoadWinsAndBusyGuardPreservesUnrelatedTags() async throws {
        let fixture = ConversationTagTestFixture(label: "sequence")
        defer { fixture.close() }
        let model = ConversationTagsModel(client: fixture.client, conversationID: 42)
        fixture.server.setTags([ConversationTagTestServer.tag(1, folder: nil, name: "Old")])
        fixture.server.holdNext("list_conversation_tags")
        let old = Task { await model.load() }
        try await fixture.waitForHeld("list_conversation_tags")
        fixture.server.setTags([ConversationTagTestServer.tag(1, folder: nil, name: "Newest")])
        await model.load()
        fixture.server.release("list_conversation_tags")
        await old.value
        XCTAssertEqual(model.tags.first?.name, "Newest")
        fixture.server.holdNext("update_conversation_tags")
        let add = Task { await model.assign(conversationID: 42, add: [1]) }
        try await fixture.waitForHeld("update_conversation_tags")
        XCTAssertTrue(model.isBusy)
        let ignored = await model.assign(conversationID: 42, remove: [1])
        XCTAssertNil(ignored)
        await model.load()
        XCTAssertEqual(fixture.server.bodies("list_conversation_tags").count, 2)
        XCTAssertEqual(fixture.server.bodies("update_conversation_tags").count, 1)
        fixture.server.release("update_conversation_tags")
        let added = await add.value
        XCTAssertEqual(added?.tagIds, [1, 900])
        let removed = await model.assign(conversationID: 42, remove: [1])
        XCTAssertEqual(removed?.tagIds, [900])
        XCTAssertFalse(model.isBusy)
        let wrongConversation = await model.assign(conversationID: 99, add: [1])
        XCTAssertNil(wrongConversation)
        XCTAssertEqual(fixture.server.bodies("update_conversation_tags").count, 2)
        XCTAssertNotNil(model.errorMessage)
    }

    func testDelayedBranchReadCannotUndoSettingsMutation() async throws {
        let fixture = ConversationTagTestFixture(label: "branch-sequence")
        defer { fixture.close() }
        let model = ConversationTagsModel(client: fixture.client)
        fixture.server.holdNext("get_conversation_branch_tag")
        let stale = Task { await model.loadBranchSettings() }
        try await fixture.waitForHeld("get_conversation_branch_tag")
        let updated = await model.updateBranchSettings(enabled: false, color: "#abcdef")
        XCTAssertEqual(updated, ConversationBranchTag(enabled: false, color: "#abcdef"))
        fixture.server.release("get_conversation_branch_tag")
        await stale.value
        XCTAssertEqual(model.branchSettings, updated)
    }
}
