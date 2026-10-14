import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Codeg

@MainActor
final class GenerativeUISettingsTests: XCTestCase {
    func testRealRequestsUseCamelCaseOpsAndDecodeSnakeCaseResponses() async throws {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        let info = try await fixture.client.generativeUISkillInfo()
        let agents = try await fixture.client.generativeUIAgents()
        let statuses = try await fixture.client.generativeUIInstallStatuses()
        XCTAssertEqual(info.id, "ui-render")
        XCTAssertFalse(info.conflict)
        XCTAssertEqual(agents.map(\.agentType), [.codex, .claudeCode, .other("custom:goose")])
        XCTAssertEqual(statuses.first?.linkPath, "/server/codex/skills/ui-render")
        let results = try await fixture.client.generativeUIApplyLinks([
            .init(agentType: .codex, enable: true),
            .init(agentType: .other("custom:goose"), enable: false)
        ])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy(\.ok))
        XCTAssertEqual(results[0].status?.agentType, .codex)
        XCTAssertEqual(results[0].status?.state, .linkedToCodeg)
        let body = try XCTUnwrap(fixture.server.bodies("generative_ui_apply_links").first)
        XCTAssertEqual(Set(body.keys), ["ops"])
        let ops = try XCTUnwrap(body["ops"] as? [[String: Any]])
        XCTAssertEqual(Set(ops[0].keys), ["expertId", "agentType", "enable"])
        XCTAssertEqual(ops[0]["expertId"] as? String, "ui-render")
        XCTAssertEqual(ops[0]["agentType"] as? String, "codex")
        XCTAssertEqual(ops[1]["agentType"] as? String, "custom:goose")
        XCTAssertEqual(ops[1]["enable"] as? Bool, false)
        XCTAssertTrue(fixture.server.validationErrors.isEmpty)
    }

    func testExistingExpertStatusAlsoAcceptsActualCamelCaseResponse() throws {
        let data = Data(#"{"expertId":"ui-render","agentType":"custom:goose","state":"linked_to_codeg","linkPath":"/shared/ui-render","targetPath":"/central/ui-render","expectedTargetPath":"/central/ui-render","copyMode":false}"#.utf8)
        let status = try CodegJSON.decoder.decode(ExpertInstallStatus.self, from: data)
        XCTAssertEqual(status.agentType, .other("custom:goose"))
        XCTAssertEqual(status.state, .linkedToCodeg)
        XCTAssertEqual(status.expectedTargetPath, "/central/ui-render")
    }

    func testSameAgentIDsOnTwoServersKeepReadsWritesAndCredentialsSeparate() async throws {
        let a = RenderSettingsFixture()
        let b = RenderSettingsFixture()
        defer { a.close(); b.close() }
        b.server.setStatuses([RenderSettingsServer.status("codex", linked: true)])
        let modelA = a.model(name: "Server A")
        let modelB = b.model(name: "Server B")
        await modelA.load()
        await modelB.load()
        let agentA = try XCTUnwrap(modelA.agents.first { $0.agentType == .codex })
        let agentB = try XCTUnwrap(modelB.agents.first { $0.agentType == .codex })
        XCTAssertEqual(agentA.id, agentB.id)
        XCTAssertEqual(modelA.status(for: agentA)?.state, .notLinked)
        XCTAssertEqual(modelB.status(for: agentB)?.state, .linkedToCodeg)
        await modelA.setEnabled(true, for: agentA)
        XCTAssertEqual(a.server.bodies("generative_ui_apply_links").count, 1)
        XCTAssertTrue(b.server.bodies("generative_ui_apply_links").isEmpty)
        XCTAssertEqual(modelB.status(for: agentB)?.state, .linkedToCodeg)
        XCTAssertNotEqual(modelA.serverID, modelB.serverID)
        XCTAssertEqual(modelA.serverName, "Server A")
        XCTAssertEqual(modelA.serverLocation, a.client.baseURL.absoluteString)
        XCTAssertTrue(a.server.validationErrors.isEmpty)
        XCTAssertTrue(b.server.validationErrors.isEmpty)
    }

    func testRetiredDelayedLoadIsNeverPublishedAndCannotWrite() async throws {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        let gate = RenderSettingsGate()
        fixture.server.enqueue("generative_ui_skill_info", .init(json: ["id": "ui-render", "conflict": false], gate: gate))
        let model = fixture.model()
        let task = Task { await model.load() }
        await fulfillment(of: [gate.received], timeout: 2)
        fixture.lifetime.invalidate()
        gate.release()
        await task.value
        XCTAssertNil(model.skill)
        XCTAssertTrue(model.agents.isEmpty)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.isRetired)
        await model.apply([.init(agentType: .codex, enable: true)])
        XCTAssertTrue(fixture.server.bodies("generative_ui_apply_links").isEmpty)
    }

    func testRetiredDelayedWriteDoesNotPublishOrStartReconciliationOnReplacement() async throws {
        let a = RenderSettingsFixture()
        let b = RenderSettingsFixture()
        defer { a.close(); b.close() }
        let modelA = a.model()
        let modelB = b.model()
        await modelA.load()
        await modelB.load()
        let agent = try XCTUnwrap(modelA.agents.first { $0.agentType == .codex })
        let gate = RenderSettingsGate()
        a.server.enqueue("generative_ui_apply_links", .init(json: [RenderSettingsServer.result("codex", ok: true)], gate: gate))
        let task = Task { await modelA.setEnabled(true, for: agent) }
        await fulfillment(of: [gate.received], timeout: 2)
        XCTAssertEqual(modelA.status(for: agent)?.state, .notLinked, "No optimistic success while awaiting the server")
        a.lifetime.invalidate()
        gate.release()
        await task.value
        XCTAssertEqual(modelA.statuses[.codex]?.state, .notLinked)
        XCTAssertTrue(modelA.actionErrors.isEmpty)
        XCTAssertEqual(a.server.bodies("generative_ui_list_all_install_statuses").count, 1)
        XCTAssertEqual(b.server.bodies("generative_ui_list_all_install_statuses").count, 1)
        XCTAssertTrue(b.server.bodies("generative_ui_apply_links").isEmpty)
    }

    func testFallbackRevisionGuardRejectsLateResultsWithoutRetargeting() async {
        let fixture = RenderSettingsFixture(bound: false)
        defer { fixture.close() }
        let revision = RenderSettingsRevision()
        let gate = RenderSettingsGate()
        fixture.server.enqueue("generative_ui_skill_info", .init(json: ["id": "ui-render", "conflict": false], gate: gate))
        let model = fixture.model(isCurrent: { revision.current })
        let task = Task { await model.load() }
        await fulfillment(of: [gate.received], timeout: 2)
        revision.current = false
        gate.release()
        await task.value
        XCTAssertNil(model.skill)
        XCTAssertTrue(model.statuses.isEmpty)
        XCTAssertTrue(model.isRetired)
        await model.load()
        XCTAssertEqual(fixture.server.bodies("generative_ui_skill_info").count, 1)
    }

    func testPartialBatchFailureKeepsFailedAgentOffAndReportsItsError() async throws {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        let model = fixture.model()
        await model.load()
        fixture.server.enqueue("generative_ui_apply_links", .init(json: [
            RenderSettingsServer.result("codex", ok: false, error: "permission denied"),
            RenderSettingsServer.result("claude_code", ok: true)
        ]))
        fixture.server.setStatuses([
            RenderSettingsServer.status("codex", linked: false),
            RenderSettingsServer.status("claude_code", linked: true)
        ])
        await model.apply([.init(agentType: .codex, enable: true), .init(agentType: .claudeCode, enable: true)])
        XCTAssertEqual(model.statuses[.codex]?.state, .notLinked)
        XCTAssertEqual(model.statuses[.claudeCode]?.state, .linkedToCodeg)
        XCTAssertEqual(model.actionErrors[.codex], "permission denied")
        XCTAssertNil(model.actionErrors[.claudeCode])
        XCTAssertFalse(model.needsRefresh)
    }

    func testFailureAfterPartialFilesystemChangeStillShowsFailureAndActualState() async {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        let model = fixture.model()
        await model.load()
        fixture.server.enqueue("generative_ui_apply_links", .init(json: [
            RenderSettingsServer.result("codex", ok: false, error: "legacy cleanup failed")
        ]))
        fixture.server.setStatuses([RenderSettingsServer.status("codex", linked: true)])
        await model.apply([.init(agentType: .codex, enable: true)])
        XCTAssertEqual(model.statuses[.codex]?.state, .linkedToCodeg)
        XCTAssertEqual(model.actionErrors[.codex], "legacy cleanup failed")
    }

    func testSuccessfulHTTPWithWrongAgentResultOrUnconfirmedStateIsNotSuccess() async {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        let model = fixture.model()
        await model.load()
        fixture.server.enqueue("generative_ui_apply_links", .init(json: [RenderSettingsServer.result("claude_code", ok: true)]))
        await model.apply([.init(agentType: .codex, enable: true)])
        XCTAssertEqual(model.statuses[.codex]?.state, .notLinked)
        XCTAssertNotNil(model.actionErrors[.codex])
        fixture.server.enqueue("generative_ui_apply_links", .init(json: [RenderSettingsServer.result("codex", ok: true)]))
        await model.apply([.init(agentType: .codex, enable: true)])
        XCTAssertEqual(model.statuses[.codex]?.state, .notLinked)
        XCTAssertNotNil(model.actionErrors[.codex])
    }

    func testCustomAgentsNeverInheritBuiltinStatusAndCustomWritesKeepExactID() async throws {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        fixture.server.setStatuses([RenderSettingsServer.status("codex", linked: true)])
        let model = fixture.model()
        await model.load()
        let custom = try XCTUnwrap(model.agents.first { $0.registryId == "goose" })
        XCTAssertNil(model.status(for: custom))
        XCTAssertFalse(model.canChange(custom))
        await model.setEnabled(true, for: custom)
        XCTAssertTrue(fixture.server.bodies("generative_ui_apply_links").isEmpty)
        fixture.server.setStatuses([RenderSettingsServer.status("custom:goose", linked: false)])
        await model.load()
        await model.setEnabled(true, for: custom)
        let body = try XCTUnwrap(fixture.server.bodies("generative_ui_apply_links").first)
        let ops = try XCTUnwrap(body["ops"] as? [[String: Any]])
        XCTAssertEqual(ops.first?["agentType"] as? String, "custom:goose")
        XCTAssertNil(model.actionErrors[.other("custom:goose")])
    }

    func testConflictAndForeignLinksBlockWritesAndCustomPiDirectoryIsExcluded() async {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        fixture.server.enqueue("generative_ui_skill_info", .init(json: ["id": "ui-render", "conflict": true]))
        let model = fixture.model()
        await model.load()
        XCTAssertTrue(model.agents.allSatisfy { !model.canChange($0) })
        await model.apply([.init(agentType: .codex, enable: true)])
        XCTAssertTrue(fixture.server.bodies("generative_ui_apply_links").isEmpty)
        fixture.server.enqueue("acp_list_agents", .init(json: [
            RenderSettingsServer.agent("codex", registry: "codex", skills: false),
            RenderSettingsServer.agent("pi", registry: "pi", env: ["PI_CODING_AGENT_DIR": "/custom"]),
            RenderSettingsServer.agent("custom:goose", registry: "different-agent"),
            RenderSettingsServer.agent("claude_code", registry: "claude")
        ]))
        var blocked = RenderSettingsServer.status("claude_code", linked: false)
        blocked["state"] = "blocked_by_real_directory"
        fixture.server.setStatuses([blocked])
        await model.load()
        XCTAssertEqual(model.agents.map(\.agentType), [.claudeCode])
        XCTAssertFalse(model.canChange(model.agents[0]))
    }

    func testRouteAndSchemaIncompatibilityShowUpgradeButAuthAndDomainErrorsStayDistinct() async {
        let cases: [(Int, Any, Bool)] = [
            (501, ["code": "not_implemented", "message": "endpoint unavailable"], true),
            (404, ["message": "Not Found"], true),
            (200, ["enabled": true], true),
            (401, ["message": "bad token"], false),
            (403, ["code": "forbidden", "message": "access denied"], false),
            (404, ["code": "skill_not_found", "message": "missing skill"], false),
            (500, ["code": "task_execution_failed", "message": "disk unavailable"], false)
        ]
        for (status, json, upgrade) in cases {
            let fixture = RenderSettingsFixture()
            fixture.server.enqueue("generative_ui_skill_info", .init(json: json, status: status))
            let model = fixture.model()
            await model.load()
            XCTAssertEqual(model.unsupported, upgrade, "HTTP \(status): \(json)")
            XCTAssertNotNil(model.loadError)
            XCTAssertTrue(model.needsRefresh)
            if upgrade { XCTAssertTrue(model.loadError?.contains("0.35.1") == true) }
            if status == 401 { XCTAssertTrue(model.loadError?.contains("Authentication failed") == true) }
            fixture.close()
        }
    }

    func testFailedReconciliationKeepsSnapshotAndDisablesWritesUntilRefresh() async throws {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        let model = fixture.model()
        await model.load()
        fixture.server.enqueue("generative_ui_list_all_install_statuses", .init(json: ["message": "unavailable"], status: 500))
        await model.apply([.init(agentType: .codex, enable: true)])
        XCTAssertEqual(model.statuses[.codex]?.state, .notLinked)
        XCTAssertNotNil(model.actionErrors[.codex])
        XCTAssertTrue(model.needsRefresh)
        XCTAssertFalse(model.canChange(try XCTUnwrap(model.agents.first)))
        await model.apply([.init(agentType: .codex, enable: false)])
        XCTAssertEqual(fixture.server.bodies("generative_ui_apply_links").count, 1)
        await model.load()
        XCTAssertFalse(model.needsRefresh)
        XCTAssertTrue(model.actionErrors.isEmpty)
        XCTAssertEqual(model.statuses[.codex]?.state, .linkedToCodeg)
    }

    func testDisableUsesFalseOpAndReconcilesOtherAgentsSharingDirectory() async {
        let fixture = RenderSettingsFixture()
        defer { fixture.close() }
        fixture.server.setStatuses([RenderSettingsServer.status("codex", linked: true), RenderSettingsServer.status("custom:goose", linked: true)])
        let model = fixture.model()
        await model.load()
        fixture.server.enqueue("generative_ui_apply_links", .init(json: [RenderSettingsServer.result("codex", ok: true)]))
        fixture.server.setStatuses([RenderSettingsServer.status("codex", linked: false), RenderSettingsServer.status("custom:goose", linked: false)])
        await model.apply([.init(agentType: .codex, enable: false)])
        XCTAssertEqual(model.statuses[.codex]?.state, .notLinked)
        XCTAssertEqual(model.statuses[.other("custom:goose")]?.state, .notLinked)
        XCTAssertTrue(model.actionErrors.isEmpty)
        let ops = fixture.server.bodies("generative_ui_apply_links").first?["ops"] as? [[String: Any]]
        XCTAssertEqual(ops?.first?["enable"] as? Bool, false)
    }
}

