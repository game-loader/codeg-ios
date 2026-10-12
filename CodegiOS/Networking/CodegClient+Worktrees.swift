import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum WorktreeAPIError: LocalizedError, Sendable {
    case upgradeRequired

    var errorDescription: String? {
        "This server does not support worktree management. Upgrade the Codeg server to use this feature."
    }

    static func translate(_ error: Error) -> Error {
        // A typed `not_found` may mean a stale checkout; it is not a missing route.
        if case let APIError.server(status, code, _, _) = error,
           status == 405 || status == 501 ||
            (status == 404 && (code == nil || ["unknown_endpoint", "endpoint_not_found", "route_not_found"].contains(code ?? ""))) {
            return WorktreeAPIError.upgradeRequired
        }
        return error
    }
}

extension CodegClient {
    func gitWorktrees(path: String) async throws -> [GitWorktreeInfo] {
        do { return try await postJSON("git_list_worktrees", PathBody(path: path)) }
        catch { throw WorktreeAPIError.translate(error) }
    }

    /// Convenience for callers with a repository path. Resolve the folder on
    /// this client only: folder IDs have no meaning on another server.
    func gitWorktreeRemoveByPath(
        path: String, worktreePath: String, deleteBranch: Bool = false, force: Bool = false
    ) async throws -> GitWorktreeRemoval {
        let folders = try await listFolders()
        guard let source = folders.first(where: { WorktreePaths.same($0.path, path) }) else {
            throw APIError.server(status: 422, code: "invalid_input",
                                  message: "The source repository must be registered before removing a worktree.", detail: nil)
        }
        return try await gitWorktreeRemoveByPath(path: path, worktreePath: worktreePath,
                                                sourceFolderId: source.id, deleteBranch: deleteBranch, force: force)
    }

    /// The model already has the initiating folder. Preserve its identity even
    /// if the parent catalog or selected server changes while awaiting Git.
    func gitWorktreeRemoveByPath(
        path: String, worktreePath: String, sourceFolderId: Int,
        deleteBranch: Bool = false, force: Bool = false
    ) async throws -> GitWorktreeRemoval {
        do {
            return try await postJSON("git_remove_worktree_path", GitWorktreeRemovePathBody(
                path: path, worktreePath: worktreePath, sourceFolderId: sourceFolderId,
                deleteBranch: deleteBranch, force: force
            ))
        } catch { throw WorktreeAPIError.translate(error) }
    }

    /// Branch-only recovery after inventory proves the checkout was removed.
    /// The backend returns a JSON string, not a null acknowledgement.
    func gitWorktreeDeleteBranch(path: String, branchName: String, force: Bool = false) async throws -> String {
        try await postJSON("git_delete_branch", GitWorktreeDeleteBranchBody(
            path: path, branchName: branchName, force: force
        ))
    }
}

struct GitWorktreeRemovePathBody: Encodable, Sendable {
    let path: String
    let worktreePath: String
    let sourceFolderId: Int
    let deleteBranch: Bool
    let force: Bool
}

struct GitWorktreeDeleteBranchBody: Encodable, Sendable {
    let path: String
    let branchName: String
    let force: Bool
}

/// Server path comparison only. Never canonicalize remote paths on the phone.
enum WorktreePaths {
    static func normalized(_ path: String) -> String {
        var value = path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func same(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("\\\\") ||
            path.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) != nil
    }
}
