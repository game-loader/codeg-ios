import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Codeg

@MainActor
final class WorktreeManagementTests: XCTestCase {
    private func entry(_ path: String, in model: WorktreeListViewModel) throws -> GitWorktreeInfo {
        try XCTUnwrap(model.worktrees.first { $0.path == path })
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
        if !predicate() { throw URLError(.timedOut) }
    }

    func testEqualFolderIDsAndPathsOnTwoHostsRemainIndependent() async throws {
        let a = try WorktreeTestFixture(), b = try WorktreeTestFixture()
        defer { a.close(); b.close() }
        XCTAssertEqual(a.folder.id, b.folder.id)
        XCTAssertEqual(a.folder.path, b.folder.path)
        var opened: [String] = []
        let modelA = WorktreeListViewModel(client: a.client, folder: a.folder, serverName: "A",
                                          onOpenFolder: { opened.append("A:\($0.path)") })
        let modelB = WorktreeListViewModel(client: b.client, folder: b.folder, serverName: "B",
                                          onOpenFolder: { opened.append("B:\($0.path)") })
        await modelA.load()
        await modelB.load()
        await modelA.open(try entry("/linked", in: modelA))
        XCTAssertEqual(a.server.count("open_worktree_folder"), 1)
        XCTAssertEqual(b.server.count("open_worktree_folder"), 0)
        modelA.requestRemoval(try entry("/linked", in: modelA))
        await modelA.confirmRemoval()
        XCTAssertNil(modelA.worktrees.first { $0.path == "/linked" })
        XCTAssertNotNil(modelB.worktrees.first { $0.path == "/linked" })
        await modelB.open(try entry("/linked", in: modelB))
        XCTAssertEqual(opened, ["A:/linked", "B:/linked"])
        XCTAssertEqual(a.server.count("git_remove_worktree_path"), 1)
        XCTAssertEqual(b.server.count("git_remove_worktree_path"), 0)
        XCTAssertTrue(a.server.unexpected.isEmpty && b.server.unexpected.isEmpty)
    }

    func testPartialCreationRetriesRegistrationOnlyAndUsesRootOfInitiatingChild() async throws {
        let a = try WorktreeTestFixture(), b = try WorktreeTestFixture()
        defer { a.close(); b.close() }
        let child = FolderDetail(id: 8, name: "child", path: "/linked", gitBranch: "topic", defaultAgentType: nil,
                                 lastOpenedAt: Date(), sortOrder: 0, color: "", parentId: 7)
        var opened: [FolderDetail] = []
        let model = WorktreeListViewModel(client: a.client, folder: child, onOpenFolder: { opened.append($0) })
        await model.load()
        a.server.enqueue("open_worktree_folder", .failure(message: "Database registration failed"))
        await model.create(branchName: " feature/new ", worktreePath: " /new ", base: " ")
        XCTAssertEqual(model.pendingRegistration?.path, "/new")
        XCTAssertNotNil(model.worktrees.first { $0.path == "/new" })
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(model.canCreate)
        await model.create(branchName: "feature/new", worktreePath: "/new")
        XCTAssertEqual(a.server.count("git_worktree_add"), 1)
        await model.retryRegistration()
        XCTAssertNil(model.pendingRegistration)
        XCTAssertEqual(opened.first?.path, "/new")
        XCTAssertEqual(opened.first?.parentId, 7)
        XCTAssertEqual(a.server.count("git_worktree_add"), 1)
        XCTAssertEqual(a.server.count("open_worktree_folder"), 2)
        XCTAssertEqual(a.server.bodies("git_worktree_add")[0]["path"] as? String, "/linked")
        XCTAssertEqual(a.server.bodies("git_worktree_add")[0]["branchName"] as? String, "feature/new")
        XCTAssertNil(a.server.bodies("git_worktree_add")[0]["base"])
        XCTAssertTrue(a.server.bodies("open_worktree_folder").allSatisfy { $0["sourceFolderId"] as? Int == 7 })
        XCTAssertEqual(b.server.count("git_worktree_add"), 0)
        XCTAssertEqual(b.server.count("open_worktree_folder"), 0)
    }