@MainActor
private final class RenderSettingsRevision { var current = true }

private struct RenderSettingsFixture {
    let host = "\(UUID().uuidString.lowercased()).render.invalid"
    let server = RenderSettingsServer()
    let lifetime = ServerBindingLifetime()
    let session: URLSession
    let client: CodegClient
    let serverID = UUID()
    let revision = UUID()

    init(bound: Bool = true) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RenderSettingsProtocol.self]
        session = URLSession(configuration: config)
        RenderSettingsProtocol.register(server, host: host)
        client = CodegClient(baseURL: URL(string: "https://\(host)/workspace")!, token: host,
                             session: session, readSession: session, probeSession: session,
                             bindingLifetime: bound ? lifetime : nil)
    }

    @MainActor
    func model(name: String = "Fixture", isCurrent: @escaping @MainActor () -> Bool = { true }) -> GenerativeUISettingsModel {
        GenerativeUISettingsModel(client: client, serverID: serverID, configurationRevision: revision,
                                  serverName: name, serverLocation: client.baseURL.absoluteString,
                                  scopeIsCurrent: isCurrent)
    }

    func close() {
        session.invalidateAndCancel()
        RenderSettingsProtocol.unregister(host: host)
    }
}

private struct RenderSettingsReply {
    let json: Any
    var status = 200
    var gate: RenderSettingsGate?
}

