import Foundation
import XCTest
@testable import Codeg

@MainActor
final class ProjectIdentityWireTests: XCTestCase {
    func testSafeSnakeCaseResponseAndExactCamelCaseRequest() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let data = Data(#"[{"folder_id":7,"path":"/repo","status":"resolved","identity":{"project_key":"github:owner/repo","provider":"github","host":"github.com","repository_path":"owner/repo","remote_name":"upstream"}},{"folder_id":8,"path":"/plain","status":"resolved","identity":null},{"folder_id":9,"path":null,"status":"unavailable","identity":null}]"#.utf8)
        fixture.server.enqueue("list_repository_project_identities", WorktreeTestReply(data: data))
        let rows = try await fixture.client.listRepositoryProjectIdentities(folderIds: [7, 8, 9])
        XCTAssertEqual(rows[0].folderId, 7)
        XCTAssertEqual(rows[0].identity?.projectKey, "github:owner/repo")
        XCTAssertEqual(rows[0].identity?.repositoryPath, "owner/repo")
        XCTAssertEqual(rows[0].identity?.remoteName, "upstream")
        XCTAssertNil(rows[1].identity)
        XCTAssertEqual(rows[1].status, .resolved)
        XCTAssertNil(rows[2].path)
        XCTAssertEqual(rows[2].status, .unavailable)
        let body = try XCTUnwrap(fixture.server.bodies("list_repository_project_identities").first)
        XCTAssertEqual(Set(body.keys), ["folderIds"])
        XCTAssertEqual(body["folderIds"] as? [Int], [7, 8, 9])
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testEmptyBatchIsEmptyAndAuthenticationAndMalformedPayloadAreNotCapabilityAbsence() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.enqueue("list_repository_project_identities", WorktreeTestReply(data: Data("[]".utf8)))
        let empty = try await fixture.client.listRepositoryProjectIdentities(folderIds: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(fixture.server.bodies("list_repository_project_identities")[0]["folderIds"] as? [Int], [])
        fixture.server.enqueue("list_repository_project_identities", .failure(status: 401))
        do {
            _ = try await fixture.client.listRepositoryProjectIdentities(folderIds: [7])
            XCTFail("Authentication must fail")
        } catch APIError.unauthorized {} catch { XCTFail("Unexpected \(error)") }
        fixture.server.enqueue("list_repository_project_identities", WorktreeTestReply(data: Data("{}".utf8)))
        do {
            _ = try await fixture.client.listRepositoryProjectIdentities(folderIds: [7])
            XCTFail("Malformed response must fail")
        } catch APIError.decoding {} catch { XCTFail("Unexpected \(error)") }
    }

    func testRetiredReadAdapterCannotIssueAnIdentityRequest() async throws {
        let fixture = try WorktreeTestFixture(), lifetime = ServerBindingLifetime()
        defer { fixture.close() }
        let client = fixture.client.bound(to: lifetime)
        lifetime.invalidate()
        do {
            _ = try await client.listRepositoryProjectIdentities(folderIds: [7])
            XCTFail("Retired binding must reject the request")
        } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(fixture.server.count("list_repository_project_identities"), 0)
    }

    func testHeldConversationsDoNotBlockFolderCatalogOrDetailResolution() async throws {
        let fixture = try WorktreeTestFixture(), lifetime = ServerBindingLifetime()
        defer { fixture.close(); lifetime.invalidate() }
        let gate = WorktreeTestGate()
        fixture.server.enqueue("list_all_conversations", WorktreeTestReply(data: Data("[]".utf8), gate: gate))
        fixture.server.enqueue("list_open_folder_details", WorktreeTestReply(data: try WorktreeTestReply.json([WorktreeTestServer.folder("/repo", id: 7)])))
        fixture.server.enqueue("list_open_folder_details", WorktreeTestReply(data: try WorktreeTestReply.json([WorktreeTestServer.folder("/repo", id: 7)])))
        fixture.server.enqueue("list_repository_project_identities", WorktreeTestReply(data: Data(#"[{"folder_id":7,"path":"/repo","status":"resolved","identity":null}]"#.utf8)))
        let client = fixture.client.bound(to: lifetime), activity = ActivityModel()
        let held = Task { await activity.refresh(client: client) }
        defer { gate.release(); held.cancel() }
        for _ in 0..<1000 where !gate.hasRequest { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.hasRequest)
        let catalog = ProjectCatalogModel(client: client, lifetime: lifetime)
        await catalog.refresh()
        XCTAssertEqual(catalog.folder(id: 7)?.path, "/repo")
        XCTAssertEqual(catalog.setupFolders.count, 1)
        XCTAssertFalse(activity.hasLoadedConversations)
        XCTAssertTrue(activity.isRefreshing)
        gate.release()
        await held.value
        XCTAssertTrue(activity.hasLoadedConversations)
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testHistoryFailureIsNotAnEmptySuccessWhenFoldersSucceed() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.enqueue("list_open_folder_details", WorktreeTestReply(data: Data("[]".utf8)))
        fixture.server.enqueue("list_all_conversations", .failure(status: 401))
        let activity = ActivityModel()
        await activity.refresh(client: fixture.client)
        XCTAssertTrue(activity.hasLoaded)
        XCTAssertFalse(activity.hasLoadedConversations)
        XCTAssertNotNil(activity.conversationsError)
        fixture.server.enqueue("list_open_folder_details", WorktreeTestReply(data: Data("[]".utf8)))
        await activity.refresh(client: fixture.client)
        XCTAssertTrue(activity.hasLoadedConversations)
        XCTAssertNil(activity.conversationsError)
    }
}
