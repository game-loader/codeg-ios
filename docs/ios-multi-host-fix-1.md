# iOS multi-host architecture fixes — review 1

Scope: the four P2 findings in `docs/ios-multi-host-review-1.md`. Changes are limited to the assigned architecture files, scoped tests, a portable probe, and this report. No staging, commits, push, API settings, localization edits, or native build are part of this handoff.

All four fixes are implemented. Portable checks passed. The new native recovery tests are authored and syntax-parsed, **not executed or native-typechecked on Linux**; the parent owns the native build/CI handoff.

| Finding | Bounded source change | Regression coverage |
| --- | --- | --- |
| F1: adopted conversation owner | `ServerWorkspace.session(conversationID:)` validates a cached alias against the model's current ID, otherwise resolves the adopted ID among retained models before creating one. The request token remains an alias. Retirement uses `ObjectIdentifier` to snapshot/tear down each model once. | Native test performs a real folderless first send with RecoveryServer, waits for adoption/submission, queues a second message, retains a third composer draft, opens by integer ID, and checks identity/text/one recovery record. Separate held failing prompt test caches the alias before actual first-send rollback and checks that it becomes invalid after the ID clears. Portable alias checks explicitly use a session double. |
| F2: reachable split exit | Healthy compact Chats panes receive an optional `ServerSwitcher.onSingleServer` callback; its default remains nil for existing callers. The title menu and Folders catalog both offer Single Server whenever a secondary host is configured. All exit actions use `registry.showSingleServer()`. | Source checks verify the healthy-client branch, callback defaults, both menu actions, and registry callback wiring. Model tests/probe enter and exit split with valid clients. No iPad menu/UI runner was available. |
| F3: navigation representation | `AppModel.transitionShell(isCompact:)` translates conversation/new-request selection and folder/tool stacks in both directions, preserves request UUIDs, clears obsolete detail selection after compact Back, and is idempotent. Both RootView size/split callbacks invoke it. Regular Chats row opens now invoke `model.open` so a prior pending draft does not mask the selected conversation. Restored compact stacks are normalized inside the registry after the existing opaque revision check. | Four added isolation tests cover split entry/exit, width changes, conversations opened in compact, folderless and project-bound draft identity/text, full project prefixes, compact Back, duplicate callbacks, and initial width after navigation restoration. Actual AppModel/registry/nav code passed the portable probe. |
| F4: text pending during send | Read-only `SessionDetailViewModel.retirementSnapshot` includes composer text, queue text, and pending user-turn text. Queued turn IDs already owned by queue entries are excluded from the pending copy. Unconfirmed pending text receives the existing delivery-unconfirmed label. The registry reads the snapshot synchronously before teardown; recovery remains copy/share/delete only and is never resubmitted. | Native tests hold `acp_find_connection_for_conversation` before any prompt, separately hold an `acp_prompt` acknowledgement, update the actual profile using `ServerStore.update`, verify the original bound client is invalid, and check original-host recovery with no replacement prompt. A fifth test preserves a submitting queue item once despite its pending-turn alias. These real model/transport tests remain pending native CI. |

The registry/workspace accept an optional `eventStreamFactory`, with the existing default unchanged, so the native tests exercise registry-created models with the established RecoveryServer/RecoveryEventStream fixtures and original bound client. Replacement clients use a second isolated fixture. Tests do not change production transport or API settings.

Modified/created files (only assigned ownership):

- `CodegiOS/App/AppModel.swift`
- `CodegiOS/App/RootView.swift`
- `CodegiOS/App/ServerWorkspaceRegistry.swift`
- `CodegiOS/Features/Sessions/SessionListView.swift`
- `CodegiOS/Features/SessionDetail/SessionDetailViewModel.swift`
- `CodegiOS/Features/Projects/MultiServerProjectListView.swift`
- `CodegiOSTests/ServerWorkspaceIsolationTests.swift` — four new tests; existing seven preserved.
- `CodegiOSTests/ServerWorkspaceArchitectureRecoveryTests.swift` — five new RecoveryServer tests.
- `scripts/test-ios-multi-host-architecture.py` — reproducible portable probe.
- This report.

The current workspace visibility environment, hidden presentation dismissal, terminal focus guard, per-pane server selection binding, `@ObservationIgnored` session cache, opaque revision and navigation persistence guards, machine header, folderless new chat, and fork/worktree behavior are retained. No edits were made to the parent-owned visibility, terminal, localization, profile/store, HTTP guard, recovery view, or worktree files.

Validation performed from `/home/droid/worktrees/codeg-ios-multi-host`:

```sh
python3 scripts/test-ios-multi-host-architecture.py
git diff --check
docker run --rm swift:6.2-jammy swift --version
```

Results:

- Portable script: exit 0; source wiring checks passed; 12 current Swift source/test files parsed; 12 runtime architecture invariants passed using Swift 6.2.4 (`swift:6.2-jammy`, `-swift-version 5`, matching the project language mode).
- `git diff --check`: exit 0, no whitespace errors.
- The runtime harness uses the actual AppModel, Route, registry, saved navigation, profile, and binding lifetime. Only SwiftUI imports are replaced with Foundation; UI-only types, ServerStore, CodegClient transport, ActivityModel, and SessionDetailViewModel are explicit doubles. Its mutable-ID alias smoke checks do **not** establish real first-send/adoption/rollback correctness; the native fixture tests cover that path.
- RecoveryServer/SessionDetailViewModel XCTest execution, SwiftUI typechecking/rendering, iOS simulator/device validation, and Xcode build were unavailable here. No native pass is claimed. The supplied reviewer harness path was absent in this environment, so the scoped portable script builds a fresh temporary harness from current source.
- Parent-reported core transport results (11 invariants) were not rerun or claimed as this worker's results. The parent continues to own HTTP guards, localization, and final checks.

Native CI handoff: use the existing `CodegiOSSessionRecovery` scheme; include `ServerWorkspaceIsolationTests` and `ServerWorkspaceArchitectureRecoveryTests`, and retain the existing `SessionForegroundRecoveryTests`, `SessionFolderlessChatTests`, and `SessionToolBoundaryTests` coverage. On regular-width iPad, enter split with two healthy clients and exit from either Chats title menu or the Folders toolbar; repeat with a visible conversation, a folderless unsent draft, and a folder stack across split and width changes.

UI strings: both `Single Server` and `Delivery unconfirmed. Check the conversation before retrying.` already exist in `Localizable.xcstrings`. No localization file was edited and no new keys are required.

```json
{"newKeys": []}
```