private final class RenderSettingsGate: @unchecked Sendable {
    let received = XCTestExpectation(description: "URLProtocol received delayed request")
    private let lock = NSLock()
    private var delivery: (() -> Void)?
    private var released = false

    func hold(_ delivery: @escaping () -> Void) {
        lock.lock()
        if released { lock.unlock(); received.fulfill(); delivery() }
        else { self.delivery = delivery; lock.unlock(); received.fulfill() }
    }

    func release() {
        lock.lock()
        released = true
        let delivery = self.delivery
        self.delivery = nil
        lock.unlock()
        delivery?()
    }
}

private final class RenderSettingsServer: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: [RenderSettingsReply]] = [:]
    private var requests: [(String, [String: Any])] = []
    private var errors: [String] = []
    private var statuses = [status("codex", linked: false), status("claude_code", linked: false), status("custom:goose", linked: false)]

    var validationErrors: [String] { lock.lock(); defer { lock.unlock() }; return errors }

    func enqueue(_ endpoint: String, _ reply: RenderSettingsReply) {
        lock.lock(); defer { lock.unlock() }
        replies[endpoint, default: []].append(reply)
    }

    func setStatuses(_ statuses: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        self.statuses = statuses
    }

    func bodies(_ endpoint: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.0 == endpoint }.map(\.1)
    }

    func reply(_ request: URLRequest, body: [String: Any]) throws -> RenderSettingsReply {
        lock.lock(); defer { lock.unlock() }
        let endpoint = request.url!.lastPathComponent
        let validHeaders = request.httpMethod == "POST"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(request.url!.host!)"
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
            && request.url!.path == "/workspace/api/\(endpoint)"
        let validBody: Bool
        if endpoint == "generative_ui_apply_links", let ops = body["ops"] as? [[String: Any]] {
            validBody = Set(body.keys) == ["ops"] && !ops.isEmpty && ops.allSatisfy {
                Set($0.keys) == ["expertId", "agentType", "enable"]
                    && $0["expertId"] as? String == "ui-render"
                    && $0["agentType"] is String && $0["enable"] is Bool
            }
        } else { validBody = body.isEmpty && endpoint != "generative_ui_apply_links" }
        guard validHeaders && validBody else {
            errors.append("Invalid request to \(endpoint)")
            throw URLError(.badServerResponse)
        }
        requests.append((endpoint, body))
        if var queue = replies[endpoint], !queue.isEmpty {
            let next = queue.removeFirst()
            replies[endpoint] = queue
            return next
        }
        switch endpoint {
        case "generative_ui_skill_info": return .init(json: ["id": "ui-render", "conflict": false])
        case "acp_list_agents": return .init(json: [
            Self.agent("codex", registry: "codex"), Self.agent("claude_code", registry: "claude"),
            Self.agent("custom:goose", registry: "goose")
        ])
        case "generative_ui_list_all_install_statuses": return .init(json: statuses)
        case "generative_ui_apply_links":
            let ops = body["ops"] as! [[String: Any]]
            let results = ops.map { op -> [String: Any] in
                let type = op["agentType"] as! String
                let enable = op["enable"] as! Bool
                statuses.removeAll { $0["agent_type"] as? String == type }
                statuses.append(Self.status(type, linked: enable))
                return Self.result(type, ok: true, includeStatus: enable)
            }
            return .init(json: results)
        default:
            errors.append("Unexpected endpoint \(endpoint)")
            throw URLError(.unsupportedURL)
        }
    }

    static func status(_ type: String, linked: Bool) -> [String: Any] {
        ["expert_id": "ui-render", "agent_type": type, "state": linked ? "linked_to_codeg" : "not_linked",
         "link_path": "/server/\(type)/skills/ui-render", "target_path": NSNull(),
         "expected_target_path": "/server/.codeg/skills/ui-render", "copy_mode": false]
    }

    static func result(_ type: String, ok: Bool, error: String? = nil, includeStatus: Bool = false) -> [String: Any] {
        ["expert_id": "ui-render", "agent_type": type, "ok": ok,
         "status": includeStatus ? status(type, linked: true) : NSNull(), "error": error as Any? ?? NSNull()]
    }

    static func agent(_ type: String, registry: String, skills: Bool = true, env: [String: String] = [:]) -> [String: Any] {
        ["agent_type": type, "registry_id": registry, "name": registry, "available": true,
         "enabled": true, "sort_order": 0, "skills_capable": skills, "env": env]
    }
}

private final class RenderSettingsProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var servers: [String: RenderSettingsServer] = [:]
    private let deliveryLock = NSLock()
    private var stopped = false

    static func register(_ server: RenderSettingsServer, host: String) {
        registryLock.lock(); defer { registryLock.unlock() }; servers[host] = server
    }

    static func unregister(host: String) {
        registryLock.lock(); defer { registryLock.unlock() }; servers[host] = nil
    }

    private static func server(host: String) -> RenderSettingsServer? {
        registryLock.lock(); defer { registryLock.unlock() }; return servers[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { deliveryLock.lock(); stopped = true; deliveryLock.unlock() }

    override func startLoading() {
        do {
            guard let host = request.url?.host, let server = Self.server(host: host) else { throw URLError(.unsupportedURL) }
            let reply = try server.reply(request, body: requestBody())
            let data = try JSONSerialization.data(withJSONObject: reply.json, options: [.fragmentsAllowed])
            let deliver = { [self] in
                deliveryLock.lock()
                let active = !stopped
                deliveryLock.unlock()
                guard active else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                               httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if let gate = reply.gate { gate.hold(deliver) } else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func requestBody() throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotDecodeRawData) }
        return body
    }
}
