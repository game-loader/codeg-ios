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
        let reference: ProjectSetupReference
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
                        projectRow(project)
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
               registry.owner(of: target.reference) === target.workspace {
                NavigationStack {
                    WorktreeListView(client: client, folder: target.folder,
                                     serverName: target.workspace.server.name,
                                     isCurrent: { registry.owner(of: target.reference) === target.workspace },
                                     onOpenFolder: { folder in
                        guard registry.owner(of: target.reference) === target.workspace else { return }
                        self.target = nil
                        registry.openProject(folder.id, on: target.workspace)
                        Task { await target.workspace.projectCatalog.refresh(force: true) }
                    }, onFoldersChanged: {
                        guard registry.owner(of: target.reference) === target.workspace else { return }
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

    private func projectRow(_ project: LogicalProject) -> some View {
        let sessions = registry.history(for: project)
        let owners = registry.workspaces.filter { owner in
            project.setups.contains { registry.owner(of: $0.reference) === owner }
        }
        return DisclosureGroup {
            ForEach(owners) { owner in historyStatus(owner) }
            if sessions.isEmpty && registry.hasLoadedHistory(for: project) {
                Text("No Sessions Yet").foregroundStyle(Theme.textSecondary)
            }
            ForEach(sessions) { session in
                if let owner = registry.owner(of: session.reference.location) {
                    projectSessionRow(session, owner: owner)
                }
            }
        } label: {
            HStack {
                Text(verbatim: project.name)
                Spacer()
                projectActions(project)
            }
        }
    }

    private func projectSessionRow(_ session: LogicalProjectSession, owner: ServerWorkspace) -> some View {
        Button { registry.openExistingSession(session.reference) } label: {
            VStack(alignment: .leading, spacing: 3) {
                SessionRow(conversation: session.conversation,
                           isSelected: owner.model.selectedConversationID == session.reference.conversationID)
                    .environment(\.conversationTagsModel, owner.conversationTags)
                HStack(spacing: 8) {
                    Label { Text(verbatim: owner.server.name) } icon: { Image(systemName: "server.rack") }
                    Label {
                        if session.folder.isWorktree { Text("Worktree Sessions") }
                        else { Text("Repository Sessions") }
                    } icon: {
                        Image(systemName: session.folder.isWorktree ? "arrow.triangle.branch" : "folder")
                    }
                    if session.conversation.isPinned { Image(systemName: "pin.fill") }
                }
                .font(.caption2).foregroundStyle(Theme.textSecondary)
                Text(verbatim: session.reference.location.path)
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if session.folder.isWorktree, let branch = session.folder.gitBranch {
                    Text(verbatim: branch).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func projectActions(_ project: LogicalProject) -> some View {
        let locations = LogicalProjectHistory.locations(for: project)
        return Menu {
            Menu("New Task") {
                ForEach(locations) { location in
                    if let owner = registry.owner(of: location.reference) {
                        Button { registry.openNewSession(at: location.reference) } label: {
                            locationLabel(location, owner: owner)
                        }
                    }
                }
            }
            Menu("Open Folder") {
                ForEach(locations) { location in
                    if let owner = registry.owner(of: location.reference) {
                        Button { registry.openProject(at: location.reference) } label: {
                            locationLabel(location, owner: owner)
                        }
                    }
                }
            }
            Menu("Manage Worktrees") {
                ForEach(locations) { location in
                    if let owner = registry.owner(of: location.reference) {
                        Button {
                            guard registry.owner(of: location.reference) === owner else { return }
                            target = FolderTarget(workspace: owner, folder: location.folder, reference: location.reference)
                        } label: {
                            locationLabel(location, owner: owner)
                        }
                    }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel("Project Actions")
    }

    private func locationLabel(_ location: ProjectHistoryLocation, owner: ServerWorkspace) -> some View {
        Label {
            Text(verbatim: "\(owner.server.name) · \(location.folder.gitBranch ?? location.folder.displayName) · \(location.reference.path)")
        } icon: {
            Image(systemName: location.folder.isWorktree ? "arrow.triangle.branch" : "folder")
        }
    }

    @ViewBuilder
    private func historyStatus(_ owner: ServerWorkspace) -> some View {
        if owner.client != nil {
            if let error = owner.activity.conversationsError {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: owner.server.name).font(.caption.weight(.semibold))
                    Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Button("Retry Sessions") { Task { await owner.activity.refresh(client: owner.client) } }
            } else if !owner.activity.hasLoadedConversations {
                HStack {
                    Text(verbatim: owner.server.name).font(.caption)
                    ProgressView("Loading sessions…")
                }
            }
        }
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
            // Also show history state when project disclosures are collapsed.
            historyStatus(owner)
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
                target = FolderTarget(workspace: owner, folder: setup.folder, reference: setup.reference)
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
                group.addTask { await owner.conversationTags?.load() }
                // History keeps its existing pulse; a held conversation does not
                // delay publication or navigation of the independent catalog.
                group.addTask { await owner.activity.refresh(client: owner.client) }
            }
        }
    }
}
