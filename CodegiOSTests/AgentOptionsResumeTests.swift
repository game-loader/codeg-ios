import Foundation
import XCTest
@testable import Codeg

/// The options sheet of a conversation that already ran must show the mode and
/// config its own session resumes with. The server restores those per session
/// (possibly picked on another device, e.g. the desktop), ahead of this device's
/// `SelectorPrefsStore` defaults, so neither the probe catalog nor the local
/// prefs can stand in for them.
@MainActor
final class AgentOptionsResumeTests: XCTestCase {
    private let prefsKey = "codeg.selectorPrefs.v1"

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
        if !predicate() { throw URLError(.timedOut) }
    }

    private func resumable(_ h: RecoveryHarness, externalId: String?) {
        var detail = RecoveryFixtures.detail(text: "Reply")
        var summary = detail["summary"] as! [String: Any]
        if let externalId { summary["external_id"] = externalId }
        detail["summary"] = summary
        h.server.setDetailPayload(detail)
    }

    func testExistingConversationShowsItsResumedSessionsModeNotTheDeviceDefault() async throws {
        let saved = UserDefaults.standard.object(forKey: prefsKey)
        defer { UserDefaults.standard.set(saved, forKey: prefsKey) }
        SelectorPrefsStore.saveMode(agent: .claudeCode, modeId: "default")
        let h = try RecoveryHarness()
        defer { h.close() }
        resumable(h, externalId: "session-from-desktop")
        await h.model.load()
        // What the server restored for this session on resume.
        h.server.setConnectionSnapshot([
            "status": "connected", "modes": RecoveryFixtures.modes(current: "plan"),
            "config_options": [], "selectors_ready": true,
        ])
        let connects = h.server.count("acp_connect")

        h.model.agentOptions.prepare(agentType: .claudeCode, workingDir: nil)
        try await eventually { h.model.agentOptions.phase == .loaded }

        XCTAssertEqual(h.model.agentOptions.selectedModeId, "plan")
        XCTAssertEqual(h.server.count("acp_describe_agent_options"), 0)
        XCTAssertEqual(h.server.count("acp_connect"), connects + 1)
        XCTAssertEqual(h.server.bodies("acp_connect").last?["sessionId"] as? String,
                       "session-from-desktop")
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }

    func testConversationWithoutASessionStillProbesWithDeviceDefaults() async throws {
        let saved = UserDefaults.standard.object(forKey: prefsKey)
        defer { UserDefaults.standard.set(saved, forKey: prefsKey) }
        SelectorPrefsStore.saveMode(agent: .claudeCode, modeId: "plan")
        let h = try RecoveryHarness()
        defer { h.close() }
        resumable(h, externalId: nil)
        await h.model.load()
        let connects = h.server.count("acp_connect")

        h.model.agentOptions.prepare(agentType: .claudeCode, workingDir: nil)
        try await eventually { h.model.agentOptions.phase == .loaded }

        XCTAssertEqual(h.server.count("acp_describe_agent_options"), 1)
        XCTAssertEqual(h.server.count("acp_connect"), connects)
        XCTAssertEqual(h.model.agentOptions.selectedModeId, "plan")
        XCTAssertTrue(h.server.unexpectedRequests.isEmpty)
    }
}
