# Native iOS worktrees implementation

## Approved source plan

Scope: the seven assigned Swift files and this report, in the existing shared
`feat/ios-multi-host-worktrees` checkout. No commits, index changes, workflow,
catalog, lifecycle, AppModel, or String Catalog edits.

1. Add Foundation DTOs for the complete Git inventory and removal response.
   Preserve nil versus empty locked/prunable reasons. Accept `root_path` when
   present; the inspected backend currently supplies the main inventory path.
2. Add `CodegClient+Worktrees.swift` for list, removal, and branch cleanup using
   exact camelCase fields. The removal handler requires `sourceFolderId`, so
   provide the requested convenience signature plus an explicit source-ID
   overload for the fixed model. Add defaulted optional `base` to the existing
   add method and body, preserving legacy callers.
3. Build an observable main-actor model bound permanently to one client and
   source folder. Cancel superseded reads with epochs; reject presentation and
   follow-up requests after invalidation. Separate Git creation from folder
   registration so recovery cannot repeat add. Open inventory paths only.
4. Build the native SwiftUI view with the specified initializer, initiating
   server/path, all inventory flags, explicit removal/branch cleanup sheets,
   and registration-only recovery. Delegate navigation/catalog updates through
   the two supplied callbacks.
5. Add standalone host-scoped URLProtocol tests for wire keys and complete DTOs,
   equal IDs/paths on A and B, creation recovery, removal recovery and guards,
   explicit force, auth/offline isolation, and retired/superseded completions.
6. Validate with available Swift Linux tooling and record exact limitations.
   Supply English keys and zh-Hans translations here for the parent's catalog
   merge. Native Xcode build/testing belongs to parent macOS CI.

## Semantic references

Read `project.yml`, `README.md`, iOS networking/folder/Git conventions and the
standalone-injection pattern in session recovery tests. Backend references:
`src-tauri/src/web/handlers/{git,folders}.rs`, `src-tauri/src/web/router.rs`,
`src-tauri/src/models/folder.rs`, and supporting folder commands. Frontend
references: `src/lib/backend/worktrees.ts` and
`src/components/workspace/host-worktree-dialog.tsx` (semantics only).

## Delivered files

| File | Responsibility |
| --- | --- |
| `CodegiOS/Models/GitWorktree.swift` | `GitWorktreeInfo` and `GitWorktreeRemoval`, Foundation only |
| `CodegiOS/Networking/CodegClient+Worktrees.swift` | Inventory, path removal, branch-only cleanup, endpoint upgrade error, remote path helpers |
| `CodegiOS/Networking/CodegClient+Folders.swift` | Only the add signature/call and request body's optional defaulted `base` |
| `CodegiOS/Features/Worktrees/WorktreeListViewModel.swift` | Immutable host/source identity, inventory loading, mutation guards, confirmations, partial recovery, presentation epochs |
| `CodegiOS/Features/Worktrees/WorktreeListView.swift` | Native list, creation form, target-specific removal/cleanup sheets, recovery actions |
| `CodegiOSTests/WorktreeWireTests.swift` | Wire tests and independent injected URLProtocol fixtures |
| `CodegiOSTests/WorktreeManagementTests.swift` | Host isolation, recovery, guards, retirement, navigation, and load races |

## Parent integration contract

```swift
WorktreeListView(
    client: client,
    folder: folder,
    serverName: serverName,
    onOpenFolder: { folder in /* navigate within the initiating server */ },
    onFoldersChanged: { /* refresh that server's catalog */ }
)
```

The initializer exactly matches the requested contract. The view owns one
`@State` model, whose client, source folder, server name, and callbacks never
change. Give the view a new identity when the initiating endpoint generation
changes. Pass the parent's bound client: the model combines optional
`isCurrent` with `client.bindingLifetime?.isValid` and the transport's binding
checks. Ordinary selection changes do not invalidate that binding. Callback
closures should retain the initiating server identity when navigating/updating
the catalog; a bare folder ID/path cannot identify a server.

For direct model use, the initializer also accepts `isCurrent: () -> Bool` and
both callbacks. `invalidate()` permanently retires a model. The view uses
`suspendPresentation()` / `resumePresentation()` for ordinary disappearance and
return navigation, so back navigation works. Loads use task cancellation and
epochs; mutation completions use a lifetime epoch plus the fixed binding.
Suspended Git creation can retain its known successful path for registration
retry, while skipping follow-up requests and old callbacks. A resumed view
reconciles inventory when the old mutation finishes.

