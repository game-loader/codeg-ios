import Foundation

extension CodegClient {
    func listRepositoryProjectIdentities(folderIds: [Int]) async throws -> [RepositoryProjectIdentityEntry] {
        try await postReadJSON("list_repository_project_identities", RepositoryProjectIdentityRequest(folderIds: folderIds))
    }
}

extension ProjectCatalogModel {
    convenience init(client: CodegClient?, lifetime: ServerBindingLifetime) {
        self.init(lifetime: lifetime, loadFolders: {
            guard let client else { throw APIError.unauthorized }
            return try await withNetworkRetry { try await client.listFolders() }
        }, loadOpenFolders: {
            guard let client else { throw APIError.unauthorized }
            return try await withNetworkRetry { try await client.listOpenFolders() }
        }, loadIdentities: { ids in
            guard let client else { throw APIError.unauthorized }
            return try await client.listRepositoryProjectIdentities(folderIds: ids)
        })
    }
}
