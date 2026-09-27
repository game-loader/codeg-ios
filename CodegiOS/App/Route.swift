import SwiftUI

/// The five top-level tabs of the compact (iPhone) shell: four content tabs
/// plus the system search tab (rendered by iOS 26 as the separated glass
/// magnifier next to the tab bar). Regular width (iPad) maps the same
/// destinations onto the split view's sidebar instead.
enum AppTab: String, Hashable, CaseIterable {
    case chats
    case projects
    case activity
    case settings
    case search
}

/// iPad sidebar selection — the split view's "source list". Settings is
/// presented as a sheet on iPad (gear in the sidebar toolbar), and search rides
/// the content column, so neither needs a sidebar row.
enum SidebarSection: String, Hashable {
    case chats
    case projects
    case activity
    case machines
    case academic
}

/// Workspace-wide tools: rows at the top of the Folders tab on iPhone (the tab
/// bar is full), sidebar rows on iPad.
enum WorkspaceTool: String, Hashable, CaseIterable {
    case machines
    case academic

    var title: LocalizedStringKey {
        switch self {
        case .machines: "Machines"
        case .academic: "Academic"
        }
    }

    var systemImage: String {
        switch self {
        case .machines: "server.rack"
        case .academic: "books.vertical"
        }
    }

    var route: Route {
        switch self {
        case .machines: .machines
        case .academic: .academic
        }
    }

    var sidebarSection: SidebarSection {
        switch self {
        case .machines: .machines
        case .academic: .academic
        }
    }
}

/// A pushable destination. Every entry point (list rows, search results,
/// activity, the running bar, deep links, future push notifications) converges
/// on this enum so navigation behaves identically regardless of origin.
enum Route: Hashable {
    case conversation(Int)
    case project(Int)
    case machines
    case machine(Machine)
    case academic
    /// An Academic paper, by id.
    case paper(String)
    /// The "start a new task" screen: a blank session detail. The agent, folder,
    /// and config are chosen in-page (from the nav-bar agent button), and the
    /// first send connects + prompts before a server conversation id exists
    /// (it adopts one on `conversation_linked`).
    case newSession(NewSessionRequest)
}

/// A draft new-task token. Carries only an optional preselected folder (e.g.
/// when launched from a project); the agent/folder/first message are all chosen
/// on the session screen itself, so this is just a stable identity for the
/// pushed/pending draft.
struct NewSessionRequest: Hashable, Identifiable {
    let id: UUID
    var preselectedFolderID: Int?
    /// A conversation about an Academic paper.
    var academic: AcademicDraft?

    init(id: UUID = UUID(), preselectedFolderID: Int? = nil, academic: AcademicDraft? = nil) {
        self.id = id
        self.preselectedFolderID = preselectedFolderID
        self.academic = academic
    }
}

/// A new conversation bound to a paper, as `academic_open_target` described
/// it: the research agent, in the paper's repository folder (the request's
/// preselected folder) or, with `chatMode`, in a scratch directory.
struct AcademicDraft: Hashable {
    let paperID: String
    let paperTitle: String
    let agent: AgentType
    let chatMode: Bool
}

/// The paper a conversation is about, for the context bar.
struct BoundPaper: Hashable, Identifiable {
    let id: String
    let title: String
}

extension Route {
    /// Parse a `codeg://` deep link: `codeg://conversation/<id>` and
    /// `codeg://project/<id>`. (`codeg://tab/<name>` switches tabs rather than
    /// pushing, so `AppModel.handle(url:)` deals with it before calling this.)
    static func from(url: URL) -> Route? {
        guard url.scheme?.lowercased() == "codeg" else { return nil }
        let id = url.pathComponents.count > 1 ? Int(url.pathComponents[1]) : nil
        switch url.host?.lowercased() {
        case "conversation": return id.map { .conversation($0) }
        case "project": return id.map { .project($0) }
        default: return nil
        }
    }
}
