import Foundation
import Observation

enum ProjectCatalogIssue: Equatable, Sendable {
    case foldersUnavailable, unavailable, upgradeRequired
    var message: String {
        switch self {
        case .foldersUnavailable: "Couldn’t load folders. Retry to refresh this server."
        case .unavailable: "Project identity is unavailable. Showing the last known setup."
        case .upgradeRequired: "Upgrade this Codeg server to group repositories across servers."
        }
    }

    static func identityFailure(_ error: Error) -> Self {
        if case let APIError.server(status, code, _, _) = error,
           status == 405 || status == 501 || (status == 404 &&
            (code == nil || ["unknown_endpoint", "endpoint_not_found", "route_not_found"].contains(code ?? ""))) {
            return .upgradeRequired
        }
        return .unavailable
    }
}

/// Folder-only bootstrap and Git identity reads have no conversation dependency.
/// The retained workspace supplies fixed-client reads; Foundation tests supply
/// controlled barriers. Every publication is fenced by lifetime and sequence.
@MainActor
@Observable
final class ProjectCatalogModel {
    private(set) var folders: [FolderDetail] = []
    private(set) var openFolders: [FolderDetail] = []
    private(set) var identities: [ProjectFolderKey: ProjectIdentityState] = [:]
    private(set) var folderIssue: ProjectCatalogIssue?
    private(set) var identityIssue: ProjectCatalogIssue?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private var foldersLoaded = false
    private var openFoldersLoaded = false
    private var foldersSequence = 0
    private var openFoldersSequence = 0
    private var hasAttempted = false
    private var unsupported = false
    private var retired = false
    private var sequence = 0
    @ObservationIgnored private let lifetime: ServerBindingLifetime
    @ObservationIgnored private let loadFolders: @MainActor () async throws -> [FolderDetail]
    @ObservationIgnored private let loadOpenFolders: @MainActor () async throws -> [FolderDetail]
    @ObservationIgnored private let loadIdentities: @MainActor ([Int]) async throws -> [RepositoryProjectIdentityEntry]
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init(lifetime: ServerBindingLifetime,
         loadFolders: @escaping @MainActor () async throws -> [FolderDetail],
         loadOpenFolders: @escaping @MainActor () async throws -> [FolderDetail],
         loadIdentities: @escaping @MainActor ([Int]) async throws -> [RepositoryProjectIdentityEntry]) {
        self.lifetime = lifetime
        self.loadFolders = loadFolders
        self.loadOpenFolders = loadOpenFolders
        self.loadIdentities = loadIdentities
    }

