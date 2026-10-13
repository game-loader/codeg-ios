import Foundation

/// Comparable read ordering across independent folder loaders. Publish an order
/// only on success, but allocate it before reading: an Activity snapshot delayed
/// by history must not supersede a catalog inventory read started after it.
@MainActor
enum FolderInventoryReadOrder {
    private static var sequence: UInt64 = 0
    static func next() -> UInt64 {
        sequence += 1
        return sequence
    }
}

/// Safe server-derived display metadata. Execution never uses a canonical key.
struct RepositoryProjectIdentity: Codable, Hashable, Sendable {
    let projectKey: String
    let provider: String
    let host: String
    let repositoryPath: String
    let remoteName: String
}

struct RepositoryProjectIdentityEntry: Decodable, Sendable {
    enum Status: String, Decodable, Sendable { case resolved, unavailable }
    let folderId: Int
    let path: String?
    let status: Status
    let identity: RepositoryProjectIdentity?
}

struct RepositoryProjectIdentityRequest: Encodable, Sendable {
    let folderIds: [Int]
}

struct ProjectFolderKey: Hashable, Sendable {
    let folderID: Int
    let path: String
    init(folderID: Int, path: String) { self.folderID = folderID; self.path = path }
    init(_ folder: FolderDetail) { self.init(folderID: folder.id, path: folder.path) }
}

struct ProjectIdentityState: Sendable {
    enum Availability: Sendable { case resolved, unavailable }
    let identity: RepositoryProjectIdentity?
    let availability: Availability
}

/// A captured row cannot silently move to a replacement configuration or path.
struct ProjectSetupReference: Hashable, Sendable {
    let serverID: UUID
    let configurationRevision: UUID
    let generationID: UUID
    let folderID: Int
    let path: String

    func matches(_ snapshot: ProjectCatalogSnapshot) -> Bool {
        serverID == snapshot.serverID && configurationRevision == snapshot.configurationRevision &&
        generationID == snapshot.generationID && snapshot.folders.contains {
            $0.id == folderID && $0.path == path && $0.kind == .regular
        }
    }
}

struct ProjectHostSetup: Identifiable, Sendable {
    let reference: ProjectSetupReference
    let folder: FolderDetail
    let worktrees: [FolderDetail]
    let identity: ProjectIdentityState?
    var id: ProjectSetupReference { reference }
    var serverID: UUID { reference.serverID }
    var path: String { reference.path }
}

struct LogicalProject: Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case source(String)
        case local(ProjectSetupReference)
    }
    let id: ID
    let name: String
    var setups: [ProjectHostSetup]
}

struct ProjectCatalogSnapshot: Sendable {
    let serverID: UUID
    let configurationRevision: UUID
    let generationID: UUID
    let folders: [FolderDetail]
    let openFolders: [FolderDetail]
    let identities: [ProjectFolderKey: ProjectIdentityState]
}

enum ProjectCatalogViewMode: String, CaseIterable { case projects, servers }

/// Pure projection, with ancestry resolved only inside each owning inventory.
enum LogicalProjectProjection {
    static func setupFolders(folders: [FolderDetail], openFolders: [FolderDetail]) -> [FolderDetail] {
        let inventory = Dictionary(folders.filter { $0.kind == .regular }.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var seen: Set<Int> = []
        var roots: [FolderDetail] = []
        for opened in openFolders where opened.kind == .regular {
            var root = inventory[opened.id] ?? opened
            var ancestors: Set<Int> = [root.id]
            while let parent = root.parentId, let known = inventory[parent], ancestors.insert(parent).inserted {
                root = known
            }
            if seen.insert(root.id).inserted { roots.append(root) }
        }
        return roots.sorted(by: folderOrder)
    }

    static func folderOrder(_ lhs: FolderDetail, _ rhs: FolderDetail) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id < rhs.id
    }

