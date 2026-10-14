import Foundation
import Observation

/// One page owns one endpoint generation. The guard checks identity only; it
/// never fetches or substitutes a new client after an await.
@MainActor
@Observable
final class GenerativeUISettingsModel {
    let serverID: UUID?
    let configurationRevision: UUID?
    let serverName: String
    let serverLocation: String
    private(set) var skill: GenerativeUISkillInfo?
    private(set) var agents: [GenerativeUIAgent] = []
    private(set) var statuses: [AgentType: ExpertInstallStatus] = [:]
    private(set) var actionErrors: [AgentType: String] = [:]
    private(set) var busyAgents: Set<AgentType> = []
    private(set) var isLoading = false
    private(set) var needsRefresh = true
    private(set) var isRetired = false
    private(set) var loadError: String?
    private(set) var unsupported = false

    @ObservationIgnored private let client: CodegClient?
    @ObservationIgnored private let pageLifetime = ServerBindingLifetime()
    @ObservationIgnored private let scopeIsCurrent: @MainActor () -> Bool

    init(client: CodegClient?, serverID: UUID?, configurationRevision: UUID?,
         serverName: String, serverLocation: String,
         scopeIsCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.serverID = serverID
        self.configurationRevision = configurationRevision
        self.serverName = serverName
        self.serverLocation = serverLocation
        self.scopeIsCurrent = scopeIsCurrent
        self.client = client?.bindingLifetime == nil ? client?.bound(to: pageLifetime) : client
    }

    var isCurrent: Bool {
        !isRetired && pageLifetime.isValid && client?.bindingLifetime?.isValid != false && scopeIsCurrent()
    }

    func retire() {
        pageLifetime.invalidate()
        isRetired = true
        isLoading = false
        busyAgents = []
    }

    private func checkScope() throws {
        try Task.checkCancellation()
        guard isCurrent else { retire(); throw CancellationError() }
        try client?.checkBinding()
    }

    func status(for agent: GenerativeUIAgent) -> ExpertInstallStatus? {
        guard agents.contains(agent), agent.canManageSkills else { return nil }
        return statuses[agent.agentType]
    }

    func canChange(_ agent: GenerativeUIAgent) -> Bool {
        guard isCurrent, !isLoading, busyAgents.isEmpty, !needsRefresh, !unsupported,
              skill?.conflict == false, let status = status(for: agent) else { return false }
        switch status.state {
        case .linkedToCodeg, .notLinked: return true
        case .linkedElsewhere, .blockedByRealDirectory, .broken: return false
        }
    }

    func load() async {
        guard !isLoading, busyAgents.isEmpty else { return }
        do { try checkScope() } catch { return }
        guard let client else {
            loadError = String(localized: "No server selected.")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let info = Self.result { try await client.generativeUISkillInfo() }
            async let list = Self.result { try await client.generativeUIAgents() }
            async let snapshot = Self.result { try await client.generativeUIInstallStatuses() }
            let fetched = await (info, list, snapshot)
            try checkScope()
            let (newSkill, newAgents, newStatuses) = try (fetched.0.get(), fetched.1.get(), fetched.2.get())
            // A duplicate wire type is ambiguous even when registry IDs differ.
            let counts = Dictionary(grouping: newAgents, by: \.agentType)
            agents = newAgents.filter { $0.canManageSkills && counts[$0.agentType]?.count == 1 }
                .sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
            statuses = Self.indexStatuses(newStatuses)
            skill = newSkill
            loadError = nil
            unsupported = false
            needsRefresh = false
            actionErrors = [:]
        } catch {
            guard (try? checkScope()) != nil else { return }
            needsRefresh = true
            unsupported = error is GenerativeUISettingsError
            loadError = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, for agent: GenerativeUIAgent) async {
        guard canChange(agent) else { return }
        await apply([GenerativeUILinkOp(agentType: agent.agentType, enable: enabled)])
    }

    /// Serialize batches because agents may share a skill directory. Keep the
    /// confirmed snapshot during the write, then reconcile every agent from disk.
    func apply(_ ops: [GenerativeUILinkOp]) async {
        guard !ops.isEmpty, let client, Set(ops.map(\.agentType)).count == ops.count,
              ops.allSatisfy({ op in
                  agents.contains { $0.agentType == op.agentType && canChange($0) }
              }) else { return }
        do { try checkScope() } catch { return }
        busyAgents = Set(ops.map(\.agentType))
        for op in ops { actionErrors[op.agentType] = nil }
        defer { busyAgents = [] }
        var failures: [AgentType: String] = [:]
        do {
            let results = try await client.generativeUIApplyLinks(ops)
            try checkScope()
            for op in ops {
                let matches = results.filter { $0.expertId == op.expertId && $0.agentType == op.agentType }
                guard results.count == ops.count, matches.count == 1, let result = matches.first,
                      result.status.map({ $0.expertId == op.expertId && $0.agentType == op.agentType }) != false else {
                    failures[op.agentType] = GenerativeUISettingsError.invalidResults.localizedDescription
                    continue
                }
                if !result.ok || result.error != nil {
                    failures[op.agentType] = result.error ?? String(localized: "Could not change UI Render for this agent.")
                }
            }
        } catch {
            guard (try? checkScope()) != nil else { return }
            if case GenerativeUISettingsError.unsupported = error { unsupported = true }
            for op in ops { failures[op.agentType] = error.localizedDescription }
        }
        do {
            // Even a failed operation can have changed a link before a later
            // filesystem step failed. Never infer state from its ok flag.
            async let snapshot = Self.result { try await client.generativeUIInstallStatuses() }
            async let info = Self.result { try await client.generativeUISkillInfo() }
            let fetched = await (snapshot, info)
            try checkScope()
            let (newStatuses, newSkill) = try (fetched.0.get(), fetched.1.get())
            statuses = Self.indexStatuses(newStatuses)
            skill = newSkill
            needsRefresh = false
            loadError = nil
            for op in ops where failures[op.agentType] == nil {
                guard let status = statuses[op.agentType], status.state.isLinked == op.enable else {
                    failures[op.agentType] = String(localized: "The server did not confirm the requested UI Render state.")
                    continue
                }
            }
        } catch {
            guard (try? checkScope()) != nil else { return }
            needsRefresh = true
            loadError = error.localizedDescription
            for op in ops where failures[op.agentType] == nil {
                failures[op.agentType] = String(localized: "The current UI Render status could not be verified. Refresh before retrying.")
            }
        }
        guard (try? checkScope()) != nil else { return }
        actionErrors.merge(failures) { _, new in new }
    }

    private static func indexStatuses(_ snapshot: [ExpertInstallStatus]) -> [AgentType: ExpertInstallStatus] {
        let groups = Dictionary(grouping: snapshot.filter { $0.expertId == GenerativeUISkillInfo.skillID }, by: \.agentType)
        return groups.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// Drain the parallel reads before handling an error; a failed endpoint must
    /// not leave another read racing a retry or publishing a partial snapshot.
    private nonisolated static func result<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