    /// Successful full inventory is authoritative for removal/path reuse. Keep
    /// each endpoint's raw snapshot, but never project stale open-folder paths.
    var catalogFolders: [FolderDetail] {
        guard foldersLoaded else { return openFolders }
        guard openFoldersSequence > foldersSequence else { return folders }
        let opened = Dictionary(openFolders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(folders.map(\.id))
        return folders.map { opened[$0.id] ?? $0 } + openFolders.filter { !known.contains($0.id) }
    }
    var visibleOpenFolders: [FolderDetail] {
        guard openFoldersLoaded else { return catalogFolders }
        guard foldersLoaded else { return openFolders }
        if openFoldersSequence > foldersSequence { return openFolders }
        let openIDs = Set(openFolders.map(\.id))
        return folders.filter { openIDs.contains($0.id) }
    }
    var setupFolders: [FolderDetail] {
        LogicalProjectProjection.setupFolders(folders: catalogFolders, openFolders: visibleOpenFolders)
    }
    func folder(id: Int) -> FolderDetail? { catalogFolders.first { $0.id == id } }
    func snapshot(serverID: UUID, configurationRevision: UUID) -> ProjectCatalogSnapshot {
        ProjectCatalogSnapshot(serverID: serverID, configurationRevision: configurationRevision,
            generationID: lifetime.id, folders: catalogFolders, openFolders: visibleOpenFolders, identities: identities)
    }

    func loadIfNeeded() async {
        guard !hasAttempted else { return }
        await refresh()
    }

    /// Ordinary loads coalesce; explicit refresh/mutation supersedes old work
    /// and reprobes unsupported capability after a server upgrade.
    func refresh(force: Bool = false) async {
        guard lifetime.isValid, !retired else { return }
        if !force, let inFlight { await inFlight.value; return }
        inFlight?.cancel()
        sequence += 1
        let token = sequence
        isLoading = true
        let task = Task { await self.load(token: token, reprobe: force) }
        inFlight = task
        await task.value
        guard accepts(token) else { return }
        inFlight = nil
        isLoading = false
        hasAttempted = true
    }

    /// Called synchronously by ServerWorkspace before releasing the generation.
    func retire() {
        retired = true
        sequence += 1
        inFlight?.cancel(); inFlight = nil
        folders = []; openFolders = []; identities = [:]
        folderIssue = nil; identityIssue = nil
        isLoading = false; hasLoaded = false
        foldersLoaded = false; openFoldersLoaded = false; hasAttempted = false
        foldersSequence = 0; openFoldersSequence = 0
    }

    private func accepts(_ token: Int) -> Bool {
        !retired && lifetime.isValid && sequence == token
    }

    private enum FolderResult: Sendable {
        case all(Result<[FolderDetail], Error>)
        case open(Result<[FolderDetail], Error>)
    }
    private static func result<T>(_ operation: @MainActor () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    private func load(token: Int, reprobe: Bool) async {
        var folderFailed = false
        await withTaskGroup(of: FolderResult.self) { group in
            group.addTask { .all(await Self.result(self.loadFolders)) }
            group.addTask { .open(await Self.result(self.loadOpenFolders)) }
            for await outcome in group {
                guard accepts(token), !Task.isCancelled else { continue }
                switch outcome {
                case .all(.success(let rows)):
                    folders = rows; foldersLoaded = true; hasLoaded = true; foldersSequence = token
                case .open(.success(let rows)):
                    openFolders = rows; openFoldersLoaded = true; hasLoaded = true; openFoldersSequence = token
                case .all(.failure), .open(.failure): folderFailed = true
                }
                pruneIdentities()
            }
        }
        guard accepts(token), !Task.isCancelled else { return }
        folderIssue = folderFailed ? .foldersUnavailable : nil
        guard !unsupported || reprobe else { return }
        let targets = setupFolders
        var issue: ProjectCatalogIssue?
        for start in stride(from: 0, to: targets.count, by: 128) {
            let batch = Array(targets[start..<min(start + 128, targets.count)])
            do {
                let entries = try await loadIdentities(batch.map(\.id))
                guard accepts(token), !Task.isCancelled else { return }
                unsupported = false
                let byID = Dictionary(grouping: entries, by: \.folderId)
                for folder in batch {
                    let key = ProjectFolderKey(folder)
                    guard self.folder(id: folder.id)?.path == folder.path else { continue }
                    // Missing, duplicate or mismatched entries carry no authority.
                    if let matches = byID[folder.id], matches.count == 1, let entry = matches.first,
                       entry.status == .resolved, entry.path == folder.path {
                        identities[key] = ProjectIdentityState(identity: entry.identity, availability: .resolved)
                    } else {
                        markUnavailable(key)
                        issue = .unavailable
                    }
                }
            } catch {
                guard accepts(token), !Task.isCancelled else { return }
                issue = ProjectCatalogIssue.identityFailure(error)
                for folder in batch { markUnavailable(ProjectFolderKey(folder)) }
                if issue == .upgradeRequired {
                    unsupported = true
                    // No old-server metadata can merge setups after fallback.
                    for folder in targets {
                        identities[ProjectFolderKey(folder)] = ProjectIdentityState(identity: nil, availability: .unavailable)
                    }
                    break
                }
            }
        }
        guard accepts(token), !Task.isCancelled else { return }
        identityIssue = issue
    }

    private func markUnavailable(_ key: ProjectFolderKey) {
        identities[key] = ProjectIdentityState(identity: identities[key]?.identity, availability: .unavailable)
    }
    private func pruneIdentities() {
        let current = Set(catalogFolders.filter { $0.kind == .regular }.map(ProjectFolderKey.init))
        identities = identities.filter { current.contains($0.key) }
    }
}
