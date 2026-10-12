import SwiftUI

/// Host-qualified catalog. A disclosure never changes the selected execution
/// target; opening a row explicitly selects its owning retained workspace.
struct MultiServerProjectListView: View {
    @Bindable var registry: ServerWorkspaceRegistry
    let workspace: ServerWorkspace
    var onOpenTool: ((WorkspaceTool) -> Void)?
    @State private var target: FolderTarget?
    @State private var browseServer: ServerWorkspace?
    @State private var cloneServer: ServerWorkspace?
    @State private var actionError: String?
    @Environment(\.serverWorkspaceVisible) private var isVisible

    private struct FolderTarget: Identifiable {
        let id = UUID()
        let workspace: ServerWorkspace
        let folder: FolderDetail
    }

    var body: some View {
        List {
            if let onOpenTool {
                Section("Tools") {
                    ForEach(WorkspaceTool.allCases, id: \.self) { tool in
                        Button { onOpenTool(tool) } label: { Label(tool.title, systemImage: tool.systemImage) }
                    }
                }
            }
            ForEach(registry.workspaces) { owner in
                Section {
                    serverCatalog(owner)
                } header: {
                    HStack {
                        Text(owner.server.name)
                        Spacer()
                        if owner.server.id == registry.selectedServerID { Image(systemName: "checkmark") }
                    }
                } footer: {
                    Text(owner.server.displayHost)
                }
            }
        }
        .navigationTitle("Servers & Worktrees")
        .scrollContentBackground(.hidden)
        .background { CodegBackground() }
        .onChange(of: isVisible) { _, visible in
            if !visible { target = nil; browseServer = nil; cloneServer = nil }
        }
        .refreshable { await refreshAll() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if registry.secondaryServerID != nil {
                        Button("Single Server") { registry.showSingleServer() }
                    }
                    Button("Manage Servers…") { registry.manageServersPresented = true }
                    if !registry.recoveredDrafts.isEmpty {
                        Button("Recovered Drafts") { registry.recoveryPresented = true }
                    }
                } label: { Image(systemName: "server.rack") }
            }
        }
        .sheet(item: $target) { target in
            if let client = target.workspace.client, !target.workspace.isRetired {
                NavigationStack {
                    WorktreeListView(client: client, folder: target.folder,
                                     serverName: target.workspace.server.name,
                                     onOpenFolder: { folder in
                        guard !target.workspace.isRetired else { return }
                        self.target = nil
                        registry.openProject(folder.id, on: target.workspace)
                    }, onFoldersChanged: {
                        Task { await target.workspace.activity.refresh(client: client) }
                    })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { self.target = nil }
                        }
                    }
                }
            }
        }
        .sheet(item: $browseServer) { owner in
            if let client = owner.client, !owner.isRetired {
                DirectoryBrowserView(client: client) { path in
                    Task {
                        do {
                            _ = try await client.openFolder(path: path)
                            guard !owner.isRetired else { return }
                            await owner.activity.refresh(client: client)
                        } catch is CancellationError {} catch {
                            guard !owner.isRetired else { return }
                            actionError = error.localizedDescription
                        }
                    }
                }
            }
        }
        .sheet(item: $cloneServer) { owner in
            if let client = owner.client, !owner.isRetired {
                CloneRepoView(client: client) {
                    Task { await owner.activity.refresh(client: client) }
                }
            }
        }
        .alert("Couldn’t Open Folder", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) { Button("OK", role: .cancel) { actionError = nil } }
        message: { Text(actionError ?? "") }
    }

    @ViewBuilder
    private func serverCatalog(_ owner: ServerWorkspace) -> some View {
        if owner.client == nil {
            Label("Server Unavailable", systemImage: "key.slash")
        } else {
            if let error = owner.activity.error {
                Text(error).font(.caption).foregroundStyle(Theme.textSecondary)
                Button("Retry") { Task { await owner.activity.refresh(client: owner.client) } }
            }
            if !owner.activity.hasLoaded {
                ProgressView("Loading folders…")
            }
            ForEach(owner.activity.displayFolders.sorted { $0.sortOrder < $1.sortOrder }) { folder in
                DisclosureGroup {
                    Button("Open Folder") { registry.openProject(folder.id, on: owner) }
                    ForEach(owner.activity.folders.filter { $0.parentId == folder.id && $0.kind == .regular }) { child in
                        Button { registry.openProject(child.id, on: owner) } label: {
                            VStack(alignment: .leading) {
                                Label(child.gitBranch ?? child.displayName, systemImage: "arrow.triangle.branch")
                                Text(child.path).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    Button { target = FolderTarget(workspace: owner, folder: folder) } label: {
                        Label("Manage Worktrees", systemImage: "arrow.triangle.branch")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.displayName)
                        Text(folder.path).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Button { browseServer = owner } label: { Label("Open Folder", systemImage: "folder.badge.plus") }
            Button { cloneServer = owner } label: { Label("Clone Repository", systemImage: "arrow.triangle.branch") }
        }
    }

    private func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for owner in registry.workspaces where !owner.isRetired {
                group.addTask { await owner.activity.refresh(client: owner.client) }
            }
        }
    }
}
