import SwiftUI

/// Prefer the runtime's already-bound transport when the shell supplies it.
/// Existing settings shells have no workspace environment, so their fallback
/// adds a page lifetime plus an exact profile-revision guard.
struct GenerativeUISettingsDestination: View {
    let store: ServerStore
    let server: ServerProfile?
    @Environment(ServerWorkspace.self) private var workspace: ServerWorkspace?
    @Environment(ServerWorkspaceRegistry.self) private var registry: ServerWorkspaceRegistry?

    var body: some View {
        let runtime = matchingWorkspace
        let client = runtime != nil ? runtime?.client : server.flatMap { store.client(for: $0) }
        GenerativeUISettingsView(
            client: client, server: server,
            scopeIsCurrent: {
                guard let server else { return true }
                return store.servers.contains {
                    $0.id == server.id && $0.configurationRevision == server.configurationRevision
                } && runtime?.isRetired != true
            }
        )
        .id("\(server?.id.uuidString ?? "none")|\(server?.configurationRevision.uuidString ?? "none")")
    }

    private var matchingWorkspace: ServerWorkspace? {
        guard let server else { return nil }
        if let workspace, workspace.server.id == server.id,
           workspace.server.configurationRevision == server.configurationRevision { return workspace }
        guard let candidate = registry?.workspace(for: server.id),
              candidate.server.configurationRevision == server.configurationRevision else { return nil }
        return candidate
    }
}

struct GenerativeUISettingsView: View {
    @State private var model: GenerativeUISettingsModel
    @State private var actionTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(client: CodegClient?, server: ServerProfile?,
         scopeIsCurrent: @escaping @MainActor () -> Bool = { true }) {
        _model = State(initialValue: GenerativeUISettingsModel(
            client: client, serverID: server?.id, configurationRevision: server?.configurationRevision,
            serverName: server?.name ?? "", serverLocation: server?.baseURL?.absoluteString ?? "",
            scopeIsCurrent: scopeIsCurrent))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    serverSection
                    Text("Enable the ui-render skill for agents on this server. Ask an enabled agent to use /ui-render (or $ui-render in Codex) to create UI cards and charts.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    if !model.isCurrent {
                        notice("This server connection was replaced or removed. Reopen UI Render settings.", error: true)
                    } else if model.isLoading && model.skill == nil {
                        ProgressView("Loading UI Render…")
                    }
                    if let error = model.loadError {
                        Text(error).font(.callout).foregroundStyle(Theme.danger)
                    }
                    if model.skill?.conflict == true {
                        notice("A skill named ui-render already exists in this server’s shared skill store. Rename your own skill on the server before enabling UI Render.", error: true)
                    }
                    if model.skill != nil {
                        agentsSection
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .screenTitle("UI Render", compact: horizontalSizeClass == .compact)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { actionTask = Task { await model.load() } }
                    .disabled(model.isLoading || !model.busyAgents.isEmpty || !model.isCurrent)
            }
        }
        .task { await model.load() }
        .onDisappear { actionTask?.cancel(); actionTask = nil }
    }

    private var serverSection: some View {
        EditorSection(title: "Server") {
            VStack(alignment: .leading, spacing: 5) {
                if model.serverID != nil {
                    Text(model.serverName).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(model.serverLocation)
                        .font(.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                } else {
                    Text("No server selected.").foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var agentsSection: some View {
        EditorSection(title: "Agents") {
            if model.agents.isEmpty {
                Text("No agents with a supported skill store are available on this server.")
                    .font(.callout).foregroundStyle(Theme.textSecondary).padding(16)
            }
            ForEach(Array(model.agents.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { SettingsRowDivider() }
                agentRow(agent)
            }
        }
    }

    private func agentRow(_ agent: GenerativeUIAgent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.status(for: agent)?.state.isLinked == true },
                set: { enabled in actionTask = Task { await model.setEnabled(enabled, for: agent) } }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(agent.agentType.rawValue).font(.caption).foregroundStyle(Theme.textTertiary)
                    Text(agent.available ? LocalizedStringKey("Installed") : LocalizedStringKey("Not installed"))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    if !agent.enabled {
                        Text("Agent disabled").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .disabled(!model.canChange(agent))
            if model.busyAgents.contains(agent.agentType) {
                ProgressView("Updating UI Render…").font(.caption)
            }
            if let status = model.status(for: agent) {
                Text(stateTitle(status.state)).font(.caption).foregroundStyle(Theme.textSecondary)
                if [.linkedElsewhere, .blockedByRealDirectory, .broken].contains(status.state) {
                    Text("The existing skill entry cannot be changed here. Resolve it on this server, then refresh.")
                        .font(.caption).foregroundStyle(Theme.danger)
                }
            } else {
                Text("Installation status unavailable").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let error = model.actionErrors[agent.agentType] {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(16)
    }

    private func notice(_ text: LocalizedStringKey, error: Bool) -> some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle") }
            .font(.callout)
            .foregroundStyle(error ? Theme.danger : Theme.textSecondary)
    }

    private func stateTitle(_ state: ExpertLinkState) -> LocalizedStringKey {
        switch state {
        case .notLinked: "UI Render disabled"
        case .linkedToCodeg: "UI Render enabled"
        case .linkedElsewhere: "Linked to another skill"
        case .blockedByRealDirectory: "Blocked by an existing directory"
        case .broken: "Broken skill link"
        }
    }
}
