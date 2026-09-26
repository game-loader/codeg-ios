import Foundation

/// Role of a rendered turn (Rust `TurnRole`).
enum TurnRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnRole(rawValue: raw) ?? .system
    }
}

/// Token usage for a single turn (Rust `TurnUsage`). All fields present on wire.
struct TurnUsage: Codable, Hashable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    var total: Int { inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens }
}

/// Inline image payload (Rust `ImageData`).
struct ImageData: Codable, Hashable, Sendable {
    let data: String
    let mimeType: String
    let uri: String?
}

/// A polymorphic block of message content (Rust `ContentBlock`, internally
/// tagged by `type` with snake_case variant names). Decode-only: the server is
/// the source of truth for transcripts; locally-constructed optimistic turns
/// build cases directly. Unknown future variants decode to `.unknown` instead
/// of throwing.
enum ContentBlock: Hashable, Sendable, Decodable {
    case text(String)
    case thinking(String)
    case image(ImageData)
    case imageGeneration(revisedPrompt: String?, image: ImageData?)
    /// `status` is the agent's own recorded call status (`pending` / `in_progress`
    /// / `completed` / `failed`); nil means UNKNOWN, never "settled".
    case toolUse(id: String?, name: String, inputPreview: String?, meta: AnyJSON?, status: String? = nil)
    case toolResult(id: String?, outputPreview: String?, isError: Bool)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        // NOTE: the decoder uses `.convertFromSnakeCase`, so wire keys arrive
        // here already camelCased — match them in camelCase.
        case type, text, data, mimeType, uri, revisedPrompt, image
        case toolUseId, toolName, inputPreview, meta, status
        case outputPreview, isError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image":
            self = .image(ImageData(
                data: try c.decodeIfPresent(String.self, forKey: .data) ?? "",
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "image/png",
                uri: try c.decodeIfPresent(String.self, forKey: .uri)
            ))
        case "image_generation":
            self = .imageGeneration(
                revisedPrompt: try c.decodeIfPresent(String.self, forKey: .revisedPrompt),
                image: try c.decodeIfPresent(ImageData.self, forKey: .image)
            )
        case "tool_use":
            self = .toolUse(
                id: try c.decodeIfPresent(String.self, forKey: .toolUseId),
                name: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "tool",
                inputPreview: try c.decodeIfPresent(String.self, forKey: .inputPreview),
                // `meta["codeg.delegation"]` carries the delegate card's authoritative
                // terminal status; nil for tool uses without any meta.
                meta: try c.decodeIfPresent(AnyJSON.self, forKey: .meta),
                status: try c.decodeIfPresent(String.self, forKey: .status)
            )
        case "tool_result":
            self = .toolResult(
                id: try c.decodeIfPresent(String.self, forKey: .toolUseId),
                outputPreview: try c.decodeIfPresent(String.self, forKey: .outputPreview),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        default:
            self = .unknown(type: type)
        }
    }
}

/// One turn in a conversation transcript (Rust `MessageTurn`).
struct MessageTurn: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let role: TurnRole
    let blocks: [ContentBlock]
    let timestamp: Date
    let usage: TurnUsage?
    let durationMs: Int?
    let model: String?
    let completedAt: Date?

    init(
        id: String,
        role: TurnRole,
        blocks: [ContentBlock],
        timestamp: Date,
        usage: TurnUsage? = nil,
        durationMs: Int? = nil,
        model: String? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.usage = usage
        self.durationMs = durationMs
        self.model = model
        self.completedAt = completedAt
    }
}