    static func projects(_ snapshots: [ProjectCatalogSnapshot]) -> [LogicalProject] {
        var projects: [LogicalProject] = []
        var positions: [LogicalProject.ID: Int] = [:]
        for snapshot in snapshots {
            for folder in setupFolders(folders: snapshot.folders, openFolders: snapshot.openFolders) {
                let reference = ProjectSetupReference(serverID: snapshot.serverID,
                    configurationRevision: snapshot.configurationRevision, generationID: snapshot.generationID,
                    folderID: folder.id, path: folder.path)
                let state = snapshot.identities[ProjectFolderKey(folder)]
                let source = state?.identity
                let id = source.map { LogicalProject.ID.source($0.projectKey) } ?? .local(reference)
                let setup = ProjectHostSetup(reference: reference, folder: folder,
                    worktrees: snapshot.folders.filter { $0.parentId == folder.id && $0.kind == .regular }
                        .sorted(by: folderOrder), identity: state)
                if let position = positions[id] {
                    projects[position].setups.append(setup)
                } else {
                    positions[id] = projects.count
                    projects.append(LogicalProject(id: id, name: source?.repositoryPath ?? folder.displayName, setups: [setup]))
                }
            }
        }
        return projects
    }
}

/// History remains scoped to a concrete folder, including completed and pinned
/// rows. Delegation visibility is supplied by the existing conversation endpoint.
enum ProjectSessionHistory {
    static func folders(for folder: FolderDetail, inventory: [FolderDetail]) -> [FolderDetail] {
        [folder] + inventory.filter { $0.parentId == folder.id && $0.kind == .regular }
            .sorted(by: LogicalProjectProjection.folderOrder)
    }

    static func sessions(in folderID: Int, conversations: [ConversationSummary]) -> [ConversationSummary] {
        conversations.filter { $0.folderId == folderID }.sorted(by: precedes)
    }

    static func precedes(_ lhs: ConversationSummary, _ rhs: ConversationSummary) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.isPinned, lhs.pinnedAt != rhs.pinnedAt { return (lhs.pinnedAt ?? .distantPast) > (rhs.pinnedAt ?? .distantPast) }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}

/// A display row and an operation destination both carry the original concrete
/// folder. Equal conversation IDs on different machines remain distinct.
struct ProjectSessionReference: Hashable, Sendable {
    let location: ProjectSetupReference
    let conversationID: Int
}

struct ProjectHistoryLocation: Identifiable, Sendable {
    let reference: ProjectSetupReference
    let folder: FolderDetail
    var id: ProjectSetupReference { reference }
}

struct LogicalProjectSession: Identifiable, Sendable {
    let reference: ProjectSessionReference
    let folder: FolderDetail
    let conversation: ConversationSummary
    var id: ProjectSessionReference { reference }
}

struct ProjectHistorySnapshot: Sendable {
    let serverID: UUID
    let configurationRevision: UUID
    let generationID: UUID
    let folders: [FolderDetail]
    /// Preserve the endpoint's existing child/delegation visibility semantics.
    let conversations: [ConversationSummary]
}

/// Pure display aggregation. No resource IDs, sessions or runtimes are merged.
enum LogicalProjectHistory {
    static func locations(for project: LogicalProject) -> [ProjectHistoryLocation] {
        project.setups.flatMap { setup in
            ([setup.folder] + setup.worktrees).map { folder in
                ProjectHistoryLocation(reference: ProjectSetupReference(serverID: setup.reference.serverID,
                    configurationRevision: setup.reference.configurationRevision,
                    generationID: setup.reference.generationID, folderID: folder.id, path: folder.path), folder: folder)
            }
        }
    }

    static func sessions(for project: LogicalProject, snapshots: [ProjectHistorySnapshot]) -> [LogicalProjectSession] {
        locations(for: project).flatMap { location -> [LogicalProjectSession] in
            let reference = location.reference
            guard let snapshot = snapshots.first(where: {
                $0.serverID == reference.serverID && $0.configurationRevision == reference.configurationRevision &&
                $0.generationID == reference.generationID
            }) else { return [] }
            guard snapshot.folders.contains(where: {
                $0.id == reference.folderID && $0.path == reference.path && $0.kind == .regular
            }) else { return [] }
            return ProjectSessionHistory.sessions(in: reference.folderID, conversations: snapshot.conversations).map {
                LogicalProjectSession(reference: ProjectSessionReference(location: reference, conversationID: $0.id),
                                      folder: location.folder, conversation: $0)
            }
        }.sorted {
            if ProjectSessionHistory.precedes($0.conversation, $1.conversation) { return true }
            if ProjectSessionHistory.precedes($1.conversation, $0.conversation) { return false }
            let lhs = $0.reference.location, rhs = $1.reference.location
            if lhs.serverID != rhs.serverID { return lhs.serverID.uuidString < rhs.serverID.uuidString }
            if lhs.folderID != rhs.folderID { return lhs.folderID < rhs.folderID }
            return lhs.path < rhs.path
        }
    }
}
