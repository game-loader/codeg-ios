import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Codeg

@MainActor
final class ConversationTagWireTests: XCTestCase {
    func testOldAndNewSummariesAndInitializer() async throws {
        for value in [nil, [], [1, 9]] as [[Int]?] {
            let data = try JSONSerialization.data(withJSONObject: ConversationTagTestServer.summary(tagIDs: value))
            let summary = try CodegJSON.decoder.decode(ConversationSummary.self, from: data)
            XCTAssertEqual(summary.tagIds, value ?? [])
            XCTAssertEqual(summary.folderId, 7)
            XCTAssertNil(summary.pinnedAt)
        }
        var nullTags = ConversationTagTestServer.summary(tagIDs: nil)
        nullTags["tag_ids"] = NSNull()
        nullTags["pinned_at"] = "2026-10-14T01:02:03.123456Z"
        let summary = try CodegJSON.decoder.decode(ConversationSummary.self,
            from: JSONSerialization.data(withJSONObject: nullTags))
        XCTAssertTrue(summary.isPinned)
        XCTAssertEqual(summary.tagIds, [])
        let old = ConversationSummary(id: 1, folderId: 7, title: nil, agentType: .codex,
            status: .completed, model: nil, gitBranch: nil, externalId: nil,
            messageCount: 0, createdAt: .distantPast, updatedAt: .distantPast)
        XCTAssertEqual(old.tagIds, [])
        var malformed = ConversationTagTestServer.summary(tagIDs: nil)
        malformed["tag_ids"] = "bad"
        XCTAssertThrowsError(try CodegJSON.decoder.decode(ConversationSummary.self,
            from: JSONSerialization.data(withJSONObject: malformed)))
        var tagged = summary
        tagged.tagIds = [1, 9]
        let roundTrip = try CodegJSON.decoder.decode(ConversationSummary.self,
            from: CodegJSON.encoder.encode(tagged))
        XCTAssertEqual(roundTrip.tagIds, [1, 9])
        XCTAssertEqual(roundTrip.folderId, tagged.folderId)
        XCTAssertTrue(roundTrip.isPinned)
    }

