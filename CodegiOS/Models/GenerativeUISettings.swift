import Foundation

struct GenerativeUISkillInfo: Decodable, Equatable, Sendable {
    static let skillID = "ui-render"
    let id: String
    let conflict: Bool
}

/// A small projection of acp_list_agents that includes the server's skill-store
/// capability. Keep the full wire identity, including custom:<registry-id>.
struct GenerativeUIAgent: Decodable, Identifiable, Equatable, Sendable {
    let agentType: AgentType
    let registryId: String
    let name: String
    let available: Bool
    let enabled: Bool
    let sortOrder: Int
    let skillsCapable: Bool
    let env: [String: String]?

    var id: String { "\(agentType.rawValue)|\(registryId)" }
    var canManageSkills: Bool {
        guard skillsCapable else { return false }
        if let customID = agentType.customAgentID, customID != registryId { return false }
        // Match the web settings: the shared store doesn't manage a custom pi dir.
        return agentType != .pi || (env?["PI_CODING_AGENT_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The only write this feature exposes. No caller-supplied skill id or path.
struct GenerativeUILinkOp: Encodable, Equatable, Sendable {
    let agentType: AgentType
    let enable: Bool
    var expertId: String { GenerativeUISkillInfo.skillID }

    enum CodingKeys: String, CodingKey { case expertId, agentType, enable }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expertId, forKey: .expertId)
        try c.encode(agentType, forKey: .agentType)
        try c.encode(enable, forKey: .enable)
    }
}

struct GenerativeUILinkResult: Decodable, Sendable {
    let expertId: String
    let agentType: AgentType
    let ok: Bool
    let status: ExpertInstallStatus?
    let error: String?
}

enum GenerativeUISettingsError: LocalizedError {
    case unsupported
    case invalidResults

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "UI Render requires Codeg server 0.35.1 or later. Upgrade this server and retry.")
        case .invalidResults:
            return String(localized: "The server returned an incomplete or mismatched UI Render result. Refresh before retrying.")
        }
    }
}
