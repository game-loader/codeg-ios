import Foundation
import Observation

/// No endpoint or credential material participates in runtime identity.
struct ProjectWorkspaceKey: Hashable {
    let generationID: UUID?
    let folderID: Int
    let path: String

    init(client: CodegClient, folder: FolderDetail) {
        generationID = client.bindingLifetime?.id
        folderID = folder.id
        path = folder.path
    }
}

/// Fixed-client project state that outlives navigation and split-shell rebuilds.
/// The PTY still starts lazily when the Terminal tab first appears.
@MainActor
@Observable
final class ProjectRuntime {
    let git: FolderGitModel
    let terminal: TerminalSession
    var tab: FolderTab = .files
    var showCommit = false

    init(client: CodegClient, folder: FolderDetail) {
        git = FolderGitModel(client: client, rootPath: folder.path, folderId: folder.id)
        terminal = TerminalSession(client: client, folder: folder)
    }

    fileprivate func retire() {
        git.cancelCredentials()
        git.pushAfterCommitDismiss = false
        terminal.retire()
    }
}

/// Each generation owns an independent folder map and one invalidation observer.
/// Active generations retain visited projects even when no view references them.
/// Retirement evicts only that generation; unbound clients always get local state.
@MainActor
final class ProjectWorkspaceCache {
    static let shared = ProjectWorkspaceCache()

    @MainActor
    private final class Generation {
        let lifetime: ServerBindingLifetime
        let observerID: UUID?
        var runtimes: [ProjectWorkspaceKey: ProjectRuntime] = [:]

        init(lifetime: ServerBindingLifetime, observer: @escaping @Sendable () -> Void) {
            self.lifetime = lifetime
            observerID = lifetime.addInvalidationObserver(observer)
        }

        deinit {
            if let observerID { lifetime.removeInvalidationObserver(observerID) }
        }
    }

    private var generations: [UUID: Generation] = [:]

    func runtime(client: CodegClient, folder: FolderDetail) -> ProjectRuntime? {
        guard let lifetime = client.bindingLifetime else {
            return ProjectRuntime(client: client, folder: folder)
        }
        let id = lifetime.id
        guard lifetime.isValid else {
            retire(generationID: id)
            return nil
        }
        let generation: Generation
        if let existing = generations[id] {
            generation = existing
        } else {
            generation = Generation(lifetime: lifetime) { [weak self] in
                Task { @MainActor [weak self] in self?.retire(generationID: id) }
            }
            generations[id] = generation
        }
        // Invalidation may race observer registration on another thread.
        guard lifetime.isValid else {
            retire(generationID: id)
            return nil
        }
        let key = ProjectWorkspaceKey(client: client, folder: folder)
        if let existing = generation.runtimes[key] { return existing }
        let created = ProjectRuntime(client: client, folder: folder)
        generation.runtimes[key] = created
        guard lifetime.isValid else {
            retire(generationID: id)
            return nil
        }
        return created
    }

    private func retire(generationID: UUID) {
        guard let generation = generations.removeValue(forKey: generationID) else { return }
        for runtime in generation.runtimes.values { runtime.retire() }
        generation.runtimes.removeAll()
    }
}