    func testEveryEndpointUsesExactCamelBodiesAndSnakeResponses() async throws {
        let fixture = ConversationTagTestFixture(label: "wire")
        defer { fixture.close() }
        fixture.server.setTags([ConversationTagTestServer.tag(1, folder: 7, name: "Existing", order: 4)])
        let listed = try await fixture.client.listConversationTags()
        XCTAssertEqual(listed.first?.folderId, 7)
        XCTAssertEqual(listed.first?.sortOrder, 4)
        let created = try await fixture.client.createConversationTag(folderId: 7, name: "New", color: "#aabbcc")
        XCTAssertEqual(created.folderId, 7)
        _ = try await fixture.client.createConversationTag(name: "Global", color: "#112233")
        let updated = try await fixture.client.updateConversationTag(tagId: created.id, color: "#445566")
        XCTAssertEqual(updated.name, "New")
        XCTAssertEqual(updated.color, "#445566")
        try await fixture.client.reorderConversationTags(tagIds: [created.id, 1])
        let assigned = try await fixture.client.updateConversationTags(conversationId: 42, add: [created.id], remove: [1])
        XCTAssertEqual(assigned.tagIds, [created.id, 900].sorted())
        let settings = try await fixture.client.getConversationBranchTag()
        XCTAssertEqual(settings, ConversationBranchTag(enabled: true, color: "#6e7781"))
        let changed = try await fixture.client.updateConversationBranchTag(enabled: false, color: "#abcdef")
        XCTAssertFalse(changed.enabled)
        try await fixture.client.deleteConversationTag(tagId: created.id)
        let createBodies = fixture.server.bodies("create_conversation_tag")
        XCTAssertEqual(Set(createBodies[0].keys), ["folderId", "name", "color"])
        XCTAssertEqual(createBodies[0]["folderId"] as? Int, 7)
        XCTAssertEqual(Set(createBodies[1].keys), ["name", "color"])
        XCTAssertEqual(Set(try XCTUnwrap(fixture.server.bodies("update_conversation_tag").first).keys), ["tagId", "color"])
        XCTAssertEqual(Set(try XCTUnwrap(fixture.server.bodies("delete_conversation_tag").first).keys), ["tagId"])
        XCTAssertEqual(fixture.server.bodies("reorder_conversation_tags").first?["tagIds"] as? [Int], [created.id, 1])
        let delta = try XCTUnwrap(fixture.server.bodies("update_conversation_tags").first)
        XCTAssertEqual(Set(delta.keys), ["conversationId", "add", "remove"])
        XCTAssertEqual(delta["conversationId"] as? Int, 42)
        XCTAssertEqual(delta["add"] as? [Int], [created.id])
        XCTAssertEqual(delta["remove"] as? [Int], [1])
        XCTAssertEqual(Set(try XCTUnwrap(fixture.server.bodies("update_conversation_branch_tag").first).keys), ["enabled", "color"])
        XCTAssertTrue(fixture.server.bodies("list_conversation_tags").first?.isEmpty == true)
        XCTAssertTrue(fixture.server.bodies("get_conversation_branch_tag").first?.isEmpty == true)
        XCTAssertTrue(fixture.server.requests.allSatisfy { $0.method == "POST" && $0.authorization == "Bearer wire" })
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testMissingRouteIsUnsupportedButResourceAuthValidationAndDecodeFailuresSurface() async throws {
        let fixture = ConversationTagTestFixture(label: "errors")
        defer { fixture.close() }
        fixture.server.failNext("list_conversation_tags", status: 404)
        let model = ConversationTagsModel(client: fixture.client)
        await model.load()
        XCTAssertTrue(model.isUnsupported)
        XCTAssertNil(model.errorMessage)
        await model.load()
        XCTAssertEqual(fixture.server.bodies("list_conversation_tags").count, 1)
        let conversations: [ConversationSummary] = try await fixture.client.postReadJSON("list_all_conversations", EmptyBody())
        XCTAssertTrue(conversations.isEmpty)
        for (status, code) in [(404, "not_found"), (422, "invalid_color"), (500, "internal_error"), (401, "unauthorized")] {
            let live = ConversationTagsModel(client: fixture.client)
            fixture.server.failNext("update_conversation_tag", status: status, code: code)
            let result = await live.update(tagID: 1, name: "New")
            XCTAssertNil(result)
            XCTAssertFalse(live.isUnsupported)
            XCTAssertNotNil(live.errorMessage)
        }
        fixture.server.respondNext("list_conversation_tags", json: ["wrong": true])
        let malformed = ConversationTagsModel(client: fixture.client)
        await malformed.load()
        XCTAssertNotNil(malformed.errorMessage)
        XCTAssertFalse(malformed.isUnsupported)
    }

    func testBranchRouteSupportIsIndependentAndOrderIsCanonical() async throws {
        let fixture = ConversationTagTestFixture(label: "branch")
        defer { fixture.close() }
        fixture.server.setTags([
            ConversationTagTestServer.tag(5, folder: 9, name: "Nine", order: 1),
            ConversationTagTestServer.tag(3, folder: nil, name: "Global three", order: 2),
            ConversationTagTestServer.tag(2, folder: nil, name: "Global two", order: 2),
            ConversationTagTestServer.tag(1, folder: 7, name: "Seven", order: 10)
        ])
        let model = ConversationTagsModel(client: fixture.client)
        fixture.server.failNext("get_conversation_branch_tag", status: 404)
        await model.loadBranchSettings()
        XCTAssertTrue(model.isBranchSettingsUnsupported)
        XCTAssertFalse(model.isUnsupported)
        XCTAssertNil(model.errorMessage)
        await model.load()
        XCTAssertEqual(model.tags.map(\.id), [2, 3, 1, 5])
        let reordered = await model.reorder(tagIDs: [3, 2])
        XCTAssertTrue(reordered)
        XCTAssertEqual(model.tags.map(\.id), [3, 2, 1, 5])
        XCTAssertEqual(model.tags.prefix(2).map(\.sortOrder), [1, 2])
        await model.load()
        XCTAssertEqual(model.tags.map(\.id), [3, 2, 1, 5])
    }
}

/// Real URLProtocol transport, host-specific state, and explicitly held replies.
/// Shared by the wire/isolation tests and compiled unchanged by the portable runner.
final class ConversationTagTestServer: @unchecked Sendable {
    struct RecordedRequest {
        let path: String
        let body: [String: Any]
        let method: String?
        let authorization: String?
    }
    private struct Reply { let status: Int; let data: Data }
    private let lock = NSLock()
    private var tagRows: [[String: Any]] = []
    private var assignments: Set<Int> = [900]
    private var branch: [String: Any] = ["enabled": true, "color": "#6e7781"]
    private var recorded: [RecordedRequest] = []
    private var failures: [String: [Reply]] = [:]
    private var holdNextPaths: Set<String> = []
    private var held: [String: [() -> Void]] = [:]
    private var unknown: [String] = []
    var requests: [RecordedRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var unexpected: [String] { lock.lock(); defer { lock.unlock() }; return unknown }

    static func tag(_ id: Int, folder: Int?, name: String, order: Int = 1) -> [String: Any] {
        ["id": id, "folder_id": folder.map { $0 as Any } ?? NSNull(), "name": name, "color": "#0969da", "sort_order": order]
    }
    static func summary(tagIDs: [Int]?) -> [String: Any] {
        var result: [String: Any] = ["id": 42, "folder_id": 7, "title": "Session", "agent_type": "codex",
            "status": "completed", "message_count": 1, "created_at": "2026-10-14T01:02:03Z", "updated_at": "2026-10-14T01:02:03Z"]
        if let tagIDs { result["tag_ids"] = tagIDs }
        return result
    }
    func setTags(_ tags: [[String: Any]]) { lock.lock(); defer { lock.unlock() }; tagRows = tags }
    func bodies(_ path: String) -> [[String: Any]] { requests.filter { $0.path == path }.map(\.body) }
    func failNext(_ path: String, status: Int, code: String? = nil) {
        var json: [String: Any] = ["message": "Fixture failure"]
        if let code { json["code"] = code }
        respondNext(path, status: status, json: json)
    }
    func respondNext(_ path: String, status: Int = 200, json: Any) {
        let reply = Reply(status: status, data: try! JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]))
        lock.lock(); defer { lock.unlock() }
        failures[path, default: []].append(reply)
    }
    func holdNext(_ path: String) { lock.lock(); defer { lock.unlock() }; holdNextPaths.insert(path) }
    func hasHeld(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !(held[path] ?? []).isEmpty }
    func release(_ path: String) {
        lock.lock(); let deliveries = held.removeValue(forKey: path) ?? []; lock.unlock()
        deliveries.forEach { $0() }
    }
    func receive(_ request: URLRequest, deliver: @escaping (Int, Data) -> Void) {
        let path = request.url!.lastPathComponent
        let bodyData: Data
        if let data = request.httpBody { bodyData = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            bodyData = data
        } else { bodyData = Data("{}".utf8) }
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        lock.lock()
        recorded.append(RecordedRequest(path: path, body: body, method: request.httpMethod,
                                        authorization: request.value(forHTTPHeaderField: "Authorization")))
        let reply: Reply
        if let first = failures[path]?.first {
            failures[path]?.removeFirst()
            reply = first
        } else {
            let json: Any
            switch path {
            case "list_conversation_tags": json = tagRows
            case "create_conversation_tag":
                let id = (tagRows.compactMap { $0["id"] as? Int }.max() ?? 0) + 1
                var row = Self.tag(id, folder: body["folderId"] as? Int, name: body["name"] as? String ?? "")
                row["color"] = body["color"]
                tagRows.append(row); json = row
            case "update_conversation_tag":
                if let index = tagRows.firstIndex(where: { $0["id"] as? Int == body["tagId"] as? Int }) {
                    if let name = body["name"] { tagRows[index]["name"] = name }
                    if let color = body["color"] { tagRows[index]["color"] = color }
                    json = tagRows[index]
                } else { json = Self.tag(body["tagId"] as? Int ?? 1, folder: nil, name: "Updated") }
            case "delete_conversation_tag":
                let id = body["tagId"] as? Int
                tagRows.removeAll { $0["id"] as? Int == id }
                if let id { assignments.remove(id) }
                json = NSNull()
            case "reorder_conversation_tags":
                for (order, id) in (body["tagIds"] as? [Int] ?? []).enumerated() {
                    if let index = tagRows.firstIndex(where: { $0["id"] as? Int == id }) { tagRows[index]["sort_order"] = order + 1 }
                }
                json = NSNull()
            case "update_conversation_tags":
                assignments.subtract(body["remove"] as? [Int] ?? [])
                assignments.formUnion(body["add"] as? [Int] ?? [])
                json = Self.summary(tagIDs: assignments.sorted())
            case "get_conversation_branch_tag": json = branch
            case "update_conversation_branch_tag": branch = body; json = branch
            case "list_all_conversations": json = [] as [Any]
            default: unknown.append(path); json = NSNull()
            }
            reply = Reply(status: 200, data: try! JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]))
        }
        let delivery = { deliver(reply.status, reply.data) }
        if holdNextPaths.remove(path) != nil {
            held[path, default: []].append(delivery)
            lock.unlock()
        } else { lock.unlock(); delivery() }
    }
}

