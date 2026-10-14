import Foundation
import Observation

/// One captured endpoint generation. Selecting another server never retargets it.
@MainActor
@Observable
final class ConversationTagsModel {
    let client: CodegClient
    let bindingLifetime: ServerBindingLifetime?
    private(set) var folders: [FolderDetail]
    let conversationID: Int?

    private(set) var tags: [ConversationTagDetail] = []
    private(set) var isLoading = false
    private(set) var isBusy = false
    private(set) var isUnsupported = false
    var errorMessage: String?
    private(set) var conversationSummary: ConversationSummary?
    private(set) var branchSettings: ConversationBranchTag?
    private(set) var isBranchSettingsUnsupported = false
    /// Advances only when a full catalog is accepted, so failed/partial loads
    /// cannot clear a workspace's tag filter.
    private(set) var catalogRevision = 0
    private(set) var catalogTagIDs: [Int] = []
    private var retired = false
    var isRetired: Bool { retired || bindingLifetime?.isValid == false }

    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var branchLoadGeneration = 0

    init(client: CodegClient, folders: [FolderDetail] = [], conversationID: Int? = nil) {
        self.client = client
        self.bindingLifetime = client.bindingLifetime
        self.folders = folders
        self.conversationID = conversationID
    }

    func updateFolders(_ folders: [FolderDetail]) {
        guard !isRetired else { return }
        self.folders = folders
    }

    func retire() {
        retired = true
        loadGeneration += 1
        branchLoadGeneration += 1
        isLoading = false
        isBusy = false
        tags = []
        catalogTagIDs = []
        conversationSummary = nil
        branchSettings = nil
    }

    func availableTags(folderID: Int?, folders: [FolderDetail]? = nil) -> [ConversationTagDetail] {
        let scope = Self.scopeFolderID(folderID, folders: folders ?? self.folders)
        return tags.filter { $0.folderId == nil || (scope != nil && $0.folderId == scope) }
    }

    /// One live representative per real folder family, including a surviving
    /// worktree whose root is no longer returned by the server.
    static func creationScopes(folders: [FolderDetail]) -> [FolderDetail] {
        let candidates = folders.filter { $0.kind == .regular }.sorted {
            if $0.parentId == nil, $1.parentId != nil { return true }
            if $0.parentId != nil, $1.parentId == nil { return false }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id < $1.id
        }
        var seen: Set<Int> = []
        return candidates.filter { folder in
            guard let scope = scopeFolderID(folder.id, folders: folders) else { return false }
            return seen.insert(scope).inserted
        }
    }

    /// A known parent link is authoritative even when the root row is absent
    /// (closed/deleted root with a surviving worktree). Never infer from paths.
    static func scopeFolderID(_ folderID: Int?, folders: [FolderDetail]) -> Int? {
        guard var currentID = folderID else { return nil }
        var visited: Set<Int> = []
        while visited.insert(currentID).inserted {
            guard let folder = folders.first(where: { $0.id == currentID }) else {
                return currentID == folderID ? nil : currentID
            }
            guard folder.kind == .regular else { return nil }
            guard let parent = folder.parentId else { return folder.id }
            currentID = parent
        }
        return nil
    }

