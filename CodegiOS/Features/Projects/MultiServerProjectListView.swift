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
            Section {
                Picker("Catalog View", selection: $registry.projectCatalogViewMode) {
                    Text("Projects").tag(ProjectCatalogViewMode.projects)
                    Text("Servers").tag(ProjectCatalogViewMode.servers)
                }
                .pickerStyle(.segmented)
            }
            if registry.projectCatalogViewMode == .projects {
                Section("Projects") {
                    ForEach(registry.logicalProjects) { project in
                        DisclosureGroup {
                            ForEach(project.setups) { setup in
                                if let owner = registry.owner(of: setup.reference) {
                                    setupRow(setup, owner: owner)
                                }
                            }
                        } label: { Text(verbatim: project.name) }
                    }
                }
            }
            ForEach(registry.workspaces) { owner in
                Section {
                    serverStatus(owner)
                    if registry.projectCatalogViewMode == .servers {
                        ForEach(setups(on: owner)) { setup in
                            setupRow(setup, owner: owner)
                        }
                    }
                    if owner.client != nil {
                        Button { browseServer = owner } label: { Label("Open Folder", systemImage: "folder.badge.plus") }
                        Button { cloneServer = owner } label: { Label("Clone Repository", systemImage: "arrow.triangle.branch") }
                    }
                } header: {
                    HStack {
                        Text(owner.server.name)
                        Spacer()
                        if owner.server.id == registry.selectedServerID { Image(systemName: "checkmark") }
                    }
                } footer: { Text(owner.server.displayHost) }
            }
        }
        .navigationTitle("Projects")
        .scrollContentBackground(.hidden)
        .background { CodegBackground() }
        .onChange(of: isVisible) { _, visible in
            if !visible { target = nil; browseServer = nil; cloneServer = nil }
        }
        .refreshable { await refreshAll() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu("Split Servers") {
                        Button("Single Server") { registry.showSingleServer() }
                        ForEach(registry.workspaces.filter { $0.server.id != registry.selectedServerID }) { other in
                            Button(other.server.name) { registry.secondaryServerID = other.server.id }
                        }
                    }
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
            if let client = target.workspace.client, !target.workspace.isRetired,
               target.workspace.projectCatalog.folder(id: target.folder.id)?.path == target.folder.path {
                NavigationStack {
                    WorktreeListView(client: client, folder: target.folder,
                                     serverName: target.workspace.server.name,
                                     onOpenFolder: { folder in
                        guard !target.workspace.isRetired else { return }
                        self.target = nil
                        registry.openProject(folder.id, on: target.workspace)
                        Task { await target.workspace.projectCatalog.refresh(force: true) }
                    }, onFoldersChanged: {
                        Task { await target.workspace.projectCatalog.refresh(force: true) }
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
                            await owner.projectCatalog.refresh(force: true)
                            Task { await owner.activity.refresh(client: client) }
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
                    Task { await owner.projectCatalog.refresh(force: true) }
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
    private func serverStatus(_ owner: ServerWorkspace) -> some View {
        if owner.client == nil {
            Label("Server Unavailable", systemImage: "key.slash")
        } else {
            if owner.projectCatalog.isLoading { ProgressView("Loading folders…") }
            if let issue = owner.projectCatalog.folderIssue {
                Text(LocalizedStringKey(issue.message)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let issue = owner.projectCatalog.identityIssue {
                Text(LocalizedStringKey(issue.message)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if owner.projectCatalog.folderIssue != nil || owner.projectCatalog.identityIssue != nil {
                Button("Retry") { Task { await owner.projectCatalog.refresh(force: true) } }
            }
            if owner.projectCatalog.hasLoaded && owner.projectCatalog.setupFolders.isEmpty {
                Text("No Open Folders").foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func setups(on owner: ServerWorkspace) -> [ProjectHostSetup] {
        LogicalProjectProjection.projects([
            owner.projectCatalog.snapshot(serverID: owner.server.id, configurationRevision: owner.server.configurationRevision)
        ]).flatMap(\.setups)
    }

    private func setupRow(_ setup: ProjectHostSetup, owner: ServerWorkspace) -> some View {
        DisclosureGroup {
            Button("Open Folder") {
                guard registry.owner(of: setup.reference) === owner else { return }
                registry.openProject(setup.folder.id, on: owner)
            }
            ForEach(setup.worktrees) { child in
                Button {
                    guard registry.owner(of: setup.reference) === owner,
                          owner.projectCatalog.folder(id: child.id)?.path == child.path else { return }
                    registry.openProject(child.id, on: owner)
                } label: {
                    VStack(alignment: .leading) {
                        Label(child.gitBranch ?? child.displayName, systemImage: "arrow.triangle.branch")
                        Text(child.path).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Button {
                guard registry.owner(of: setup.reference) === owner else { return }
                target = FolderTarget(workspace: owner, folder: setup.folder)
            } label: { Label("Manage Worktrees", systemImage: "arrow.triangle.branch") }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(setup.folder.displayName)
                Text(owner.server.name).font(.caption).foregroundStyle(Theme.textSecondary)
                Text(setup.path).font(.caption).foregroundStyle(Theme.textSecondary)
                if setup.identity?.availability == .unavailable {
                    Text("Identity unavailable").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for owner in registry.workspaces where !owner.isRetired {
                group.addTask { await owner.projectCatalog.refresh(force: true) }
                // History keeps its existing pulse; a held conversation does not
                // delay publication or navigation of the independent catalog.
                group.addTask { await owner.activity.refresh(client: owner.client) }
            }
        }
    }
}
