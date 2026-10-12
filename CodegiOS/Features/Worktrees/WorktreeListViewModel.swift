import Foundation
import Observation

enum WorktreeIssue: Equatable {
    case upgradeRequired, invalidInput, targetUnavailable, protectedWorktree, rootFolderUnavailable
    case failure(String)

    var key: String {
        switch self {
        case .upgradeRequired:
            return "This server does not support worktree management. Upgrade the Codeg server to use this feature."
        case .invalidInput:
            return "Enter a branch name and an absolute path on this server."
        case .targetUnavailable:
            return "This checkout has changed or is unavailable. Refresh the worktree list."
        case .protectedWorktree:
            return "Main, current, bare, and locked worktrees cannot be removed."
        case .rootFolderUnavailable:
            return "Open the main checkout as a folder before registering another checkout."
        case .failure: return "Worktree operation failed"
        }
    }
}

struct WorktreeRegistrationRecovery: Equatable, Sendable {
    let path: String
}

struct WorktreeBranchRecovery: Equatable, Sendable {
    let worktreePath: String
    let branchName: String
}

struct WorktreeRemovalConfirmation: Identifiable {
    let worktree: GitWorktreeInfo
    var id: String { worktree.path }
}

private struct WorktreeInventoryLoad: Sendable {
    let entries: [GitWorktreeInfo]?
    let folders: [FolderDetail]?
    let error: Error?
}

/// One initiating server and folder for the entire lifetime of the view.
/// Selection changes never replace either value, including during recovery.
@MainActor
@Observable
final class WorktreeListViewModel {
    let client: CodegClient
    let sourceFolder: FolderDetail
    let serverName: String
    private(set) var worktrees: [GitWorktreeInfo] = []
    private(set) var folders: [FolderDetail]
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var hasInventory = false
    private(set) var issue: WorktreeIssue?
    private(set) var pendingRegistration: WorktreeRegistrationRecovery?
    private(set) var branchRecovery: WorktreeBranchRecovery?
    // Unverified cleanup intent stays private until accepted Git inventory
    // proves the checkout absent. The client/source identity is fixed here.
    private var pendingRemoval: WorktreeBranchRecovery?
    private(set) var removalConfirmation: WorktreeRemovalConfirmation?
    private(set) var isConfirmingBranchCleanup = false

    @ObservationIgnored private let isCurrent: () -> Bool
    @ObservationIgnored private let onOpenFolder: (FolderDetail) -> Void
    @ObservationIgnored private let onFoldersChanged: () -> Void
    @ObservationIgnored private var loadTask: Task<WorktreeInventoryLoad, Never>?
    @ObservationIgnored private var loadEpoch = 0
    @ObservationIgnored private var lifecycleEpoch = 0
    @ObservationIgnored private var isPresented = true
    private(set) var isInvalidated = false

    init(client: CodegClient, folder: FolderDetail, serverName: String = "",
         isCurrent: @escaping () -> Bool = { true },
         onOpenFolder: @escaping (FolderDetail) -> Void = { _ in },
         onFoldersChanged: @escaping () -> Void = {}) {
        self.client = client
        sourceFolder = folder
        self.serverName = serverName
        folders = [folder]
        self.isCurrent = { isCurrent() && (client.bindingLifetime?.isValid ?? true) }
        self.onOpenFolder = onOpenFolder
        self.onFoldersChanged = onFoldersChanged
    }

    var rootPath: String {
        worktrees.first?.rootPath ?? worktrees.first(where: \.isMain)?.path ?? sourceFolder.path
    }

    var canCreate: Bool {
        canAct && pendingRegistration == nil && pendingRemoval == nil && branchRecovery == nil
    }

    var allowsPresentation: Bool { isPresented && !isInvalidated && isCurrent() }

    private var canAct: Bool {
        allowsPresentation && !isMutating && !isLoading && hasInventory && issue != .upgradeRequired
    }

    /// Navigation can temporarily hide this view without retiring its host.
    /// In-flight requests retain their client; their old epoch cannot present.
    func suspendPresentation() {
        isPresented = false
        lifecycleEpoch += 1
        loadEpoch += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        removalConfirmation = nil
        isConfirmingBranchCleanup = false
    }

    func resumePresentation() {
        guard !isInvalidated, isCurrent() else { return }
        isPresented = true
    }

    /// Permanent retirement. The parent must create a new view/model after an
    /// endpoint generation changes. Already sent mutations stay on their client;
    /// no completion can present UI or send a follow-up registration.
    func invalidate() {
        isInvalidated = true
        lifecycleEpoch += 1
        loadEpoch += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        isMutating = false
        pendingRemoval = nil
        removalConfirmation = nil
        isConfirmingBranchCleanup = false
    }

    func load() async {
        guard isPresented, !isInvalidated, isCurrent(), !isMutating else { return }
        _ = await refresh(clearIssue: true)
    }

