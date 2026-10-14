import Foundation

enum ConversationTagsAPIError: LocalizedError, Sendable {
    case unsupported

    var errorDescription: String? {
        String(localized: "Conversation tags require a newer Codeg Server.")
    }
}

extension CodegClient {
    func listConversationTags() async throws -> [ConversationTagDetail] {
        try await conversationTagRequest {
            try await postReadJSON("list_conversation_tags", EmptyBody())
        }
    }

    func createConversationTag(folderId: Int? = nil, name: String, color: String) async throws -> ConversationTagDetail {
        try await conversationTagRequest {
            try await postJSON("create_conversation_tag", CreateTagBody(folderId: folderId, name: name, color: color))
        }
    }

    func updateConversationTag(tagId: Int, name: String? = nil, color: String? = nil) async throws -> ConversationTagDetail {
        try await conversationTagRequest {
            try await postJSON("update_conversation_tag", UpdateTagBody(tagId: tagId, name: name, color: color))
        }
    }

    func deleteConversationTag(tagId: Int) async throws {
        try await conversationTagRequest {
            _ = try await send("delete_conversation_tag", body: TagIDBody(tagId: tagId))
        }
    }

    /// IDs are the complete ordered list for one scope, as required by v0.35.1.
    func reorderConversationTags(tagIds: [Int]) async throws {
        try await conversationTagRequest {
            _ = try await send("reorder_conversation_tags", body: TagIDsBody(tagIds: tagIds))
        }
    }

    /// A delta preserves unrelated assignments, including IDs absent from cache.
    func updateConversationTags(conversationId: Int, add: [Int] = [], remove: [Int] = []) async throws -> ConversationSummary {
        try await conversationTagRequest {
            try await postJSON("update_conversation_tags", TagDeltaBody(conversationId: conversationId, add: add, remove: remove))
        }
    }

    func getConversationBranchTag() async throws -> ConversationBranchTag {
        try await conversationTagRequest {
            try await postReadJSON("get_conversation_branch_tag", EmptyBody())
        }
    }

    func updateConversationBranchTag(enabled: Bool, color: String) async throws -> ConversationBranchTag {
        try await conversationTagRequest {
            try await postJSON("update_conversation_branch_tag", ConversationBranchTag(enabled: enabled, color: color))
        }
    }

    private func conversationTagRequest<Result>(_ operation: () async throws -> Result) async throws -> Result {
        do {
            let result = try await operation()
            try checkBinding()
            return result
        } catch {
            try checkBinding()
            // Axum's missing route is an untyped 404. A structured resource
            // not_found (tag/folder/conversation) must remain a real failure.
            if case APIError.server(404, nil, _, nil) = error {
                throw ConversationTagsAPIError.unsupported
            }
            throw error
        }
    }
}

private struct CreateTagBody: Encodable {
    let folderId: Int?
    let name: String
    let color: String
}

private struct UpdateTagBody: Encodable {
    let tagId: Int
    let name: String?
    let color: String?
}

private struct TagIDBody: Encodable { let tagId: Int }
private struct TagIDsBody: Encodable { let tagIds: [Int] }
private struct TagDeltaBody: Encodable {
    let conversationId: Int
    let add: [Int]
    let remove: [Int]
}
