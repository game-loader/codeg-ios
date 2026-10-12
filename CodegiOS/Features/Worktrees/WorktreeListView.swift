import SwiftUI

/// The parent owns navigation and catalog refresh. Recreate this view with a
/// new identity when the initiating endpoint generation is retired.
struct WorktreeListView: View {
    @State private var model: WorktreeListViewModel
    @State private var isCreating = false
    @State private var branchName = ""
    @State private var worktreePath = ""
    @State private var base: String

    init(client: CodegClient, folder: FolderDetail, serverName: String,
         onOpenFolder: @escaping (FolderDetail) -> Void,
         onFoldersChanged: @escaping () -> Void) {
        _model = State(initialValue: WorktreeListViewModel(
            client: client, folder: folder, serverName: serverName,
            onOpenFolder: onOpenFolder, onFoldersChanged: onFoldersChanged
        ))
        _base = State(initialValue: folder.gitBranch ?? "HEAD")
    }

    var body: some View {
        List {
            Section {
                Label {
                    Text(verbatim: model.serverName)
                } icon: {
                    Image(systemName: "server.rack")
                }
                Text(verbatim: model.sourceFolder.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if !WorktreePaths.same(model.rootPath, model.sourceFolder.path) {
                    LabeledContent("Repository root") {
                        Text(verbatim: model.rootPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if let issue = model.issue {
                Section {
                    Text(LocalizedStringKey(issue.key))
                        .foregroundStyle(.red)
                    if case .failure(let detail) = issue {
                        Text(verbatim: detail).font(.caption).textSelection(.enabled)
                    }
                }
            }

            if let pending = model.pendingRegistration {
                Section {
                    Text("Git created this checkout. Add it to the workspace to finish.")
                    Text(verbatim: pending.path)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Retry registration") { Task { [model] in await model.retryRegistration() } }
                        .disabled(model.isMutating || model.isLoading || model.isInvalidated)
                }
            }

            if let recovery = model.branchRecovery {
                Section {
                    Text("The checkout was removed, but branch cleanup did not finish.")
                    Text(verbatim: recovery.worktreePath)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    LabeledContent("Branch") { Text(verbatim: recovery.branchName) }
                    Button("Delete remaining branch…") { model.requestBranchCleanup() }
                        .disabled(model.isMutating || model.isLoading || model.isInvalidated)
                }
            }

            if isCreating && model.pendingRegistration == nil {
                creationForm
            }

            Section("Git worktrees") {
                if model.isLoading || model.isMutating {
                    HStack {
                        ProgressView()
                        Text(model.isMutating ? LocalizedStringKey("Updating worktrees…") : LocalizedStringKey("Loading worktrees…"))
                    }
                }
                if model.hasInventory && model.worktrees.isEmpty {
                    Text("No Git worktrees found.").foregroundStyle(.secondary)
                }
                ForEach(model.worktrees) { worktree in
                    worktreeRow(worktree)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { CodegBackground() }
        .navigationTitle("Worktrees")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { [model] in await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh worktrees")
                .disabled(model.isLoading || model.isMutating || model.isInvalidated)
                Button {
                    isCreating.toggle()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New worktree")
                .disabled(!model.canCreate)
            }
        }
        .refreshable { await model.load() }
        .task { model.resumePresentation(); await model.load() }
        .onDisappear { model.suspendPresentation() }
        .sheet(item: Binding(
            get: { model.removalConfirmation },
            set: { if $0 == nil { model.cancelRemoval() } }
        )) { confirmation in
            WorktreeRemovalSheet(serverName: model.serverName, repositoryPath: model.sourceFolder.path,
                                 worktree: confirmation.worktree,
                                 onCancel: { model.cancelRemoval() },
                                 onConfirm: { deleteBranch, force in
                Task { [model] in await model.confirmRemoval(deleteBranch: deleteBranch, force: force) }
            })
        }
        .sheet(isPresented: Binding(
            get: { model.isConfirmingBranchCleanup },
            set: { if !$0 { model.cancelBranchCleanup() } }
        )) {
            if let recovery = model.branchRecovery {
                WorktreeBranchCleanupSheet(serverName: model.serverName, repositoryPath: model.sourceFolder.path,
                                           recovery: recovery, onCancel: { model.cancelBranchCleanup() },
                                           onConfirm: { force in
                    Task { [model] in await model.confirmBranchCleanup(force: force) }
                })
            }
        }
    }

    private var creationForm: some View {
        Section("New worktree") {
            TextField("Branch name", text: $branchName)
                .onChange(of: branchName) { old, new in
                    let prefix = WorktreePaths.normalized(model.sourceFolder.path)
                    let oldSuggestion = prefix + "-" + old.replacingOccurrences(of: "/", with: "-")
                    if worktreePath.isEmpty || worktreePath == oldSuggestion {
                        worktreePath = prefix + "-" + new.replacingOccurrences(of: "/", with: "-")
                    }
                }
            TextField("Base (optional)", text: $base)
            TextField("Absolute checkout path", text: $worktreePath, axis: .vertical)
                .font(.system(.body, design: .monospaced))
            Text("The path is on the initiating server.").font(.caption).foregroundStyle(.secondary)
            Button("Create worktree") {
                Task { [model, branchName, worktreePath, base] in
                    await model.create(branchName: branchName, worktreePath: worktreePath, base: base)
                    guard model.allowsPresentation else { return }
                    if model.pendingRegistration != nil || model.issue == nil { isCreating = false }
                }
            }
            .disabled(!model.canCreate || branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      worktreePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { isCreating = false }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .disabled(model.isMutating || model.isLoading || model.isInvalidated)
    }

    private func worktreeRow(_ worktree: GitWorktreeInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let branch = worktree.branch {
                Label { Text(verbatim: branch) } icon: { Image(systemName: "arrow.triangle.branch") }
            } else {
                Text(worktree.bare ? LocalizedStringKey("Bare repository") : LocalizedStringKey("Detached HEAD"))
            }
            Text(verbatim: worktree.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
            if let head = worktree.head {
                Text(verbatim: head).font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            // Vertical flags remain readable on narrow screens and with large text.
            VStack(alignment: .leading, spacing: 3) {
                if worktree.isMain { Label("Main checkout", systemImage: "house") }
                if WorktreePaths.same(worktree.path, model.sourceFolder.path) {
                    Label("Current checkout", systemImage: "location")
                }
                if worktree.detached { Label("Detached HEAD", systemImage: "link") }
                if worktree.bare { Label("Bare repository", systemImage: "archivebox") }
                if let reason = worktree.locked {
                    Label("Locked", systemImage: "lock")
                    if !reason.isEmpty { Text(verbatim: reason).textSelection(.enabled) }
                }
                if let reason = worktree.prunable {
                    Label("Prunable", systemImage: "exclamationmark.triangle")
                    if !reason.isEmpty { Text(verbatim: reason).textSelection(.enabled) }
                }
                Text(model.registeredFolder(for: worktree) == nil ? LocalizedStringKey("Unregistered checkout") : LocalizedStringKey("Registered folder"))
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open checkout") { Task { [model] in await model.open(worktree) } }
                    .disabled(!model.canOpen(worktree))
                Spacer()
                Button(role: .destructive) { model.requestRemoval(worktree) } label: {
                    Label("Remove checkout…", systemImage: "trash")
                }
                .disabled(!model.canRemove(worktree))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }
}

private struct WorktreeRemovalSheet: View {
    let serverName: String
    let repositoryPath: String
    let worktree: GitWorktreeInfo
    let onCancel: () -> Void
    let onConfirm: (Bool, Bool) -> Void
    @State private var deleteBranch = false
    @State private var force = false

    var body: some View {
        NavigationStack {
            Form {
                WorktreeConfirmationTarget(serverName: serverName, repositoryPath: repositoryPath,
                                           checkoutPath: worktree.path, branch: worktree.branch)
                Section {
                    Text("Removing this checkout deletes its working directory.")
                    if worktree.branch != nil && !worktree.detached {
                        Toggle("Also delete the branch", isOn: $deleteBranch)
                    }
                    Toggle("Force removal", isOn: $force)
                    if force { Text("Force may discard uncommitted changes and delete an unmerged branch.").foregroundStyle(.red) }
                }
                Section {
                    Button("Remove checkout", role: .destructive) { onConfirm(deleteBranch, force) }
                }
            }
            .navigationTitle("Confirm removal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
    }
}

private struct WorktreeBranchCleanupSheet: View {
    let serverName: String
    let repositoryPath: String
    let recovery: WorktreeBranchRecovery
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void
    @State private var force = false

    var body: some View {
        NavigationStack {
            Form {
                WorktreeConfirmationTarget(serverName: serverName, repositoryPath: repositoryPath,
                                           checkoutPath: recovery.worktreePath, branch: recovery.branchName)
                Section {
                    Text("Only the remaining branch will be deleted. The checkout is already removed.")
                    Toggle("Force branch deletion", isOn: $force)
                    if force { Text("Force can delete an unmerged branch.").foregroundStyle(.red) }
                }
                Section {
                    Button("Delete branch", role: .destructive) { onConfirm(force) }
                }
            }
            .navigationTitle("Confirm branch cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
    }
}

private struct WorktreeConfirmationTarget: View {
    let serverName: String
    let repositoryPath: String
    let checkoutPath: String
    let branch: String?

    var body: some View {
        Section {
            LabeledContent("Server") { Text(verbatim: serverName) }
            LabeledContent("Repository") { Text(verbatim: repositoryPath) }
            LabeledContent("Checkout") { Text(verbatim: checkoutPath) }
            if let branch { LabeledContent("Branch") { Text(verbatim: branch) } }
        }
        .textSelection(.enabled)
    }
}