final class ConversationTagTestProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: ConversationTagTestServer] = [:]
    static func register(_ server: ConversationTagTestServer, host: String) { lock.lock(); defer { lock.unlock() }; servers[host] = server }
    static func unregister(_ host: String) { lock.lock(); defer { lock.unlock() }; servers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".tags.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url!.host!]; Self.lock.unlock()
        guard let server else { client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return }
        server.receive(request) { [self] status, data in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

struct ConversationTagTestFixture {
    let server = ConversationTagTestServer()
    let lifetime = ServerBindingLifetime()
    let session: URLSession
    let client: CodegClient
    let host: String
    init(label: String) {
        host = UUID().uuidString.lowercased() + ".tags.invalid"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConversationTagTestProtocol.self]
        session = URLSession(configuration: config)
        client = CodegClient(baseURL: URL(string: "https://\(host)")!, token: label,
            session: session, readSession: session, probeSession: session, bindingLifetime: lifetime)
        ConversationTagTestProtocol.register(server, host: host)
    }
    func close() { session.invalidateAndCancel(); ConversationTagTestProtocol.unregister(host) }
    func waitForHeld(_ path: String) async throws {
        for _ in 0..<400 {
            if server.hasHeld(path) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("HTTP reply was never held: \(path)")
        throw URLError(.timedOut)
    }
}