Inventory includes main, detached, bare, locked, and prunable entries. Head,
branch, and reasons are nullable; `locked == ""` and `prunable == ""` still mean
the corresponding flag is present. `rootPath` decodes `root_path` when supplied,
and otherwise the main inventory entry supplies the repository root. The
inspected Rust inventory currently has no `root_path`; both wire shapes are
tested. No registered folder list substitutes for Git inventory.

Existing registered/main checkouts reopen through `open_folder`. Unregistered
listed checkouts use `open_worktree_folder` only. Registration uses the fixed
source folder's root ID, or the registered main path when a linked checkout was
previously registered as a top-level folder. If that root is not registered,
the view asks the user to open the listed main checkout first. Bare/prunable
checkouts cannot be opened through this view. There is no implicit Git creation.

## Verified HTTP contract

All endpoints use the existing authenticated `POST /api/<name>` transport.

| Endpoint | Request keys | Response |
| --- | --- | --- |
| `git_list_worktrees` | `path` | Complete inventory array |
| `git_worktree_add` | `path`, `branchName`, `worktreePath`, optional `base` | `null` (existing add behavior) |
| `open_worktree_folder` | `path`, `sourceFolderId` | `FolderDetail` |
| `open_folder` | `path` | `FolderDetail` |
| `git_remove_worktree_path` | `path`, `worktreePath`, **required** `sourceFolderId`, `deleteBranch`, `force` | `GitWorktreeRemoval` |
| `git_delete_branch` | `path`, `branchName`, `force` | JSON string |

The requested `gitWorktrees(path:)` and
`gitWorktreeRemoveByPath(path:worktreePath:deleteBranch:force:)` signatures exist.
Because Rust requires a source ID, the removal convenience resolves the
registered source path using this client's folder list; it fails explicitly if
the source is unregistered. The model uses an explicit `sourceFolderId` overload
instead. Both Boolean defaults are false and encoded as camelCase keys. `base`
is omitted when nil; the creation form trims it and treats blank as nil. Old
three-argument `gitWorktreeAdd` and `GitWorktreeAddBody` callers still work.

Missing routes (untyped/unknown-route 404, 405, or 501) produce an explicit
server-upgrade message. A typed checkout `not_found` error stays a checkout
error. Authentication and transport failures stay on the initiating client;
there is no fallback to another host. Missing worktree support does not change
chat or file APIs.

## Recovery and removal behavior

Git add succeeds before folder registration starts. Its successful checkout
path is recorded before awaiting registration. Registration failure refreshes
inventory and offers **Retry registration**; it never repeats Git add. New
creation is blocked while registration recovery is pending.

Removal requires a confirmation containing server, source repository, exact
checkout path, and branch. Branch deletion and force start false in each sheet.
Main/current/bare/locked entries are protected even with force. The backend's
busy/task guards remain authoritative and their error detail is shown; no error
automatically escalates to force. Server paths are not canonicalized on iOS;
the backend still enforces canonical-path/current-tree guards.

Every removal result/error reloads inventory. If branch deletion was requested
and a successful reload proves the checkout absent, branch-only recovery is
offered. An unavailable inventory is not evidence of removal. Cleanup requires
a separate target-specific confirmation, resets force to false, and calls only
`git_delete_branch` with `{path, branchName, force}`. Failed cleanup retains the
recovery target; another explicit confirmation is required to retry. Detached
checkouts never request branch deletion.

## Validation

| Check | Result | Scope |
| --- | --- | --- |
| Swift 6.2.4 Linux XCTest, Swift 5 language mode | PASS: 27 tests, 0 failures | 21 management + 6 wire tests, injected `.invalid` hosts |
| Swift frontend parse | PASS | All seven assigned Swift files, including the native view |
| `git diff --check` | PASS | Workspace whitespace check |
| Localization handoff validation | PASS | Valid JSON; 50 translation pairs cover all 49 UI/model keys plus the convenience-method error |
| Native Xcode build, simulator UI, and native test bundle | NOT RUN | No local macOS/iOS SDK; parent macOS CI required |

