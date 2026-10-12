import Foundation

/// Git's complete inventory, including checkouts not registered with Codeg.
/// The shared decoder converts `is_main` / `root_path` to their Swift names.
struct GitWorktreeInfo: Decodable, Identifiable, Hashable, Sendable {
    let path: String
    let head: String?
    let branch: String?
    let detached: Bool
    let bare: Bool
    let locked: String?
    let prunable: String?
    let isMain: Bool
    // Optional for servers whose inventory predates this field.
    var rootPath: String? = nil

    var id: String { path }
    // Some("") means the flag is present, without a reason.
    var isLocked: Bool { locked != nil }
    var isPrunable: Bool { prunable != nil }
}

/// Rust `GitWorktreeRemoval`: Git removal and Codeg folder reconciliation.
struct GitWorktreeRemoval: Decodable, Equatable, Sendable {
    let worktreePath: String?
    let branchDeleted: Bool
    let folderId: Int?
    let reparented: UInt32
}
