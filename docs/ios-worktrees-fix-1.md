# iOS worktrees P2 deferred cleanup fix

Date: 2026-10-12. Implements the sole P2 in `docs/ios-worktrees-review.md`.
Portable validation passes; parent final review and native CI remain outstanding.

## Delivered change

Only these repository files were written by this task:

| File | Change |
| --- | --- |
| `CodegiOS/Features/Worktrees/WorktreeListViewModel.swift` | Retain and reconcile an unverified branch-cleanup target across failed inventory reads. |
| `CodegiOSTests/WorktreeManagementTests.swift` | Add seven actual-model regressions using the existing host-scoped URLProtocol fixture. |
| `docs/ios-worktrees-fix-1.md` | This evidence report. |

The initiating model retains the exact checkout path and listed branch privately
when branch deletion was requested for an attached checkout with a known branch.
The intent is saved after an accepted mutation error, or an accepted response
with `branchDeleted == false`, before attempting inventory reconciliation.
A failed read preserves the last inventory and the unresolved intent; it cannot
publish `branchRecovery` or claim removal. Creation/removal remain blocked while
that intent is unresolved so another mutation cannot replace its target.

Every accepted successful Git inventory, including a later manual `load()`,
resolves the intent. An absent checkout promotes the saved path/branch to
`branchRecovery`; a checkout still present clears the intent, including when
that path now lists another branch. Subsequent unrelated disappearance cannot
revive the cleared intent. A response confirming branch deletion never creates
cleanup intent. Unselected, unknown, and detached branches cannot create it.

Reconciliation runs inside the existing load/lifecycle epoch and binding guards.
Superseded/suspended reads and retired endpoint/model completions cannot promote
recovery. Permanent model invalidation also clears the private intent. Ordinary
suspension retains it for reconciliation by a fresh accepted load after resume.

The existing view consumes `branchRecovery` for its **Delete remaining branch…**
controls and confirmation. No view, DTO, or API signature changed. Cleanup still
requires separate explicit confirmation, defaults force to false, and sends only
`git_delete_branch`; a failed cleanup requires a fresh confirmation for retry.
There is no automatic branch deletion, force escalation, or repeated path removal.

No root/registry/AppModel/SessionDetailViewModel, server-lifetime, project,
localization, workflow, index, commit, or push changes were made by this task.
Other workers' concurrent changes are outside this report's signoff.

## Regression coverage

All 21 original management and 6 original wire test bodies were compared with
the pre-fix snapshot and preserved verbatim. The wire test file/fixture was not
edited. The seven added tests are:

| Test | Verified behavior |
| --- | --- |
| `testPartialRemovalFailedReloadThenRefreshOffersRemainingBranchCleanup` | Server removes `/linked` but returns an unmerged-branch failure; immediate inventory is offline. Manual refresh proves absence and publishes the exact `topic` recovery. Explicit cleanup failure/retry sends only branch-delete bodies with force false; path removal remains at one request. |
| `testFailedRemovalLateInventoryStillContainsCheckoutClearsCleanupIntent` | Late inventory still lists `/linked`, now on `replacement`: no cleanup, normal removal becomes available, and unrelated later absence cannot revive the old intent. |
| `testFailedRemovalLateAbsenceRequiresSelectedKnownAttachedBranch` | Unselected branch deletion, nil listed branch, and detached checkout never yield recovery or branch deletion after late absence. |
| `testRemovalResponseFailedReloadReconcilesOnlyUndeletedSelectedBranch` | Both success-response variants survive failed immediate inventory; late absence offers cleanup only when branch deletion was not confirmed. |
| `testSupersededRemovalInventoryCannotPromoteBranchCleanup` | Held older absence cannot overwrite newer accepted presence or promote/retain cleanup intent. |
| `testSuspendedRemovalInventoryNeedsFreshLoadBeforePromotingBranchCleanup` | Suspended load cannot publish absence; a fresh accepted load after resume can reconcile the retained target. |
| `testRetiredRemovalInventoryCannotPromoteBranchCleanup` | Binding invalidation, permanent model invalidation, and the initiating `isCurrent` closure all suppress late promotion and cleanup requests. |

## Exact validation evidence

Cached Docker image: `swift:6.2-jammy`; compiler Swift 6.2.4,
`x86_64-unknown-linux-gnu`, package Swift 5 language mode. All containers used
`--network none` and injected `.worktree-tests.invalid` hosts.

