import Foundation
import XCTest
@testable import Codeg

/// Model-only coverage: creating these runtimes never starts a PTY or HTTP task.
@MainActor
final class ProjectRuntimeRetentionTests: XCTestCase {
    private func client(_ lifetime: ServerBindingLifetime? = nil, host: String = "a") -> CodegClient {
        CodegClient(baseURL: URL(string: "https://\(host).invalid")!, token: "fixture",
                    bindingLifetime: lifetime)
    }

    private func folder(id: Int = 7, path: String = "/project", parentID: Int? = nil) -> FolderDetail {
        FolderDetail(id: id, name: "Project", path: path, gitBranch: nil, defaultAgentType: nil,
                     lastOpenedAt: Date(), sortOrder: 0, color: "", parentId: parentID)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "MainActor retirement did not finish")
    }

    func testReconstructionAfterDroppingViewOwnerRetainsModelsAndTab() async throws {
        let cache = ProjectWorkspaceCache()
        let lifetime = ServerBindingLifetime()
        defer { lifetime.invalidate() }
        let bound = client(lifetime)
        var viewOwner: ProjectRuntime? = try XCTUnwrap(cache.runtime(client: bound, folder: folder()))
        weak var retained = viewOwner
        let git = try XCTUnwrap(viewOwner?.git)
        let terminal = try XCTUnwrap(viewOwner?.terminal)
        let emulator = terminal.view
        viewOwner?.tab = .terminal
        viewOwner?.showCommit = true
        git.pushAfterCommitDismiss = true
        // Model the old navigation/split shell disappearing before its successor.
        viewOwner = nil
        XCTAssertNil(viewOwner)
        let restored = try XCTUnwrap(cache.runtime(client: bound, folder: folder()))
        XCTAssertTrue(restored === retained)
        XCTAssertTrue(restored.git === git)
        XCTAssertTrue(restored.terminal === terminal)
        XCTAssertTrue(restored.terminal.view === emulator)
        XCTAssertEqual(restored.tab, .terminal)
        XCTAssertTrue(restored.showCommit)
        XCTAssertTrue(restored.git.pushAfterCommitDismiss)
        XCTAssertEqual(restored.terminal.phase, .idle)
    }

    func testEqualFolderIDsAndPathsOnABRetainIndependentFixedClients() async throws {
        let cache = ProjectWorkspaceCache()
        let a = ServerBindingLifetime(), b = ServerBindingLifetime()
        defer { a.invalidate(); b.invalidate() }
        let first = try XCTUnwrap(cache.runtime(client: client(a), folder: folder()))
        let second = try XCTUnwrap(cache.runtime(client: client(b, host: "b"), folder: folder()))
        first.tab = .terminal
        first.git.pushAfterCommitDismiss = true
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.git === second.git)
        XCTAssertFalse(first.terminal === second.terminal)
        XCTAssertFalse(first.terminal.view === second.terminal.view)
        XCTAssertTrue(first.git.client.bindingLifetime === a)
        XCTAssertTrue(second.git.client.bindingLifetime === b)
        XCTAssertEqual(second.tab, .files)
        XCTAssertFalse(second.git.pushAfterCommitDismiss)
        // Switching B -> A only resolves each host's original runtime.
        XCTAssertTrue(cache.runtime(client: client(b, host: "b"), folder: folder()) === second)
        XCTAssertTrue(cache.runtime(client: client(a), folder: folder()) === first)
    }

    func testFoldersPathsAndWorktreesHaveIndependentRuntimes() async throws {
        let cache = ProjectWorkspaceCache()
        let lifetime = ServerBindingLifetime()
        defer { lifetime.invalidate() }
        let bound = client(lifetime)
        let root = try XCTUnwrap(cache.runtime(client: bound, folder: folder()))
        let moved = try XCTUnwrap(cache.runtime(client: bound, folder: folder(path: "/moved")))
        let otherID = try XCTUnwrap(cache.runtime(client: bound, folder: folder(id: 8)))
        let worktree = try XCTUnwrap(cache.runtime(client: bound, folder: folder(id: 9, path: "/linked", parentID: 7)))
        XCTAssertFalse(root === moved)
        XCTAssertFalse(root === otherID)
        XCTAssertFalse(root === worktree)
        XCTAssertEqual(moved.git.rootPath, "/moved")
        XCTAssertEqual(worktree.git.rootPath, "/linked")
        XCTAssertEqual(worktree.git.folderId, 9)
        XCTAssertTrue(cache.runtime(client: bound, folder: folder()) === root)
    }

    func testBackgroundRetirementReleasesAbsentViewsOnlyForRetiredGeneration() async throws {
        let cache = ProjectWorkspaceCache()
        let a = ServerBindingLifetime(), b = ServerBindingLifetime()
        defer { b.invalidate() }
        var viewA: ProjectRuntime? = try XCTUnwrap(cache.runtime(client: client(a), folder: folder()))
        weak var old = viewA
        weak var oldGit = viewA?.git
        weak var oldTerminal = viewA?.terminal
        viewA = nil
        XCTAssertNotNil(old)
        let survivor = try XCTUnwrap(cache.runtime(client: client(b), folder: folder()))
        survivor.tab = .terminal
        await Task.detached { a.invalidate(); a.invalidate() }.value
        await waitUntil { old == nil && oldGit == nil && oldTerminal == nil }
        XCTAssertNil(cache.runtime(client: client(a), folder: folder()))
        XCTAssertTrue(cache.runtime(client: client(b), folder: folder()) === survivor)
        XCTAssertEqual(survivor.tab, .terminal)
        XCTAssertEqual(survivor.terminal.phase, .idle)
    }

    func testRetirementStopsStillReferencedTerminalAndCannotRestartIt() async throws {
        let cache = ProjectWorkspaceCache()
        let lifetime = ServerBindingLifetime()
        let runtime = try XCTUnwrap(cache.runtime(client: client(lifetime), folder: folder()))
        runtime.git.pushAfterCommitDismiss = true
        await Task.detached { lifetime.invalidate() }.value
        await waitUntil { runtime.terminal.phase == .exited }
        XCTAssertFalse(runtime.git.pushAfterCommitDismiss)
        runtime.terminal.start()
        runtime.terminal.restart()
        runtime.terminal.retire()
        XCTAssertEqual(runtime.terminal.phase, .exited)
        XCTAssertNil(cache.runtime(client: client(lifetime), folder: folder()))
    }

    func testReplacementGenerationNeverAdoptsOldRuntimeAtSameEndpoint() async throws {
        let cache = ProjectWorkspaceCache()
        let old = ServerBindingLifetime(), replacement = ServerBindingLifetime()
        defer { replacement.invalidate() }
        let previous = try XCTUnwrap(cache.runtime(client: client(old), folder: folder()))
        previous.tab = .terminal
        old.invalidate()
        let next = try XCTUnwrap(cache.runtime(client: client(replacement), folder: folder()))
        await waitUntil { previous.terminal.phase == .exited }
        XCTAssertFalse(previous === next)
        XCTAssertFalse(previous.git === next.git)
        XCTAssertFalse(previous.terminal === next.terminal)
        XCTAssertEqual(next.tab, .files)
        XCTAssertTrue(cache.runtime(client: client(replacement), folder: folder()) === next)
    }

    func testAlreadyRetiredGenerationNeverCreatesRuntime() async {
        let cache = ProjectWorkspaceCache()
        let lifetime = ServerBindingLifetime()
        lifetime.invalidate()
        XCTAssertNil(cache.runtime(client: client(lifetime), folder: folder()))
    }

    func testUnboundClientsKeepLocalOwnershipAndNeverShareRuntime() async throws {
        let cache = ProjectWorkspaceCache()
        let unbound = client()
        var first: ProjectRuntime? = try XCTUnwrap(cache.runtime(client: unbound, folder: folder()))
        weak var released = first
        weak var releasedTerminal = first?.terminal
        let second = try XCTUnwrap(cache.runtime(client: unbound, folder: folder()))
        XCTAssertFalse(first === second)
        XCTAssertFalse(first?.git === second.git)
        XCTAssertFalse(first?.terminal === second.terminal)
        first = nil
        XCTAssertNil(released)
        XCTAssertNil(releasedTerminal)
        XCTAssertEqual(second.terminal.phase, .idle)
    }
}

