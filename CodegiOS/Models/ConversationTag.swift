import Foundation

/// Server `ConversationTagDetail`; nil folderId denotes a global tag.
struct ConversationTagDetail: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let folderId: Int?
    var name: String
    var color: String
    var sortOrder: Int

    /// Globals first, then folder groups; ties within a group use the tag ID.
    static func displayOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.folderId != rhs.folderId {
            guard let left = lhs.folderId else { return true }
            guard let right = rhs.folderId else { return false }
            return left < right
        }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id < rhs.id
    }
}

/// Optional server-wide branch chip settings, independent of assigned tags.
struct ConversationBranchTag: Codable, Hashable, Sendable {
    var enabled: Bool
    var color: String
}
