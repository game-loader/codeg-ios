import Foundation
import XCTest
@testable import Codeg

@MainActor
final class NotificationRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var previousSelectedServer: Any?
    private let first = ServerProfile(name: "First", urlString: "https://first.example")
    private let second = ServerProfile(name: "Second", urlString: "https://second.example")

    override func setUp() async throws {
        suite = "NotificationRoutingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "codeg.servers.v1")
        previousSelectedServer = UserDefaults.standard.object(forKey: "codeg.lastSelectedServerID")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        if let previousSelectedServer {
            UserDefaults.standard.set(previousSelectedServer, forKey: "codeg.lastSelectedServerID")
        } else {
            UserDefaults.standard.removeObject(forKey: "codeg.lastSelectedServerID")
        }
    }

    private func app(compact: Bool) -> AppModel {
        let app = AppModel(serverStore: ServerStore(defaults: defaults))
        app.selectedServerID = first.id
        app.isCompact = compact
        return app
    }

    func testKnownServerSelectedBeforeConversationNavigationOnBothShells() {
        for compact in [true, false] {
            let model = app(compact: compact)
            model.paths[.projects] = [.project(1)]
            model.contentPath = [.project(1)]
            model.settingsPath = [.general]
            model.sidebarSection = .projects
            model.selectedConversationID = 7
            model.handle(url: URL(string: "codeg://conversation/42?server_id=\(second.id.uuidString)")!)
            XCTAssertEqual(model.selectedServerID, second.id)
            XCTAssertTrue(model.settingsPath.isEmpty)
            XCTAssertTrue(model.contentPath.isEmpty)
            XCTAssertNil(model.paths[.projects])
            // Simulate the later SwiftUI onChange callback. It must not erase
            // the destination that was opened after the synchronous reset.
            model.selectedServerChanged(from: first, to: second)
            if compact {
                XCTAssertEqual(model.selectedTab, .chats)
                XCTAssertEqual(model.paths[.chats], [.conversation(42)])
            } else {
                XCTAssertEqual(model.selectedConversationID, 42)
                XCTAssertEqual(model.sidebarSection, .chats)
            }
        }
    }

    func testNotificationTestLinkSelectsServerAndOpensSettingsOnBothShells() {
        for compact in [true, false] {
            let model = app(compact: compact)
            model.handle(url: URL(string: "codeg://settings/notifications?server_id=\(second.id.uuidString.lowercased())")!)
            model.selectedServerChanged(from: first, to: second)
            XCTAssertEqual(model.selectedServerID, second.id)
            XCTAssertEqual(model.settingsPath, [.notifications])
            if compact { XCTAssertEqual(model.selectedTab, .settings) }
            else { XCTAssertTrue(model.settingsSheetPresented) }
        }
    }

    func testUnknownMalformedEmptyAndDuplicateExplicitIDsLeaveStateUntouched() {
        let invalidQueries = [
            "server_id=\(UUID().uuidString)", "server_id=not-a-uuid", "server_id=", "server_id",
            "server_id=\(second.id.uuidString)&server_id=\(first.id.uuidString)",
            "server_id=\(second.id.uuidString)&server_id=\(second.id.uuidString)"
        ]
        for compact in [true, false] {
            let model = app(compact: compact)
            model.selectedTab = .projects
            model.paths[.projects] = [.project(7)]
            model.settingsPath = [.general]
            model.selectedConversationID = 7
            for query in invalidQueries {
                for target in ["conversation/42", "settings/notifications", "tab/chats"] {
                    model.handle(url: URL(string: "codeg://\(target)?\(query)")!)
                    XCTAssertEqual(model.selectedServerID, first.id)
                    XCTAssertEqual(model.selectedTab, .projects)
                    XCTAssertEqual(model.paths[.projects], [.project(7)])
                    XCTAssertEqual(model.settingsPath, [.general])
                    XCTAssertEqual(model.selectedConversationID, 7)
                    XCTAssertFalse(model.settingsSheetPresented)
                }
            }
        }
    }

    func testLegacyLinksKeepCurrentServerAndSameServerLinksStillNavigate() {
        let model = app(compact: true)
        model.handle(url: URL(string: "codeg://conversation/42")!)
        XCTAssertEqual(model.selectedServerID, first.id)
        XCTAssertEqual(model.paths[.chats], [.conversation(42)])
        model.handle(url: URL(string: "codeg://settings/notifications")!)
        XCTAssertEqual(model.settingsPath, [.notifications])
        model.handle(url: URL(string: "codeg://conversation/43?server_id=\(first.id.uuidString)")!)
        XCTAssertEqual(model.paths[.chats], [.conversation(43)])
        XCTAssertEqual(model.selectedServerID, first.id)
    }

    func testInPlaceEndpointEditStillClearsServerScopedNavigation() {
        let model = app(compact: true)
        model.paths[.chats] = [.conversation(42)]
        model.settingsPath = [.notifications]
        var edited = first
        edited.urlString = "https://replacement.example"
        model.selectedServerChanged(from: first, to: edited)
        XCTAssertTrue(model.paths.isEmpty)
        XCTAssertTrue(model.settingsPath.isEmpty)
    }
}