/// Foundation-only observer tests also run in the portable Swift harness.
final class ProjectInvalidationObserverTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private final class Capture: @unchecked Sendable {
        let onDeinit: @Sendable () -> Void
        init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }

    func testObserversRunOnceOutsideLockAndLateRegistrationIsImmediate() {
        let lifetime = ServerBindingLifetime()
        let first = Counter(), late = Counter()
        let token = lifetime.addInvalidationObserver {
            XCTAssertFalse(lifetime.isValid)
            lifetime.invalidate() // Reentry must not deadlock or fire again.
            XCTAssertNil(lifetime.addInvalidationObserver { late.increment() })
            first.increment()
        }
        XCTAssertNotNil(token)
        XCTAssertEqual(first.value, 0)
        lifetime.invalidate()
        lifetime.invalidate()
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(late.value, 1)
        XCTAssertThrowsError(try lifetime.check()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testRemovedObserverDoesNotFireAndDoesNotAffectOtherObservers() throws {
        let lifetime = ServerBindingLifetime()
        let removed = Counter(), retained = Counter()
        let token = try XCTUnwrap(lifetime.addInvalidationObserver { removed.increment() })
        lifetime.addInvalidationObserver { retained.increment() }
        lifetime.removeInvalidationObserver(token)
        lifetime.removeInvalidationObserver(token)
        lifetime.invalidate()
        XCTAssertEqual(removed.value, 0)
        XCTAssertEqual(retained.value, 1)
    }

    func testConcurrentRegistrationAndInvalidationDoesNotLoseOrRepeatObservers() {
        for _ in 0..<50 {
            let lifetime = ServerBindingLifetime()
            let calls = Counter()
            DispatchQueue.concurrentPerform(iterations: 64) { index in
                lifetime.addInvalidationObserver {
                    XCTAssertFalse(lifetime.isValid)
                    calls.increment()
                }
                if index.isMultiple(of: 7) { lifetime.invalidate() }
            }
            lifetime.invalidate()
            XCTAssertEqual(calls.value, 64)
        }
    }

    func testInvalidationAndRemovalReleaseCapturesOutsideLock() throws {
        for remove in [false, true] {
            let lifetime = ServerBindingLifetime()
            let released = Counter()
            var capture: Capture? = Capture {
                // Releasing the observer's captures must not deadlock either.
                lifetime.invalidate()
                released.increment()
            }
            weak var held = capture
            let token = try XCTUnwrap(lifetime.addInvalidationObserver { [capture] in
                withExtendedLifetime(capture) {}
            })
            capture = nil
            XCTAssertNotNil(held)
            if remove { lifetime.removeInvalidationObserver(token) }
            else { lifetime.invalidate() }
            XCTAssertNil(held)
            XCTAssertEqual(released.value, 1)
        }
    }
}