    /// Every refresh owns an epoch as well as cancellation: even a transport
    /// which completes after cancellation cannot replace a newer inventory.
    @discardableResult
    private func refresh(clearIssue: Bool) async -> Bool {
        guard accepts(lifecycleEpoch) else { return false }
        loadEpoch += 1
        let epoch = loadEpoch
        let lifetime = lifecycleEpoch
        let fixedClient = client
        let fixedPath = sourceFolder.path
        loadTask?.cancel()
        isLoading = true
        if clearIssue { issue = nil }
        let task = Task { () -> WorktreeInventoryLoad in
            do {
                let entries = try await fixedClient.gitWorktrees(path: fixedPath)
                try Task.checkCancellation()
                do {
                    let folders = try await fixedClient.listFolders()
                    return WorktreeInventoryLoad(entries: entries, folders: folders, error: nil)
                } catch {
                    return WorktreeInventoryLoad(entries: entries, folders: nil, error: error)
                }
            } catch {
                return WorktreeInventoryLoad(entries: nil, folders: nil, error: error)
            }
        }
        loadTask = task
        let result = await task.value
        guard epoch == loadEpoch, lifetime == lifecycleEpoch, !isInvalidated else { return false }
        loadTask = nil
        isLoading = false
        guard accepts(lifetime) else { return false }
        if let entries = result.entries {
            worktrees = entries
            hasInventory = true
            if let pending = pendingRemoval {
                // A failed/superseded read leaves the intent unresolved. A
                // current successful read resolves it, even on a later load.
                pendingRemoval = nil
                if currentEntry(pending.worktreePath) == nil { branchRecovery = pending }
            }
        }
        if let folders = result.folders { self.folders = folders }
        if let error = result.error { setIssue(error) }
        return result.entries != nil
    }

    func registeredFolder(for worktree: GitWorktreeInfo) -> FolderDetail? {
        folders.first { WorktreePaths.same($0.path, worktree.path) }
    }

    func canOpen(_ worktree: GitWorktreeInfo) -> Bool {
        canAct && currentEntry(worktree.path).map { !$0.bare && !$0.isPrunable } == true
    }

    func canRemove(_ worktree: GitWorktreeInfo) -> Bool {
        canAct && pendingRegistration == nil && pendingRemoval == nil && branchRecovery == nil &&
            currentEntry(worktree.path).map { !isProtected($0) } == true
    }

    /// Only a current inventory entry may be opened. This never calls Git add.
    func open(_ worktree: GitWorktreeInfo) async {
        guard canOpen(worktree), let entry = currentEntry(worktree.path) else { return }
        let rootID = registrationRootID
        if !entry.isMain && registeredFolder(for: entry) == nil && rootID == nil {
            issue = .rootFolderUnavailable; return
        }
        let fixedClient = client
        let lifetime = beginMutation()
        defer { finishMutation(lifetime) }
        do {
            let folder: FolderDetail
            if entry.isMain || registeredFolder(for: entry) != nil {
                // Reopen a registered folder, preserving its existing parent.
                folder = try await fixedClient.openFolder(path: entry.path)
            } else {
                folder = try await fixedClient.openWorktreeFolder(
                    path: entry.path, sourceFolderId: rootID!
                )
            }
            guard accepts(lifetime) else { return }
            if pendingRegistration?.path == entry.path { pendingRegistration = nil }
            await registered(folder, lifetime: lifetime)
        } catch {
            if accepts(lifetime) { setIssue(error) }
        }
    }

    func create(branchName: String, worktreePath: String, base: String? = nil) async {
        guard canCreate else { return }
        let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = worktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = base?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, WorktreePaths.isAbsolute(path) else { issue = .invalidInput; return }
        guard let rootID = registrationRootID else { issue = .rootFolderUnavailable; return }
        let fixedClient = client
        let lifetime = beginMutation()
        defer { finishMutation(lifetime) }
        do {
            try await fixedClient.gitWorktreeAdd(path: sourceFolder.path, branchName: branch,
                                                worktreePath: path, base: base?.isEmpty == true ? nil : base)
            // Persist the successful stage BEFORE awaiting registration.
            if !isInvalidated && isCurrent() {
                pendingRegistration = WorktreeRegistrationRecovery(path: path)
            }
            guard accepts(lifetime) else { return }
            do {
                let folder = try await fixedClient.openWorktreeFolder(path: path, sourceFolderId: rootID)
                guard accepts(lifetime) else { return }
                pendingRegistration = nil
                await registered(folder, lifetime: lifetime)
            } catch {
                guard accepts(lifetime) else { return }
                onFoldersChanged()
                _ = await refresh(clearIssue: false)
                if accepts(lifetime) { setIssue(error) }
            }
        } catch {
            if accepts(lifetime) { setIssue(error) }
        }
    }

    /// Resume the registration stage using its saved path, without Git add.
    func retryRegistration() async {
        guard canAct, let pending = pendingRegistration else { return }
        guard let rootID = registrationRootID else { issue = .rootFolderUnavailable; return }
        let fixedClient = client
        let lifetime = beginMutation()
        defer { finishMutation(lifetime) }
        do {
            let folder = try await fixedClient.openWorktreeFolder(path: pending.path, sourceFolderId: rootID)
            guard accepts(lifetime) else { return }
            pendingRegistration = nil
            await registered(folder, lifetime: lifetime)
        } catch {
            if accepts(lifetime) { setIssue(error) }
        }
    }