Harness:
`/tmp/codeg-acp/3177506-48d3d5bb/codeg-ios-worktrees-fix-gazigg8j`.
Builder: `/tmp/codeg-ios-worktrees-fix-harness.py`, adapted from the review's
existing builder without changing repository source. `snapshot/` retains the
pre-fix files; `Sources/Codeg/` and `Tests/CodegTests/` contain the validated
final model/tests. Their contents were checked against the repository copies.

| Check | Result | Evidence |
| --- | --- | --- |
| Pre-fix original suites | PASS: **27 tests, 0 failures** | `/tmp/codeg-ios-worktrees-fix-baseline.log` |
| New exact regression against unchanged model | Expected FAIL: **1 test, 5 failed assertions, 0 unexpected**; first failure was nil `branchRecovery` after successful manual refresh | `/tmp/codeg-ios-worktrees-fix-red.log` |
| Final complete portable suites | PASS: **34 tests, 0 failures, 0 unexpected** (28 management + 6 wire; 0.229 seconds) | `/tmp/codeg-ios-worktrees-fix-tests.log` |
| Swift frontend parse | PASS: all seven worktree Swift files | `/tmp/codeg-ios-worktrees-fix-parse.log` (empty output, exit 0) |
| Original test preservation | PASS: all 27 original test bodies unchanged | Compared with harness `snapshot/CodegiOSTests/` |
| Whitespace | PASS: `git diff --check` plus snapshot/new-file checks for the three assigned files | Required separately because the assigned source/tests were untracked in the shared checkout |

Run the final portable suite with:

```bash
docker run --rm --network none \
  -v /tmp/codeg-acp/3177506-48d3d5bb/codeg-ios-worktrees-fix-gazigg8j:/work \
  -w /work swift:6.2-jammy \
  swift test --filter 'WorktreeManagementTests|WorktreeWireTests'
```

The baseline used this same filter before copying in the new tests/patched model.
The failing reproduction used
`swift test --filter WorktreeManagementTests.testPartialRemovalFailedReloadThenRefreshOffersRemainingBranchCleanup`
with the original model and the new regression.

Source parse command:

```bash
docker run --rm --network none \
  -v /home/droid/worktrees/codeg-ios-multi-host:/repo:ro -w /repo \
  swift:6.2-jammy swiftc -frontend -parse \
  CodegiOS/Models/GitWorktree.swift \
  CodegiOS/Networking/CodegClient+Worktrees.swift \
  CodegiOS/Networking/CodegClient+Folders.swift \
  CodegiOS/Features/Worktrees/WorktreeListViewModel.swift \
  CodegiOS/Features/Worktrees/WorktreeListView.swift \
  CodegiOSTests/WorktreeManagementTests.swift \
  CodegiOSTests/WorktreeWireTests.swift
```

For the assigned untracked files, whitespace was also checked with
`git diff --no-index --check` against their pre-fix snapshots, and against
`/dev/null` for this report. No whitespace diagnostics were emitted; the
no-index checks returned exit 1 for the content differences.

The first full-suite attempt exposed a Linux FoundationNetworking double-resume
race when a new test released a held URLProtocol success while cancellation was
still pending. The new cancellation tests now await the cancelled load before
releasing the held response. The final complete run above passed. The existing
fixture's unavailable Sendable-conformance warning remains non-failing.

Validated source SHA-256:

```text
ee57a8172d38e4351d525d298d522eed003d3a712622854153c41bf0a6aa416a  CodegiOS/Features/Worktrees/WorktreeListViewModel.swift
41ad98beb4159d8edc840094f0495473d11d51ef3c5eafbec182a44f814bf71e  CodegiOSTests/WorktreeManagementTests.swift
```

The portable package copies the DTO, worktree networking extension, model,
tests, JSON/error helpers, and binding helpers unchanged. Shared client
transport/methods, request bodies, FolderDetail/FolderKind, and file-preview DTO
are extracted verbatim. Linux adjustments import FoundationNetworking, omit
unsupported `waitsForConnectivity` assignments, and supply unrelated AgentType
and empty conversation-summary shims, as in the reviewer harness.

Native SwiftUI type checking, iOS app/test-bundle builds, simulator rendering,
and UI interaction were **not run**. Parsing and model publication assertions
do not establish a native render result. Parent final review and macOS/iOS CI
are required for native signoff.
