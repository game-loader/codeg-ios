import Foundation

extension CodegClient {
    func generativeUISkillInfo() async throws -> GenerativeUISkillInfo {
        let info: GenerativeUISkillInfo = try await generativeUIRead("generative_ui_skill_info")
        guard info.id == GenerativeUISkillInfo.skillID else { throw GenerativeUISettingsError.unsupported }
        return info
    }

    func generativeUIAgents() async throws -> [GenerativeUIAgent] {
        try await generativeUIRead("acp_list_agents")
    }

    func generativeUIInstallStatuses() async throws -> [ExpertInstallStatus] {
        try await generativeUIRead("generative_ui_list_all_install_statuses")
    }

    func generativeUIApplyLinks(_ ops: [GenerativeUILinkOp]) async throws -> [GenerativeUILinkResult] {
        struct Body: Encodable { let ops: [GenerativeUILinkOp] }
        do {
            return try await postJSON("generative_ui_apply_links", Body(ops: ops))
        } catch { throw Self.generativeUIError(error) }
    }

    private func generativeUIRead<T: Decodable>(_ endpoint: String) async throws -> T {
        do { return try await postReadJSON(endpoint, EmptyBody()) }
        catch { throw Self.generativeUIError(error) }
    }

    private static func generativeUIError(_ error: Error) -> Error {
        guard let api = error as? APIError else { return error }
        switch api {
        case .decoding:
            return GenerativeUISettingsError.unsupported
        case .server(let status, let code, _, _):
            // The server's API fallback is 501/not_implemented. A resource 404
            // with a domain error code is a real failure, not a version hint.
            if (status == 501 && (code == nil || code == "not_implemented"))
                || ((status == 404 || status == 405) && (code == nil || code == "not_found" || code == "not_implemented")) {
                return GenerativeUISettingsError.unsupported
            }
            return error
        default: return error
        }
    }
}