    func requestRemoval(_ worktree: GitWorktreeInfo) {
        guard canAct, pendingRegistration == nil, pendingRemoval == nil, branchRecovery == nil else { return }
        guard let current = currentEntry(worktree.path) else { issue = .targetUnavailable; return }
        guard !isProtected(current) else { issue = .protectedWorktree; return }
        removalConfirmation = WorktreeRemovalConfirmation(worktree: current)
    }

    func cancelRemoval() { removalConfirmation = nil }

    /// No mutation without a preceding request for this exact target. Force is
    /// never inferred from an error or carried over to a later confirmation.
    func confirmRemoval(deleteBranch: Bool = false, force: Bool = false) async {
        guard canAct, let confirmation = removalConfirmation else { return }
        removalConfirmation = nil
        guard let entry = currentEntry(confirmation.worktree.path), entry == confirmation.worktree else {
            issue = .targetUnavailable; return
        }
        guard !isProtected(entry) else { issue = .protectedWorktree; return }
        let fixedClient = client
        let deletingBranch = deleteBranch && entry.branch != nil && !entry.detached
        let cleanup = deletingBranch ? entry.branch.map {
            WorktreeBranchRecovery(worktreePath: entry.path, branchName: $0)
        } : nil
        let lifetime = beginMutation()
        defer { finishMutation(lifetime) }
        do {
            let result = try await fixedClient.gitWorktreeRemoveByPath(
                path: sourceFolder.path, worktreePath: entry.path, sourceFolderId: sourceFolder.id,
                deleteBranch: deletingBranch, force: force
            )
            guard accepts(lifetime) else { return }
            pendingRemoval = result.branchDeleted ? nil : cleanup
            onFoldersChanged()
            _ = await refresh(clearIssue: false)
        } catch {
            guard accepts(lifetime) else { return }
            // A removal can succeed before branch deletion throws. A fresh,
            // successful inventory is the only proof used for recovery.
            pendingRemoval = cleanup
            _ = await refresh(clearIssue: false)
            guard accepts(lifetime) else { return }
            onFoldersChanged()
            setIssue(error)
        }
    }

    func requestBranchCleanup() {
        guard canAct, branchRecovery != nil else { return }
        isConfirmingBranchCleanup = true
    }

    func cancelBranchCleanup() { isConfirmingBranchCleanup = false }

    func confirmBranchCleanup(force: Bool = false) async {
        guard canAct, isConfirmingBranchCleanup, let recovery = branchRecovery else { return }
        isConfirmingBranchCleanup = false
        let fixedClient = client
        let lifetime = beginMutation()
        defer { finishMutation(lifetime) }
        do {
            _ = try await fixedClient.gitWorktreeDeleteBranch(path: sourceFolder.path,
                                                            branchName: recovery.branchName, force: force)
            guard accepts(lifetime) else { return }
            branchRecovery = nil
            onFoldersChanged()
            _ = await refresh(clearIssue: false)
        } catch {
            if accepts(lifetime) { setIssue(error) }
        }
    }

    private func currentEntry(_ path: String) -> GitWorktreeInfo? {
        worktrees.first { WorktreePaths.same($0.path, path) }
    }

    private var registrationRootID: Int? {
        if let parent = sourceFolder.parentId { return parent }
        if WorktreePaths.same(rootPath, sourceFolder.path) { return sourceFolder.id }
        return folders.first { WorktreePaths.same($0.path, rootPath) }?.id
    }

    private func isProtected(_ worktree: GitWorktreeInfo) -> Bool {
        worktree.isMain || worktree.bare || worktree.isLocked || WorktreePaths.same(worktree.path, sourceFolder.path)
    }

    private func accepts(_ lifetime: Int) -> Bool {
        isPresented && !isInvalidated && isCurrent() && lifetime == lifecycleEpoch && !Task.isCancelled
    }

    private func beginMutation() -> Int {
        loadEpoch += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        isMutating = true
        issue = nil
        return lifecycleEpoch
    }

    private func finishMutation(_ lifetime: Int) {
        guard !isInvalidated else { return }
        isMutating = false
        // A resumed view may have skipped its load while this request was still
        // running. Reconcile once it finishes, without invoking old callbacks.
        if isPresented && isCurrent() && lifetime != lifecycleEpoch {
            Task { await self.load() }
        }
    }

    private func registered(_ folder: FolderDetail, lifetime: Int) async {
        guard accepts(lifetime) else { return }
        onFoldersChanged()
        _ = await refresh(clearIssue: false)
        if accepts(lifetime) { onOpenFolder(folder) }
    }

    private func setIssue(_ error: Error) {
        if error is WorktreeAPIError { issue = .upgradeRequired }
        else { issue = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    }
}
