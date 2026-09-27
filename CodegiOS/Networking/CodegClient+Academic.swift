import Foundation

/// Academic endpoints. Every failure the academic core reports is a 400
/// `invalid_input` whose message is meant for display.
extension CodegClient {
    /// The library, select and import calls go to the Zotero app on the server
    /// host (90s per bridge request, two or three requests per call), so they
    /// get the web's 190s / 280s ceilings rather than the 30s default.
    static let academicSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 280
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    func academicSettings() async throws -> AcademicSettings {
        try await postJSON("academic_settings_get", EmptyBody())
    }

    /// `token` nil keeps the stored pairing token (there is no way to clear it).
    func setAcademicSettings(agentType: String, bridgePort: Int, token: String?) async throws -> AcademicSettings {
        try await postJSON("academic_settings_set", AcademicSettingsBody(
            agentType: agentType, bridgePort: bridgePort, token: token
        ))
    }

    func academicLibrary() async throws -> AcademicLibrary {
        try await postJSON("academic_library", EmptyBody(), session: Self.academicSession)
    }

    /// The paper for a library item. Creating it (the first select of an item)
    /// starts preparation in the background; an existing paper comes back as is.
    func academicSelect(itemKey: String, preferences: AcademicAgentPreferences?) async throws -> AcademicPaper {
        try await postJSON("academic_select", AcademicSelectBody(itemKey: itemKey, agentPreferences: preferences),
                           session: Self.academicSession)
    }

    func academicPaper(id: String) async throws -> AcademicPaper {
        try await postJSON("academic_paper_get", AcademicPaperIdBody(paperId: id))
    }

    /// Add a paper to a Zotero collection by arXiv id / URL or DOI; returns the
    /// new library item (not yet a paper — select it to prepare it).
    func academicImport(identifier: String, collectionKey: String) async throws -> AcademicItem {
        try await postJSON("academic_import", AcademicImportBody(identifier: identifier, collectionKey: collectionKey),
                           session: Self.academicSession)
    }

    /// (Re)start preparation: after a failure, with a chosen arXiv match, or
    /// with a chosen repository. A running job is left alone.
    func academicPrepare(
        paperId: String,
        arxivId: String? = nil,
        repoUrl: String? = nil,
        preferences: AcademicAgentPreferences?
    ) async throws -> AcademicPaper {
        try await postJSON("academic_prepare", AcademicPrepareBody(
            paperId: paperId, arxivId: arxivId, repoUrl: repoUrl, agentPreferences: preferences
        ))
    }

    /// Response is `null`.
    func academicCancel(paperId: String) async throws {
        try await send("academic_cancel", body: AcademicPaperIdBody(paperId: paperId))
    }

    /// Where to open a conversation about the paper. `withoutCode: false`
    /// needs a `ready` paper and registers its repository as a folder.
    func academicOpenTarget(paperId: String, withoutCode: Bool) async throws -> AcademicOpenTarget {
        try await postJSON("academic_open_target", AcademicOpenTargetBody(paperId: paperId, withoutCode: withoutCode))
    }

    /// The paper a conversation is bound to, or nil.
    func academicConversationPaper(conversationId: Int) async throws -> AcademicPaper? {
        let data = try await send("academic_conversation_paper", body: ConversationIdBody(conversationId: conversationId))
        if Self.isJSONNull(data) { return nil }
        do { return try CodegJSON.decoder.decode(AcademicPaper.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// A scratch directory for a chat-mode (no folder) conversation, so the
    /// agent can connect at a real cwd before the conversation exists.
    func createChatDir() async throws -> String {
        let created: ChatDirCreated = try await postJSON("create_chat_dir", EmptyBody())
        return created.path
    }

    /// Create a chat-mode conversation (and its `chat` folder) in `existingDir`,
    /// bound to a paper in the same transaction when `academicPaperId` is set.
    func createChatConversation(
        agentType: AgentType,
        title: String?,
        academicPaperId: String?,
        existingDir: String?
    ) async throws -> ChatConversationCreated {
        try await postJSON("create_chat_conversation", CreateChatConversationBody(
            agentType: agentType, title: title, academicPaperId: academicPaperId, existingDir: existingDir
        ))
    }
}

private struct AcademicSettingsBody: Encodable {
    let agentType: String
    let bridgePort: Int
    let token: String?
}

private struct AcademicSelectBody: Encodable {
    let itemKey: String
    let agentPreferences: AcademicAgentPreferences?
}

private struct AcademicPaperIdBody: Encodable {
    let paperId: String
}

private struct AcademicImportBody: Encodable {
    let identifier: String
    let collectionKey: String
}

private struct AcademicPrepareBody: Encodable {
    let paperId: String
    let arxivId: String?
    let repoUrl: String?
    let agentPreferences: AcademicAgentPreferences?
}

private struct AcademicOpenTargetBody: Encodable {
    let paperId: String
    let withoutCode: Bool
}

private struct CreateChatConversationBody: Encodable {
    let agentType: AgentType
    let title: String?
    let academicPaperId: String?
    let existingDir: String?
}
