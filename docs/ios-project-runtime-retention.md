# Retained iOS project runtime

Implemented in the shared `/home/droid/worktrees/codeg-ios-multi-host` worktree at baseline `fd83379`. This worker edited only `ProjectDetailView.swift`, new `ProjectWorkspaceCache.swift`, the agreed observer extension in `ServerBindingLifetime.swift`, the optional lifecycle extension in `TerminalSession.swift`, new `CodegiOSTests/ProjectRuntimeRetentionTests.swift`, and this report. No staging, commit, push, CI dispatch, or edits to AppModel, RootView, ServerWorkspaceRegistry, SessionDetailViewModel, FolderGitModel, CommitSheet, or the parent's FolderTerminalView focus guard were performed. The parent paused the owned files; the only shared API integration is the lifetime observer extension below.

The work followed three steps: retain fixed-client project models by generation and folder, wire explicit retirement without navigation teardown, then validate identity/isolation and the portable observer primitive.

`ProjectWorkspaceCache.shared` owns separate folder maps for each active server generation. `ProjectWorkspaceKey` contains only `bindingLifetime.id`, `folder.id`, and the exact folder path. Equal IDs and paths on A/B remain distinct, changed paths and worktrees remain distinct, and replacement generations cannot adopt old models even at the same endpoint. URL/token strings do not participate in identity. No global selection, ActivityModel, navigation stack, or chat session state moved into this cache.

Each `ProjectRuntime` holds the original client's `FolderGitModel`, `TerminalSession` (including its SwiftTerm emulator), selected project tab, and commit-sheet presentation flag. FolderDetailContent resolves this runtime in its existing initializer and observes it. ProjectDetailView's existing initializer remains compatible; its content identity now includes the generation and path. Leaving/rebuilding navigation or regular/compact/split shells has no eviction or terminal teardown hook. A terminal remains lazy until its first tab appearance.

Unbound clients receive a fresh runtime for each content initializer, stored only in that view's `@State`. They are never retained or deduplicated by URL, token, or folder globally. This preserves the existing local lifetime and deinit cleanup.

Each cached generation registers **one** observer, regardless of how many projects or view rebuilds it sees. The callback captures the cache weakly and schedules `Task { @MainActor ... }` to remove only that UUID's folder map. Removal also resolves pending local Git credential continuations and retires every terminal. Registration/removal is bounded by active generations at this call site; late callbacks are not stored, and generation deinit removes any outstanding observer. Validity is checked before lookup, after registration, and after creation so a raced or already-retired client cannot remain cached. Retirement is asynchronous on the MainActor; the binding itself becomes invalid synchronously.

`TerminalSession.retire()` is idempotent. It resolves the ready gate, cancels bootstrap/consumer/reconnect/resize tasks, closes the local socket and write queue through the existing teardown, clears the runtime's terminal ID, resigns keyboard focus, and marks the terminal exited. Start/restart and stale-generation frame handling reject retired bindings. The existing deinit still calls `runtime.teardown(kill: true)`; no remote agent cancellation endpoint was introduced. Retirement deliberately keeps the original bound client: after invalidation, its HTTP checks reject PTY kill requests. Local resource shutdown and eviction are guaranteed by this path; remote PTY termination after credentials/address retirement is not guaranteed. No request is redirected to a replacement endpoint and no binding check is bypassed.

The new lifetime methods are:

```swift
@discardableResult
func addInvalidationObserver(_ observer: @escaping @Sendable () -> Void) -> UUID?
func removeInvalidationObserver(_ id: UUID)
```

Callbacks run synchronously on the invalidating/registering thread, outside NSLock. Invalidation drains the observers once; late registration invokes immediately and returns nil. Removal is idempotent and cannot recall an already-drained callback. Captured owners are also released outside the lock, permitting their deinits to reenter lifetime methods. `id`, `isValid`, and `check()` keep their existing contract. The exact delta from the observer file at this worker's entry is recorded below (that file was already untracked parent work, so its delta is not represented by ordinary `git diff`).

