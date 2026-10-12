import Foundation

/// Only host-local resource references and an opaque configuration identity.
/// No client, credentials, unsent text, or old endpoint is a layout field.
struct SavedServerNavigation: Codable {
    let configurationRevision: UUID
    let selectedTab: String
    let sidebarSection: String?
    let conversationID: Int?
    let paths: [String: [SavedRoute]]
    let contentPath: [SavedRoute]

    struct SavedRoute: Codable {
        let kind: String
        let value: String?

        init?(_ route: Route) {
            switch route {
            case .conversation(let id): kind = "conversation"; value = String(id)
            case .project(let id): kind = "project"; value = String(id)
            case .machines: kind = "machines"; value = nil
            case .academic: kind = "academic"; value = nil
            case .paper(let id): kind = "paper"; value = id
            case .machine, .newSession: return nil
            }
        }

        var route: Route? {
            switch kind {
            case "conversation": return value.flatMap(Int.init).map(Route.conversation)
            case "project": return value.flatMap(Int.init).map(Route.project)
            case "machines": return .machines
            case "academic": return .academic
            case "paper": return value.map(Route.paper)
            default: return nil
            }
        }
    }

    @MainActor init(workspace: ServerWorkspace) {
        configurationRevision = workspace.server.configurationRevision
        selectedTab = workspace.model.selectedTab.rawValue
        sidebarSection = workspace.model.sidebarSection?.rawValue
        conversationID = workspace.model.selectedConversationID
        paths = Dictionary(uniqueKeysWithValues: workspace.model.paths.map { tab, routes in
            var saved: [SavedRoute] = []
            for route in routes {
                guard let item = SavedRoute(route) else { break }
                saved.append(item)
            }
            return (tab.rawValue, saved)
        })
        contentPath = workspace.model.contentPath.compactMap(SavedRoute.init)
    }

    @MainActor func restore(into model: AppModel) {
        model.selectedTab = AppTab(rawValue: selectedTab) ?? .chats
        model.sidebarSection = sidebarSection.flatMap(SidebarSection.init(rawValue:)) ?? .chats
        model.selectedConversationID = conversationID
        model.paths = Dictionary(uniqueKeysWithValues: paths.compactMap { key, routes in
            guard let tab = AppTab(rawValue: key) else { return nil }
            return (tab, routes.compactMap(\.route))
        })
        model.contentPath = contentPath.compactMap(\.route)
    }
}