    func load() async {
        guard !isRetired, acceptsResults, !isBusy, !isUnsupported else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let result = try await client.listConversationTags()
            guard acceptsResults, generation == loadGeneration else { return }
            tags = result.sorted(by: ConversationTagDetail.displayOrder)
            catalogTagIDs = tags.map(\.id)
            catalogRevision += 1
        } catch {
            guard acceptsResults, generation == loadGeneration else { return }
            record(error)
        }
    }

    @discardableResult
    func create(name: String, color: String, folderID: Int? = nil) async -> ConversationTagDetail? {
        guard canMutate else { return nil }
        let scope = Self.scopeFolderID(folderID, folders: folders)
        guard folderID == nil || scope != nil else {
            errorMessage = String(localized: "The folder's tag scope is unavailable.")
            return nil
        }
        // A surviving worktree may name a root whose row is no longer live.
        // Submit that worktree so the backend can validate it and resolve owner.
        let requestFolderID = scope.flatMap { root in
            folders.contains(where: { $0.id == root }) ? root : folderID
        }
        return await mutate {
            try await self.client.createConversationTag(folderId: requestFolderID, name: name, color: color)
        } publish: { self.upsert($0) }
    }

    @discardableResult
    func update(tagID: Int, name: String? = nil, color: String? = nil) async -> ConversationTagDetail? {
        await mutate {
            try await self.client.updateConversationTag(tagId: tagID, name: name, color: color)
        } publish: { self.upsert($0) }
    }

    @discardableResult
    func delete(tagID: Int) async -> Bool {
        let result: Void? = await mutate {
            try await self.client.deleteConversationTag(tagId: tagID)
        } publish: { _ in
            self.tags.removeAll { $0.id == tagID }
            self.conversationSummary?.tagIds.removeAll { $0 == tagID }
        }
        return result != nil
    }

    @discardableResult
    func reorder(tagIDs: [Int]) async -> Bool {
        let result: Void? = await mutate {
            try await self.client.reorderConversationTags(tagIds: tagIDs)
        } publish: { _ in
            for (order, id) in tagIDs.enumerated() {
                if let index = self.tags.firstIndex(where: { $0.id == id }) {
                    self.tags[index].sortOrder = order + 1
                }
            }
            self.tags.sort(by: ConversationTagDetail.displayOrder)
        }
        return result != nil
    }

    @discardableResult
    func assign(conversationID: Int, add: [Int] = [], remove: [Int] = []) async -> ConversationSummary? {
        guard canMutate else { return nil }
        guard self.conversationID == nil || self.conversationID == conversationID else {
            errorMessage = String(localized: "This tag editor belongs to another conversation.")
            return nil
        }
        return await mutate {
            try await self.client.updateConversationTags(conversationId: conversationID, add: add, remove: remove)
        } publish: { self.conversationSummary = $0 }
    }

    /// Branch support is optional and does not disable the tag catalog.
    func loadBranchSettings() async {
        guard acceptsResults, !isBusy, !isBranchSettingsUnsupported else { return }
        branchLoadGeneration += 1
        let generation = branchLoadGeneration
        do {
            let result = try await client.getConversationBranchTag()
            guard acceptsResults, generation == branchLoadGeneration else { return }
            branchSettings = result
        } catch {
            guard acceptsResults, generation == branchLoadGeneration else { return }
            record(error, branch: true)
        }
    }

    @discardableResult
    func updateBranchSettings(enabled: Bool, color: String) async -> ConversationBranchTag? {
        await mutate(branch: true) {
            try await self.client.updateConversationBranchTag(enabled: enabled, color: color)
        } publish: { self.branchSettings = $0 }
    }

    private var acceptsResults: Bool {
        !isRetired && !Task.isCancelled && (bindingLifetime?.isValid ?? true)
    }

    private var canMutate: Bool { acceptsResults && !isBusy && !isUnsupported }

    /// Busy guard serializes mutations. Both read generations are retired before
    /// awaiting HTTP, so an older refresh can never undo this mutation.
    private func mutate<Result>(branch: Bool = false, _ operation: () async throws -> Result,
                                publish: (Result) -> Void) async -> Result? {
        guard acceptsResults, !isBusy,
              branch ? !isBranchSettingsUnsupported : !isUnsupported else { return nil }
        isBusy = true
        loadGeneration += 1
        branchLoadGeneration += 1
        isLoading = false
        errorMessage = nil
        defer { isBusy = false }
        do {
            let result = try await operation()
            try client.checkBinding()
            guard acceptsResults else { return nil }
            publish(result)
            return result
        } catch {
            if acceptsResults { record(error, branch: branch) }
            return nil
        }
    }

    private func upsert(_ tag: ConversationTagDetail) {
        tags.removeAll { $0.id == tag.id }
        tags.append(tag)
        tags.sort(by: ConversationTagDetail.displayOrder)
    }

    private func record(_ error: Error, branch: Bool = false) {
        if error is CancellationError { return }
        if error is ConversationTagsAPIError {
            if branch {
                isBranchSettingsUnsupported = true
                branchSettings = nil
            } else {
                isUnsupported = true
                tags = []
            }
        } else {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