    func testOpeningDetachedUnregisteredCheckoutDoesNotCreateAndMainUsesOpenFolder() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true),
                                     WorktreeTestServer.entry("/detached", branch: nil, detached: true)])
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        await model.open(try entry("/detached", in: model))
        let registered = try XCTUnwrap(fixture.server.bodies("open_worktree_folder").first)
        XCTAssertEqual(Set(registered.keys), ["path", "sourceFolderId"])
        XCTAssertEqual(registered["path"] as? String, "/detached")
        XCTAssertEqual(registered["sourceFolderId"] as? Int, 7)
        await model.open(try entry("/detached", in: model))
        await model.open(try entry("/repo", in: model))
        XCTAssertEqual(fixture.server.count("open_folder"), 2)
        XCTAssertEqual(fixture.server.count("open_worktree_folder"), 1)
        XCTAssertEqual(fixture.server.count("git_worktree_add"), 0)
    }

    func testMainCurrentBareAndEmptyReasonLockedCheckoutsCannotBeRemovedEvenWithForce() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true), WorktreeTestServer.entry("/linked"),
                                     WorktreeTestServer.entry("/bare", branch: nil, bare: true),
                                     WorktreeTestServer.entry("/locked", locked: "")])
        let child = FolderDetail(id: 8, name: "child", path: "/linked", gitBranch: "topic", defaultAgentType: nil,
                                 lastOpenedAt: Date(), sortOrder: 0, color: "", parentId: 7)
        let model = WorktreeListViewModel(client: fixture.client, folder: child)
        await model.load()
        for path in ["/repo", "/linked", "/bare", "/locked"] {
            let worktree = try entry(path, in: model)
            XCTAssertFalse(model.canRemove(worktree))
            model.requestRemoval(worktree)
            XCTAssertNil(model.removalConfirmation)
            await model.confirmRemoval(deleteBranch: true, force: true)
        }
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 0)
        XCTAssertFalse(model.canOpen(try entry("/bare", in: model)))
    }

    func testPartialRemovalReloadsAndBranchCleanupNeverRepeatsCheckoutRemoval() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        var changes = 0
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder, onFoldersChanged: { changes += 1 })
        await model.load()
        fixture.server.enqueue("git_remove_worktree_path", .failure(message: "Branch is not merged", removedPath: "/linked"))
        model.requestRemoval(try entry("/linked", in: model))
        await model.confirmRemoval(deleteBranch: true)
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 2)
        XCTAssertNil(model.worktrees.first { $0.path == "/linked" })
        XCTAssertEqual(model.branchRecovery, WorktreeBranchRecovery(worktreePath: "/linked", branchName: "topic"))
        XCTAssertEqual(changes, 1)
        await model.confirmBranchCleanup(force: true)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0, "A separate confirmation is required")
        fixture.server.enqueue("git_delete_branch", .failure(message: "Branch is not merged"))
        model.requestBranchCleanup()
        await model.confirmBranchCleanup()
        XCTAssertNotNil(model.branchRecovery)
        XCTAssertFalse(model.isConfirmingBranchCleanup)
        model.requestBranchCleanup()
        await model.confirmBranchCleanup(force: true)
        XCTAssertNil(model.branchRecovery)
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        let bodies = fixture.server.bodies("git_delete_branch")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["force"] as? Bool, false)
        XCTAssertEqual(bodies[1]["force"] as? Bool, true)
        XCTAssertTrue(bodies.allSatisfy { $0["path"] as? String == "/repo" && $0["branchName"] as? String == "topic" })
    }

    func testForceRemovalRequiresFreshExplicitTargetConfirmation() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        await model.confirmRemoval(force: true)
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 0)
        fixture.server.enqueue("git_remove_worktree_path", .failure(message: "Checkout has modified files"))
        model.requestRemoval(try entry("/linked", in: model))
        await model.confirmRemoval()
        XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" })
        XCTAssertNil(model.branchRecovery)
        XCTAssertNil(model.removalConfirmation)
        await model.confirmRemoval(force: true)
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        model.requestRemoval(try entry("/linked", in: model))
        XCTAssertEqual(model.removalConfirmation?.worktree.path, "/linked")
        await model.confirmRemoval(force: true)
        let bodies = fixture.server.bodies("git_remove_worktree_path")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["force"] as? Bool, false)
        XCTAssertEqual(bodies[1]["force"] as? Bool, true)
    }

    func testBackendBusyGuardIsSurfacedAndCannotTriggerAutomaticForceOrBranchCleanup() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        fixture.server.enqueue("git_remove_worktree_path", .failure(status: 422, code: "invalid_input", message: "A to-do task is still working in this worktree"))
        model.requestRemoval(try entry("/linked", in: model))
        await model.confirmRemoval(deleteBranch: true, force: true)
        XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" })
        XCTAssertNil(model.branchRecovery)
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
        guard case .failure(let message) = model.issue else { return XCTFail("Expected the backend busy error") }
        XCTAssertTrue(message.contains("to-do task"))
    }

    func testFailedReloadIsNotProofOfPartialRemoval() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        fixture.server.enqueue("git_remove_worktree_path", .failure(removedPath: "/linked"))
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet)))
        model.requestRemoval(try entry("/linked", in: model))
        await model.confirmRemoval(deleteBranch: true)
        XCTAssertNil(model.branchRecovery)
        XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" }, "Keep the last known inventory")
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
    }

    func testPartialRemovalFailedReloadThenRefreshOffersRemainingBranchCleanup() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder, serverName: "Initiating server")
        await model.load()
        fixture.server.enqueue("git_remove_worktree_path", .failure(message: "Branch is not merged", removedPath: "/linked"))
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet)))
        model.requestRemoval(try entry("/linked", in: model))
        await model.confirmRemoval(deleteBranch: true)
        XCTAssertNil(model.branchRecovery, "A failed inventory read cannot prove checkout removal")
        XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" })
        XCTAssertNotNil(model.issue)
        XCTAssertNil(model.removalConfirmation)
        XCTAssertFalse(model.canCreate, "Keep the unresolved cleanup target until inventory can reconcile it")
        let cached = try entry("/linked", in: model)
        XCTAssertFalse(model.canRemove(cached))
        model.requestRemoval(cached)
        await model.confirmRemoval(force: true)
        XCTAssertNil(model.removalConfirmation)
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 2)
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)

        await model.load()
        let recovery = WorktreeBranchRecovery(worktreePath: "/linked", branchName: "topic")
        XCTAssertNil(model.worktrees.first { $0.path == "/linked" })
        XCTAssertNil(model.issue)
        XCTAssertTrue(model.allowsPresentation)
        XCTAssertEqual(model.branchRecovery, recovery, "The existing view renders its cleanup controls from this value")
        XCTAssertEqual(model.sourceFolder, fixture.folder)
        XCTAssertEqual(model.serverName, "Initiating server")
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 3)
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
        await model.confirmBranchCleanup(force: true)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0, "Cleanup needs its own explicit confirmation")

        fixture.server.enqueue("git_delete_branch", .failure(message: "Branch is not merged"))
        model.requestBranchCleanup()
        XCTAssertTrue(model.isConfirmingBranchCleanup)
        await model.confirmBranchCleanup()
        XCTAssertEqual(model.branchRecovery, recovery)
        XCTAssertFalse(model.isConfirmingBranchCleanup)
        await model.confirmBranchCleanup(force: true)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 1, "A failed cleanup cannot retry itself")
        model.requestBranchCleanup()
        await model.confirmBranchCleanup()
        XCTAssertNil(model.branchRecovery)
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        let cleanups = fixture.server.bodies("git_delete_branch")
        XCTAssertEqual(cleanups.count, 2)
        for body in cleanups {
            XCTAssertEqual(Set(body.keys), ["path", "branchName", "force"])
            XCTAssertEqual(body["path"] as? String, "/repo")
            XCTAssertEqual(body["branchName"] as? String, "topic")
            XCTAssertEqual(body["force"] as? Bool, false)
        }
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testFailedRemovalLateInventoryStillContainsCheckoutClearsCleanupIntent() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        fixture.server.enqueue("git_remove_worktree_path", .failure(message: "Checkout has modified files"))
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet)))
        model.requestRemoval(try entry("/linked", in: model))
        await model.confirmRemoval(deleteBranch: true)
        XCTAssertNil(model.branchRecovery)

        fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true),
                                     WorktreeTestServer.entry("/linked", branch: "replacement")])
        await model.load()
        XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" })
        XCTAssertNil(model.branchRecovery)
        XCTAssertNil(model.issue)
        XCTAssertTrue(model.canRemove(try entry("/linked", in: model)))
        XCTAssertTrue(model.canCreate)
        model.requestBranchCleanup()
        await model.confirmBranchCleanup(force: true)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)

        // Unrelated later removal must not revive the resolved failed intent.
        fixture.server.setInventory([WorktreeTestServer.entry("/repo", branch: "main", main: true)])
        await model.load()
        XCTAssertNil(model.branchRecovery)
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
    }

    func testFailedRemovalLateAbsenceRequiresSelectedKnownAttachedBranch() async throws {
        for (deleteBranch, branch, detached) in [(false, Optional("topic"), false), (true, nil, false), (true, "topic", true)] {
            let fixture = try WorktreeTestFixture()
            defer { fixture.close() }
            fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true),
                                         WorktreeTestServer.entry("/linked", branch: branch, detached: detached)])
            let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
            await model.load()
            fixture.server.enqueue("git_remove_worktree_path", .failure(removedPath: "/linked"))
            fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet)))
            model.requestRemoval(try entry("/linked", in: model))
            await model.confirmRemoval(deleteBranch: deleteBranch)
            await model.load()
            XCTAssertNil(model.worktrees.first { $0.path == "/linked" })
            XCTAssertNil(model.branchRecovery)
            XCTAssertEqual(fixture.server.bodies("git_remove_worktree_path")[0]["deleteBranch"] as? Bool, false)
            model.requestBranchCleanup()
            await model.confirmBranchCleanup(force: true)
            XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
            XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
        }
    }

    func testRemovalResponseFailedReloadReconcilesOnlyUndeletedSelectedBranch() async throws {
        for branchDeleted in [false, true] {
            let fixture = try WorktreeTestFixture()
            defer { fixture.close() }
            let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
            await model.load()
            fixture.server.enqueue("git_remove_worktree_path", WorktreeTestReply(data: try WorktreeTestReply.json([
                "worktree_path": "/linked", "branch_deleted": branchDeleted, "folder_id": 8, "reparented": 2
            ]), removedPath: "/linked"))
            fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet)))
            model.requestRemoval(try entry("/linked", in: model))
            await model.confirmRemoval(deleteBranch: true)
            XCTAssertNil(model.branchRecovery)
            XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" })
            await model.load()
            XCTAssertNil(model.worktrees.first { $0.path == "/linked" })
            XCTAssertEqual(model.branchRecovery, branchDeleted ? nil : WorktreeBranchRecovery(worktreePath: "/linked", branchName: "topic"))
            XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
            XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
        }
    }

    func testSupersededRemovalInventoryCannotPromoteBranchCleanup() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        fixture.server.enqueue("git_remove_worktree_path", .failure(removedPath: "/linked"))
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet)))
        model.requestRemoval(try entry("/linked", in: model))
        await model.confirmRemoval(deleteBranch: true)
        let gate = WorktreeTestGate()
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(
            data: try WorktreeTestReply.json([WorktreeTestServer.entry("/repo", main: true)]), gate: gate))
        let old = Task { await model.load() }
        defer { gate.release() }
        try await eventually { gate.hasRequest }
        fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true), WorktreeTestServer.entry("/linked")])
        await model.load()
        await old.value
        gate.release()
        XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" })
        XCTAssertNil(model.branchRecovery)
        XCTAssertNil(model.issue)

        fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true)])
        await model.load()
        XCTAssertNil(model.branchRecovery, "Only the accepted inventory may resolve a pending removal")
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
    }

    func testSuspendedRemovalInventoryNeedsFreshLoadBeforePromotingBranchCleanup() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        fixture.server.enqueue("git_remove_worktree_path", .failure(removedPath: "/linked"))
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet)))
        model.requestRemoval(try entry("/linked", in: model))
        await model.confirmRemoval(deleteBranch: true)
        let gate = WorktreeTestGate()
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(
            data: try WorktreeTestReply.json([WorktreeTestServer.entry("/repo", main: true)]), gate: gate))
        let old = Task { await model.load() }
        defer { gate.release() }
        try await eventually { gate.hasRequest }
        model.suspendPresentation()
        await old.value
        gate.release()
        XCTAssertNil(model.branchRecovery)
        XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" })
        await model.load()
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 3)
        model.resumePresentation()
        await model.load()
        XCTAssertEqual(model.branchRecovery, WorktreeBranchRecovery(worktreePath: "/linked", branchName: "topic"))
        XCTAssertNil(model.worktrees.first { $0.path == "/linked" })
        XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
    }

    func testRetiredRemovalInventoryCannotPromoteBranchCleanup() async throws {
        for retirement in 0..<3 {
            let fixture = try WorktreeTestFixture()
            defer { fixture.close() }
            let lifetime = ServerBindingLifetime()
            var current = true
            var changes = 0
            let model = WorktreeListViewModel(client: fixture.client.bound(to: lifetime), folder: fixture.folder,
                                             isCurrent: { current }, onFoldersChanged: { changes += 1 })
            await model.load()
            fixture.server.enqueue("git_remove_worktree_path", .failure(removedPath: "/linked"))
            fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet)))
            model.requestRemoval(try entry("/linked", in: model))
            await model.confirmRemoval(deleteBranch: true)
            XCTAssertEqual(changes, 1)
            let gate = WorktreeTestGate()
            fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(
                data: try WorktreeTestReply.json([WorktreeTestServer.entry("/repo", main: true)]), gate: gate))
            let loading = Task { await model.load() }
            defer { gate.release() }
            try await eventually { gate.hasRequest }
            switch retirement {
            case 0: lifetime.invalidate()
            case 1:
                model.invalidate()
                // Drain cancellation before releasing a held URLProtocol
                // response, so cancellation and success cannot race delivery.
                await loading.value
            default: current = false
            }
            gate.release()
            await loading.value
            XCTAssertNil(model.branchRecovery)
            XCTAssertNotNil(model.worktrees.first { $0.path == "/linked" })
            XCTAssertFalse(model.allowsPresentation)
            XCTAssertEqual(changes, 1)
            model.resumePresentation()
            await model.load()
            model.requestBranchCleanup()
            await model.confirmBranchCleanup(force: true)
            XCTAssertEqual(fixture.server.count("git_list_worktrees"), 3)
            XCTAssertEqual(fixture.server.count("git_remove_worktree_path"), 1)
            XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
        }
    }

    func testDetachedRemovalNeverRequestsBranchDeletion() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true),
                                     WorktreeTestServer.entry("/detached", branch: nil, detached: true)])
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        model.requestRemoval(try entry("/detached", in: model))
        await model.confirmRemoval(deleteBranch: true)
        XCTAssertEqual(fixture.server.bodies("git_remove_worktree_path")[0]["deleteBranch"] as? Bool, false)
        XCTAssertNil(model.branchRecovery)
        XCTAssertEqual(fixture.server.count("git_delete_branch"), 0)
    }

    func testAuthAndOfflineFailuresStayOnInitiatingHostForReadsAndRegistration() async throws {
        for reply in [WorktreeTestReply.failure(status: 401, code: nil, message: "Unauthorized"),
                      WorktreeTestReply(data: Data(), error: URLError(.notConnectedToInternet))] {
            let a = try WorktreeTestFixture(), b = try WorktreeTestFixture()
            defer { a.close(); b.close() }
            let modelA = WorktreeListViewModel(client: a.client, folder: a.folder)
            let modelB = WorktreeListViewModel(client: b.client, folder: b.folder)
            a.server.enqueue("git_list_worktrees", reply)
            await modelA.load()
            await modelB.load()
            XCTAssertNotNil(modelA.issue)
            XCTAssertNotEqual(modelA.issue, .upgradeRequired)
            XCTAssertFalse(modelA.canCreate)
            XCTAssertNil(modelB.issue)
            await modelA.load()
            a.server.enqueue("open_worktree_folder", reply)
            await modelA.open(try entry("/linked", in: modelA))
            XCTAssertNotNil(modelA.issue)
            XCTAssertEqual(a.server.count("open_worktree_folder"), 1)
            XCTAssertEqual(b.server.count("open_worktree_folder"), 0)
            XCTAssertEqual(b.server.count("git_worktree_add"), 0)
            XCTAssertEqual(b.server.count("git_list_worktrees"), 1)
        }
    }

    func testRetiredEndpointAfterGitAddCannotRegisterOrPresentOnAnotherHost() async throws {
        let a = try WorktreeTestFixture(), b = try WorktreeTestFixture()
        defer { a.close(); b.close() }
        var current = true
        var callbacks = 0
        let modelA = WorktreeListViewModel(client: a.client, folder: a.folder, isCurrent: { current },
                                          onOpenFolder: { _ in callbacks += 1 }, onFoldersChanged: { callbacks += 1 })
        await modelA.load()
        let gate = WorktreeTestGate()
        a.server.enqueue("git_worktree_add", WorktreeTestReply(data: Data("null".utf8), gate: gate))
        let creation = Task { await modelA.create(branchName: "new", worktreePath: "/new") }
        try await eventually { gate.hasRequest }
        current = false
        let modelB = WorktreeListViewModel(client: b.client, folder: b.folder)
        await modelB.load()
        gate.release()
        await creation.value
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(a.server.count("git_worktree_add"), 1)
        XCTAssertEqual(a.server.count("open_worktree_folder"), 0)
        XCTAssertEqual(b.server.count("git_worktree_add"), 0)
        XCTAssertEqual(b.server.count("open_worktree_folder"), 0)
    }

    func testInvalidationSuppressesLateRegistrationCallbacksAndFollowupLoad() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        var callbacks = 0
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder,
                                         onOpenFolder: { _ in callbacks += 1 }, onFoldersChanged: { callbacks += 1 })
        await model.load()
        let gate = WorktreeTestGate()
        fixture.server.enqueue("open_worktree_folder", WorktreeTestReply(
            data: try WorktreeTestReply.json(WorktreeTestServer.folder("/linked", parent: 7)), gate: gate))
        let target = try entry("/linked", in: model)
        let opening = Task { await model.open(target) }
        try await eventually { gate.hasRequest }
        model.invalidate()
        gate.release()
        await opening.value
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 1)
        XCTAssertFalse(model.canCreate)
        XCTAssertFalse(model.isMutating)
    }

    func testSupersededInventoryCannotOverwriteNewerLoad() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        let gate = WorktreeTestGate()
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(
            data: try WorktreeTestReply.json([WorktreeTestServer.entry("/stale")]), gate: gate))
        let old = Task { await model.load() }
        try await eventually { gate.hasRequest }
        fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true), WorktreeTestServer.entry("/fresh")])
        await model.load()
        gate.release()
        await old.value
        XCTAssertEqual(model.worktrees.map(\.path), ["/repo", "/fresh"])
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(fixture.server.count("list_all_folder_details"), 1)
    }

    func testInvalidatedInventoryDoesNotPublishOrLoadFolders() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        let gate = WorktreeTestGate()
        fixture.server.enqueue("git_list_worktrees", WorktreeTestReply(
            data: try WorktreeTestReply.json([WorktreeTestServer.entry("/repo", main: true)]), gate: gate))
        let loading = Task { await model.load() }
        try await eventually { gate.hasRequest }
        model.invalidate()
        gate.release()
        await loading.value
        XCTAssertTrue(model.worktrees.isEmpty)
        XCTAssertFalse(model.hasInventory)
        XCTAssertEqual(fixture.server.count("list_all_folder_details"), 0)
    }

    func testLegacyServerShowsUpgradeWithoutReplacingInitiatingFolder() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.enqueue("git_list_worktrees", .failure(status: 404, code: nil, message: "Not Found"))
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder, serverName: "Old server")
        await model.load()
        XCTAssertEqual(model.issue, .upgradeRequired)
        XCTAssertEqual(model.sourceFolder, fixture.folder)
        XCTAssertEqual(model.serverName, "Old server")
        XCTAssertFalse(model.canCreate)
        await model.create(branchName: "new", worktreePath: "/new")
        XCTAssertEqual(fixture.server.count("git_worktree_add"), 0)
    }

    func testCreationRequiresBranchAndAbsoluteServerPathBeforeSendingGit() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        await model.create(branchName: " ", worktreePath: "/new")
        await model.create(branchName: "new", worktreePath: "relative/new")
        XCTAssertEqual(model.issue, .invalidInput)
        XCTAssertEqual(fixture.server.count("git_worktree_add"), 0)
    }

    func testStandaloneRegisteredCheckoutUsesActualRepositoryRootForNewRegistration() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        // An existing linked checkout registered through Open Folder has no
        // parent metadata. Git inventory still identifies the real repo root.
        let standalone = FolderDetail(id: 8, name: "standalone", path: "/linked", gitBranch: "topic", defaultAgentType: nil,
                                      lastOpenedAt: Date(), sortOrder: 0, color: "")
        let model = WorktreeListViewModel(client: fixture.client, folder: standalone)
        await model.load()
        await model.create(branchName: "new", worktreePath: "/new", base: " origin/main ")
        XCTAssertEqual(fixture.server.bodies("open_worktree_folder")[0]["sourceFolderId"] as? Int, 7)
        XCTAssertEqual(fixture.server.bodies("git_worktree_add")[0]["base"] as? String, "origin/main")
    }

    func testMissingRootCanBeOpenedBeforeRegisteringLinkedCheckout() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let standalone = FolderDetail(id: 8, name: "standalone", path: "/linked", gitBranch: "topic", defaultAgentType: nil,
                                      lastOpenedAt: Date(), sortOrder: 0, color: "")
        fixture.server.setFolders([WorktreeTestServer.folder("/linked", id: 8)])
        let model = WorktreeListViewModel(client: fixture.client, folder: standalone)
        await model.load()
        await model.create(branchName: "new", worktreePath: "/new")
        XCTAssertEqual(model.issue, .rootFolderUnavailable)
        XCTAssertEqual(fixture.server.count("git_worktree_add"), 0)
        await model.open(try entry("/repo", in: model))
        XCTAssertEqual(fixture.server.count("open_folder"), 1)
        await model.create(branchName: "new", worktreePath: "/new")
        XCTAssertNil(model.pendingRegistration)
        XCTAssertEqual(fixture.server.count("git_worktree_add"), 1)
        XCTAssertEqual(fixture.server.bodies("open_worktree_folder")[0]["sourceFolderId"] as? Int, 7)
    }

    func testPresentationCanResumeAfterNavigationWithoutRevivingRetiredModel() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder)
        await model.load()
        model.suspendPresentation()
        XCTAssertFalse(model.canCreate)
        await model.load()
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 1)
        model.resumePresentation()
        await model.load()
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 2)
        model.invalidate()
        model.resumePresentation()
        await model.load()
        XCTAssertFalse(model.canCreate)
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 2)
    }

    func testBoundEndpointRetirementSuppressesPresentationWithoutCustomClosure() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let lifetime = ServerBindingLifetime()
        var callbacks = 0
        let model = WorktreeListViewModel(client: fixture.client.bound(to: lifetime), folder: fixture.folder,
                                         onOpenFolder: { _ in callbacks += 1 }, onFoldersChanged: { callbacks += 1 })
        await model.load()
        let gate = WorktreeTestGate()
        fixture.server.enqueue("open_worktree_folder", WorktreeTestReply(
            data: try WorktreeTestReply.json(WorktreeTestServer.folder("/linked", parent: 7)), gate: gate))
        let target = try entry("/linked", in: model)
        let opening = Task { await model.open(target) }
        try await eventually { gate.hasRequest }
        lifetime.invalidate()
        gate.release()
        await opening.value
        XCTAssertEqual(callbacks, 0)
        XCTAssertNil(model.issue)
        XCTAssertFalse(model.canCreate)
        XCTAssertEqual(fixture.server.count("git_list_worktrees"), 1)
    }

    func testCreationCompletingAfterNavigationRetainsPathAndRequiresRegistrationRetry() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        var callbacks = 0
        let model = WorktreeListViewModel(client: fixture.client, folder: fixture.folder,
                                         onOpenFolder: { _ in callbacks += 1 })
        await model.load()
        let gate = WorktreeTestGate()
        fixture.server.enqueue("git_worktree_add", WorktreeTestReply(data: Data("null".utf8), gate: gate))
        let creating = Task { await model.create(branchName: "new", worktreePath: "/new") }
        try await eventually { gate.hasRequest }
        model.suspendPresentation()
        model.resumePresentation()
        await model.load() // The mutation still owns the operation gate.
        fixture.server.setInventory([WorktreeTestServer.entry("/repo", main: true),
                                     WorktreeTestServer.entry("/linked"), WorktreeTestServer.entry("/new", branch: "new")])
        gate.release()
        await creating.value
        try await eventually { fixture.server.count("git_list_worktrees") == 2 && !model.isLoading }
        XCTAssertEqual(model.pendingRegistration?.path, "/new")
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(fixture.server.count("open_worktree_folder"), 0)
        await model.retryRegistration()
        XCTAssertNil(model.pendingRegistration)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(fixture.server.count("git_worktree_add"), 1)
        XCTAssertEqual(fixture.server.count("open_worktree_folder"), 1)
    }
}
