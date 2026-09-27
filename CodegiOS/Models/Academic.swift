import Foundation

// Academic: papers from the server's paired Zotero library, prepared by a
// research agent (PDF → text → analysis → verified code repository), and chat
// conversations bound to a paper (`src-tauri/src/academic`). Responses are
// snake_case and decode with the shared `CodegJSON.decoder`.

/// `academic_settings_get` / `_set`. `paired` only says a bridge token is
/// stored; the token itself is write-only.
struct AcademicSettings: Decodable, Hashable, Sendable {
    /// The research agent (an `AgentType` wire value).
    let agentType: String
    /// Port of the Codeg Bridge plugin in the Zotero app on the server host.
    let bridgePort: Int
    let paired: Bool
    /// Newer servers: whether agents get the Zotero MCP tools.
    let mcpEnabled: Bool?
}

struct AcademicCollection: Decodable, Hashable, Identifiable, Sendable {
    let key: String
    let name: String
    let parentKey: String?

    var id: String { key }
}

/// A regular item of the Zotero library.
struct AcademicItem: Decodable, Hashable, Identifiable, Sendable {
    let key: String
    let title: String
    let abstractText: String
    let authors: [String]
    let doi: String?
    let url: String?
    /// Collection keys.
    let collections: [String]

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, title, abstractText, authors, doi, url, collections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        abstractText = try c.decodeIfPresent(String.self, forKey: .abstractText) ?? ""
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        doi = try c.decodeIfPresent(String.self, forKey: .doi)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        collections = try c.decodeIfPresent([String].self, forKey: .collections) ?? []
    }
}

/// `academic_library`: the whole personal library, fetched live from Zotero
/// (no paging, no server-side search).
struct AcademicLibrary: Decodable, Sendable {
    let libraryId: Int
    let instanceId: String
    let collections: [AcademicCollection]
    let items: [AcademicItem]
}

struct ArxivCandidate: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let authors: [String]
    let summary: String
    let pdfUrl: String
}

struct RepositoryCandidate: Decodable, Hashable, Identifiable, Sendable {
    let url: String
    let evidenceQuote: String
    let sourceUrl: String?
    let license: String?

    var id: String { url }
}

/// A conversation bound to a paper (the analysis chats included).
struct AcademicConversation: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let folderId: Int
    let agentType: String
    let title: String?
}

/// A paper being (or done being) prepared.
struct AcademicPaper: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let itemKey: String
    let title: String
    let authors: [String]
    let abstractText: String
    let doi: String?
    let arxivId: String?
    let pdfPath: String?
    let textPath: String?
    let contextPath: String?
    let repoUrl: String?
    let repoPath: String?
    let folderId: Int?
    let status: AcademicStatus
    let error: String?
    /// Markdown written by the research agent.
    let analysis: String?
    let analysisConversationId: Int?
    let candidates: [ArxivCandidate]
    let repoCandidates: [RepositoryCandidate]
    let conversations: [AcademicConversation]

    enum CodingKeys: String, CodingKey {
        case id, itemKey, title, authors, abstractText, doi, arxivId, pdfPath, textPath, contextPath
        case repoUrl, repoPath, folderId, status, error, analysis, analysisConversationId
        case candidates, repoCandidates, conversations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        itemKey = try c.decodeIfPresent(String.self, forKey: .itemKey) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        abstractText = try c.decodeIfPresent(String.self, forKey: .abstractText) ?? ""
        doi = try c.decodeIfPresent(String.self, forKey: .doi)
        arxivId = try c.decodeIfPresent(String.self, forKey: .arxivId)
        pdfPath = try c.decodeIfPresent(String.self, forKey: .pdfPath)
        textPath = try c.decodeIfPresent(String.self, forKey: .textPath)
        contextPath = try c.decodeIfPresent(String.self, forKey: .contextPath)
        repoUrl = try c.decodeIfPresent(String.self, forKey: .repoUrl)
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath)
        folderId = try c.decodeIfPresent(Int.self, forKey: .folderId)
        status = AcademicStatus(rawValue: try c.decodeIfPresent(String.self, forKey: .status) ?? "")
        error = try c.decodeIfPresent(String.self, forKey: .error)
        analysis = try c.decodeIfPresent(String.self, forKey: .analysis)
        analysisConversationId = try c.decodeIfPresent(Int.self, forKey: .analysisConversationId)
        candidates = try c.decodeIfPresent([ArxivCandidate].self, forKey: .candidates) ?? []
        repoCandidates = try c.decodeIfPresent([RepositoryCandidate].self, forKey: .repoCandidates) ?? []
        conversations = try c.decodeIfPresent([AcademicConversation].self, forKey: .conversations) ?? []
    }
}

/// Where a paper's preparation stands. A free string server-side; unknown
/// values keep their raw text.
struct AcademicStatus: Hashable, Sendable {
    let rawValue: String

    static let queued = AcademicStatus(rawValue: "queued")
    static let resolving = AcademicStatus(rawValue: "resolving")
    static let extracting = AcademicStatus(rawValue: "extracting")
    static let analyzing = AcademicStatus(rawValue: "analyzing")
    static let verifying = AcademicStatus(rawValue: "verifying")
    static let cloning = AcademicStatus(rawValue: "cloning")
    static let needsMatch = AcademicStatus(rawValue: "needs_match")
    static let needsRepo = AcademicStatus(rawValue: "needs_repo")
    static let ready = AcademicStatus(rawValue: "ready")
    static let noCode = AcademicStatus(rawValue: "no_code")
    static let metadataOnly = AcademicStatus(rawValue: "metadata_only")
    static let failed = AcademicStatus(rawValue: "failed")
    static let cancelled = AcademicStatus(rawValue: "cancelled")
    static let interrupted = AcademicStatus(rawValue: "interrupted")

    /// A background job is running (the server's `is_active` set).
    var isBusy: Bool {
        [.queued, .resolving, .extracting, .analyzing, .verifying, .cloning].contains(self)
    }

    /// Waiting for the user to pick an arXiv match or a repository.
    var needsChoice: Bool { self == .needsMatch || self == .needsRepo }
}

/// `academic_open_target`: what a new conversation about the paper should
/// use. `folderId`/`workingDir` are set when it opens in the paper's cloned
/// repository; nil means a chat-mode conversation (no code).
struct AcademicOpenTarget: Decodable, Sendable {
    let paperId: String
    let agentType: String
    let folderId: Int?
    let workingDir: String?
}

/// The research agent's mode and config for a select / prepare. The nested
/// keys are snake_case on the wire (the struct has no `rename_all`), unlike the
/// camelCase top-level arguments.
struct AcademicAgentPreferences: Encodable, Sendable {
    let agentType: String
    let modeId: String?
    let configValues: [String: String]

    enum CodingKeys: String, CodingKey {
        case agentType = "agent_type"
        case modeId = "mode_id"
        case configValues = "config_values"
    }
}

/// `create_chat_conversation`. The top level is camelCase (the nested folder
/// is snake_case) — both decode with the shared decoder.
struct ChatConversationCreated: Decodable, Sendable {
    let conversationId: Int
    let folderId: Int
    let folder: FolderDetail
}

struct ChatDirCreated: Decodable, Sendable {
    let path: String
}