Linux tests ran in cached `swift:6.2-jammy` Docker with networking disabled.
The temporary Swift package outside the repository compiled the new DTO,
networking extension, model, and tests unchanged, plus the shared JSON/error
code and parent's `ServerBindingLifetime`. Existing client methods/transport,
request bodies, `FolderDetail`/`FolderKind`, and `FilePreviewContent` were
extracted verbatim into the package. Linux-only harness adjustments imported
FoundationNetworking, omitted unsupported `waitsForConnectivity` assignments,
and provided minimal unrelated `AgentType`/empty conversation-summary shims.
This validates the worktree workflows and actual HTTP transport, not the full
native app or full chat transcript decoding. The chat/files legacy test is a
wire smoke test. Linux emitted a non-failing URLProtocol Sendable conformance
warning from FoundationNetworking; the test fixture follows the project's
existing unchecked Sendable URLProtocol pattern.

The test suites cover exact camelCase keys/defaults/base, all nullable inventory
flags and root-path compatibility, equal IDs/paths on A/B, root registration,
exactly one Git add across partial creation, branch-only partial-removal retry,
force confirmation, backend busy rejection, detached removal, failed reloads,
401/offline isolation, canceled/superseded loads, optional-current and bound
endpoint retirement, and suspended/resumed navigation during creation.

`project.yml` already discovers both new source/test directories; no project
configuration change is needed. Parent-owned changes coexist in the shared
checkout. This task modified only the assigned files and made no commits or
index changes.

## Localization handoff

English String Catalog keys with zh-Hans values follow. Merge these into the
parent's catalog, preserving existing shared-key translations where present.
Dynamic server names, paths, heads, branches, and backend error details are
verbatim. No String Catalog edit was made by this task.

```json
{
  "Worktrees": "工作树",
  "Repository root": "仓库根目录",
  "Git worktrees": "Git 工作树",
  "New worktree": "新建工作树",
  "Refresh worktrees": "刷新工作树",
  "Updating worktrees…": "正在更新工作树…",
  "Loading worktrees…": "正在加载工作树…",
  "No Git worktrees found.": "未找到 Git 工作树。",
  "Branch name": "分支名称",
  "Base (optional)": "起点（可选）",
  "Absolute checkout path": "检出目录的绝对路径",
  "The path is on the initiating server.": "此路径位于发起操作的服务器上。",
  "Create worktree": "创建工作树",
  "Main checkout": "主检出目录",
  "Current checkout": "当前检出目录",
  "Detached HEAD": "分离的 HEAD",
  "Bare repository": "裸仓库",
  "Locked": "已锁定",
  "Prunable": "可清理",
  "Unregistered checkout": "未登记的检出目录",
  "Registered folder": "已登记的文件夹",
  "Open checkout": "打开检出目录",
  "Remove checkout…": "移除检出目录…",
  "Remove checkout": "移除检出目录",
  "Confirm removal": "确认移除",
  "Removing this checkout deletes its working directory.": "移除此检出目录将删除其工作目录。",
  "Also delete the branch": "同时删除分支",
  "Force removal": "强制移除",
  "Force may discard uncommitted changes and delete an unmerged branch.": "强制操作可能丢弃未提交的更改，并删除尚未合并的分支。",
  "Git created this checkout. Add it to the workspace to finish.": "Git 已创建此检出目录。将其添加到工作区以完成操作。",
  "Retry registration": "重试登记",
  "The checkout was removed, but branch cleanup did not finish.": "检出目录已移除，但分支清理尚未完成。",
  "Delete remaining branch…": "删除剩余分支…",
  "Confirm branch cleanup": "确认清理分支",
  "Only the remaining branch will be deleted. The checkout is already removed.": "只会删除剩余分支。检出目录已经移除。",
  "Force branch deletion": "强制删除分支",
  "Force can delete an unmerged branch.": "强制操作可能删除尚未合并的分支。",
  "Delete branch": "删除分支",
  "Server": "服务器",
  "Repository": "仓库",
  "Checkout": "检出目录",
  "Branch": "分支",
  "Cancel": "取消",
  "Worktree operation failed": "工作树操作失败",
  "This server does not support worktree management. Upgrade the Codeg server to use this feature.": "此服务器不支持工作树管理。请升级 Codeg 服务器以使用此功能。",
  "Enter a branch name and an absolute path on this server.": "请输入分支名称以及此服务器上的绝对路径。",
  "This checkout has changed or is unavailable. Refresh the worktree list.": "此检出目录已更改或不可用。请刷新工作树列表。",
  "Main, current, bare, and locked worktrees cannot be removed.": "无法移除主工作树、当前工作树、裸仓库或已锁定的工作树。",
  "Open the main checkout as a folder before registering another checkout.": "请先将主检出目录作为文件夹打开，再登记其他检出目录。",
  "The source repository must be registered before removing a worktree.": "移除工作树之前，必须先登记源仓库。"
}
```
