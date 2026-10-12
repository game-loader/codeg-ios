import Foundation
import Observation

struct RecoveredServerDraft: Identifiable, Codable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let endpoint: String
    let conversationID: Int?
    let text: String
    let createdAt: Date
}

/// Stable owner for one profile generation. Every ID underneath it belongs to
/// this fixed client; names/selection can change without replacing its models.
@MainActor
@Observable
final class ServerWorkspace: Identifiable {
    let id: UUID
    private(set) var server: ServerProfile
    let client: CodegClient?
    let model: AppModel
    let lifetime: ServerBindingLifetime
    @ObservationIgnored private var sessions: [String: SessionDetailViewModel] = [:]
    @ObservationIgnored private let eventStreamFactory: (() -> any SessionEventStream)?
    var activity: ActivityModel { model.activity }
    var isRetired: Bool { !lifetime.isValid }

    init(server: ServerProfile, client: CodegClient?, store: ServerStore,
         eventStreamFactory: (() -> any SessionEventStream)? = nil) {
        let lifetime = ServerBindingLifetime()
        self.lifetime = lifetime
        self.id = lifetime.id
        self.server = server
        self.eventStreamFactory = eventStreamFactory
        self.client = client?.bound(to: lifetime)
        self.model = AppModel(serverStore: store, serverID: server.id,
                              fixedClient: self.client)
    }

    func matches(_ client: CodegClient?) -> Bool {
        self.client?.baseURL == client?.baseURL && self.client?.token == client?.token
    }

    func rename(_ server: ServerProfile) { self.server = server }

    func session(conversationID: Int) -> SessionDetailViewModel? {
        guard !isRetired, let client else { return nil }
        let key = "conversation:\(conversationID)"
        // First-send adoption happens inside the retained draft model. Its live
        // identity also invalidates an alias if that send is later rolled back.
        if let existing = sessions[key], existing.conversationID == conversationID { return existing }
        sessions.removeValue(forKey: key)
        if let adopted = sessions.values.first(where: { $0.conversationID == conversationID }) {
            sessions[key] = adopted
            return adopted
        }
        let created = SessionDetailViewModel(client: client, conversationID: conversationID,
                                            eventStreamFactory: eventStreamFactory)
        sessions[key] = created
        return created
    }

    func session(request: NewSessionRequest) -> SessionDetailViewModel? {
        guard !isRetired, let client else { return nil }
        let key = "draft:\(request.id)"
        if let existing = sessions[key] { return existing }
        let created = SessionDetailViewModel(client: client, newSession: request,
                                            eventStreamFactory: eventStreamFactory)
        sessions[key] = created
        return created
    }

    /// Archives text before disposing subscriptions/uploads. Never writes or
    /// sends recovered content to a replacement endpoint.
    func retire() -> [RecoveredServerDraft] {
        guard !isRetired else { return [] }
        lifetime.invalidate()
        var retiredModels: Set<ObjectIdentifier> = []
        let recovery = sessions.values.compactMap { session -> RecoveredServerDraft? in
            guard retiredModels.insert(ObjectIdentifier(session)).inserted else { return nil }
            let text = session.retirementSnapshot.recoveryText
            session.teardown()
            guard !text.isEmpty else { return nil }
            return RecoveredServerDraft(id: UUID(), serverID: server.id,
                                        serverName: server.name,
                                        endpoint: Self.displayEndpoint(client?.baseURL) ?? server.displayHost,
                                        conversationID: session.conversationID,
                                        text: text, createdAt: Date())
        }
        sessions = [:]
        activity.reset()
        return recovery
    }

    private static func displayEndpoint(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return parts.string
    }
}

/// The window owns profiles; each retained workspace owns its navigation,
/// drafts, streams and activity snapshot. Tokens never enter layout storage.
@MainActor
@Observable
final class ServerWorkspaceRegistry {
    let store: ServerStore
    private(set) var workspaces: [ServerWorkspace] = []
    private(set) var recoveredDrafts: [RecoveredServerDraft] = []
    var manageServersPresented = false
    var recoveryPresented = false
    var selectedServerID: UUID? {
        didSet {
            guard oldValue != selectedServerID else { return }
            defaults.set(selectedServerID?.uuidString, forKey: "codeg.lastSelectedServerID")
            if selectedServerID == secondaryServerID { secondaryServerID = oldValue }
        }
    }
    var secondaryServerID: UUID?
    private let defaults: UserDefaults
    private let clientProvider: (ServerProfile) -> CodegClient?
    @ObservationIgnored private let eventStreamFactory: (() -> any SessionEventStream)?
    private static let recoveryKey = "codeg.multiServer.recoveredDrafts.v1"