```diff
--- ServerBindingLifetime.swift (worker entry)
+++ ServerBindingLifetime.swift (worker result)
@@ -8,0 +9 @@
+    private var invalidationObservers: [UUID: @Sendable () -> Void] = [:]
@@ -16 +17,32 @@
-        lock.lock(); valid = false; lock.unlock()
+        lock.lock()
+        guard valid else { lock.unlock(); return }
+        valid = false
+        let observers = invalidationObservers
+        invalidationObservers = [:]
+        lock.unlock()
+        for observer in observers.values { observer() }
+    }
+
+    /// Called once on the invalidating thread, outside the lock. A late observer
+    /// fires immediately and is not stored. Owners can remove an unused observer;
+    /// removal cannot recall a callback already drained by `invalidate()`.
+    @discardableResult
+    func addInvalidationObserver(_ observer: @escaping @Sendable () -> Void) -> UUID? {
+        lock.lock()
+        guard valid else {
+            lock.unlock()
+            observer()
+            return nil
+        }
+        let id = UUID()
+        invalidationObservers[id] = observer
+        lock.unlock()
+        return id
+    }
+
+    func removeInvalidationObserver(_ id: UUID) {
+        lock.lock()
+        let removed = invalidationObservers.removeValue(forKey: id)
+        lock.unlock()
+        // Release captured owners outside the lock too (their deinit may reenter).
+        withExtendedLifetime(removed) {}
```

Validation results:

| Check | Result | Coverage / limit |
| --- | --- | --- |
| Swift 6.2.4 frontend parse | PASS | All five owned Swift files, including view, real terminal, and native XCTest source. Syntax only for UIKit/SwiftUI/SwiftTerm. |
| Swift 6 strict concurrency portable XCTest | PASS: 12 tests | Production cache and lifetime compiled unchanged, with explicit model/client/platform doubles. Eight retention/isolation tests and four Foundation-only observer tests. This does not execute the native terminal implementation. |
| Observer races | PASS | 50 rounds of 64 concurrent registrations interleaved with invalidation, exactly 3,200 callbacks; repeated/late invalidation, removal, callback reentry, and capture release/deinit reentry also covered. |
| Existing `scripts/test-server-binding.swift` | PASS: 6 invariants | Actual lifetime plus profile revision migration; Swift 6 strict concurrency. |
| Existing `scripts/test-server-http.swift` | PASS: 5 invariants | Actual lifetime and ServerBoundHTTP: fixed A/B routing, held-response retirement, unaffected B; Swift 6 strict concurrency. |
| Scoped whitespace checks | PASS | Owned tracked diffs and new files checked without modifying the index. |
| Native app/test bundle build, iPad UI, real PTY | NOT RUN by this worker | Parent native CI/device validation required. The user-reported baseline dispatch `38192495757` is not evidence for these changes. |

The portable test package and log are retained at `/tmp/codeg-acp/3177506-28db8c65/codeg-project-retention-3it0o1_u` (`PROVENANCE.md`, `test.log`). Its Codeg target contains unchanged `ProjectWorkspaceCache.swift`/`ServerBindingLifetime.swift` and explicit stand-ins for CodegClient, FolderDetail, FolderTab, FolderGitModel, and TerminalSession. The full new XCTest source ran against those stand-ins. Weak-local mutability suggestions from Swift 6.2 are warnings only. Re-run it with:

```sh
docker run --rm --network none \
  -v /tmp/codeg-acp/3177506-28db8c65/codeg-project-retention-3it0o1_u:/probe \
  -w /probe swift:6.2-jammy swift test --disable-sandbox
```

The new native tests exercise runtime/Git/terminal/emulator identities, absent-view ownership, A/B equal IDs and paths, changed paths, worktrees, background retirement, still-referenced retirement, replacement and already-retired generations, and unbound local ownership. They never spawn a PTY or issue HTTP. `project.yml` already discovers both new source files; no project configuration edit is needed. After regenerating the project, the parent's native validation can run:

```sh
xcodebuild test -project CodegiOS.xcodeproj -scheme CodegiOSSessionRecovery \
  -destination 'platform=iOS Simulator,id=<available-simulator-udid>' \
  -only-testing:CodegiOSTests/ProjectRuntimeRetentionTests \
  -only-testing:CodegiOSTests/ProjectInvalidationObserverTests
```

For native UI validation, open a terminal in A, switch A/B with matching project IDs/paths, resize an iPad between regular/compact and split shells, and return to A; the terminal instance/process/scrollback and selected tab should remain. Edit/delete A's endpoint and confirm local teardown while B remains usable. Real PTY and UIKit reparenting behavior are not asserted from the portable doubles.

One explicit remaining limit: retaining FolderGitModel preserves its operation/prompt state but **does not retain unsaved commit text or file selections**. Those are private `@State` fields in the out-of-scope `CommitSheet.swift`, and the same limitation applies to nested Files view state. The presentation flag is retained, but a reconstructed sheet can create a fresh composer. This report does not claim composer retention; completing it requires a separately authorized change to CommitSheet's state ownership.