    init(store: ServerStore? = nil, defaults: UserDefaults = .standard,
         clientProvider: ((ServerProfile) -> CodegClient?)? = nil,
         eventStreamFactory: (() -> any SessionEventStream)? = nil) {
        let store = store ?? ServerStore(defaults: defaults)
        self.store = store
        self.defaults = defaults
        self.clientProvider = clientProvider ?? { store.client(for: $0) }
        self.eventStreamFactory = eventStreamFactory
        let persisted = defaults.string(forKey: "codeg.lastSelectedServerID").flatMap(UUID.init)
        self.selectedServerID = store.servers.first { $0.id == persisted }?.id ?? store.servers.first?.id
        if let data = defaults.data(forKey: Self.recoveryKey),
           let recovery = try? JSONDecoder().decode([RecoveredServerDraft].self, from: data) {
            recoveredDrafts = recovery
        }
        reconcile()
        store.onProfilesChanged = { [weak self] in self?.reconcile() }
    }

    func workspace(for serverID: UUID?) -> ServerWorkspace? {
        guard let serverID else { return nil }
        return workspaces.first { $0.server.id == serverID }
    }

    func reconcile() {
        var next: [ServerWorkspace] = []
        for profile in store.servers {
            let client = clientProvider(profile)
            if let old = workspace(for: profile.id), old.matches(client),
               old.server.configurationRevision == profile.configurationRevision {
                old.rename(profile)
                next.append(old)
            } else {
                if let old = workspace(for: profile.id) { recoveredDrafts += old.retire() }
                let created = ServerWorkspace(server: profile, client: client, store: store,
                                              eventStreamFactory: eventStreamFactory)
                restoreNavigation(created)
                next.append(created)
            }
        }
        for removed in workspaces where !store.servers.contains(where: { $0.id == removed.server.id }) {
            recoveredDrafts += removed.retire()
        }
        workspaces = next
        if workspace(for: selectedServerID) == nil { selectedServerID = workspaces.first?.server.id }
        if workspace(for: secondaryServerID) == nil { secondaryServerID = nil }
        persistRecovery()
    }

    func openProject(_ folderID: Int, on workspace: ServerWorkspace) {
        guard !workspace.isRetired, workspaces.contains(where: { $0 === workspace }) else { return }
        selectedServerID = workspace.server.id
        workspace.model.selectedTab = .projects
        workspace.model.open(.project(folderID))
    }

    func showSingleServer() { secondaryServerID = nil }

    /// Use the existing strict deep-link resolver, then route only on the
    /// resolved host's retained model. The resolver's temporary reset affects
    /// no existing workspace and cannot discard another server's draft.
    func handle(url: URL, compact: Bool) {
        let resolver = AppModel(serverStore: store, serverID: selectedServerID)
        resolver.isCompact = compact
        resolver.handle(url: url)
        guard let target = workspace(for: resolver.selectedServerID) else { return }
        // Invalid explicit identities leave the temporary resolver untouched.
        guard !resolver.paths.isEmpty || resolver.selectedConversationID != nil
                || !resolver.contentPath.isEmpty || !resolver.settingsPath.isEmpty
                || url.host?.lowercased() == "tab" else { return }
        selectedServerID = target.server.id
        target.model.handle(url: url)
    }

    func discardRecovery(_ id: UUID) {
        recoveredDrafts.removeAll { $0.id == id }
        persistRecovery()
    }

    func saveNavigation(_ workspace: ServerWorkspace) {
        guard !workspace.isRetired else { return }
        let navigation = SavedServerNavigation(workspace: workspace)
        if let data = try? JSONEncoder().encode(navigation) {
            defaults.set(data, forKey: "codeg.multiServer.navigation.v1.\(workspace.server.id)")
        }
    }

    private func restoreNavigation(_ workspace: ServerWorkspace) {
        guard let data = defaults.data(forKey: "codeg.multiServer.navigation.v1.\(workspace.server.id)"),
              let saved = try? JSONDecoder().decode(SavedServerNavigation.self, from: data),
              saved.configurationRevision == workspace.server.configurationRevision else { return }
        saved.restore(into: workspace.model)
        // Saved compact stacks have no regular column selection. Normalize
        // them once so the initial width callback can translate either way
        // without replacing a restored destination with an empty tab root.
        let model = workspace.model
        if model.contentPath.isEmpty, model.selectedConversationID == nil,
           !model.paths[model.selectedTab, default: []].isEmpty {
            model.isCompact = true
            model.transitionShell(isCompact: false)
        }
    }

    private func persistRecovery() {
        if let data = try? JSONEncoder().encode(recoveredDrafts) {
            defaults.set(data, forKey: Self.recoveryKey)
        }
    }
}
