import Foundation
import XCTest
@testable import Codeg

// Host-scoped registry for the explicitly injected HTTP and read sessions.
// Unknown routes fail closed; no request to the fixture host reaches a network.
final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var servers: [String: RecoveryServer] = [:]
    static func register(_ server: RecoveryServer, host: String) {
        lock.lock(); servers[host] = server; lock.unlock()
    }
    static func remove(host: String) {
        lock.lock(); servers.removeValue(forKey: host); lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".session-recovery.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let server = Self.servers[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let server else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        server.respond(to: request) { [weak self] status, data in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

// Explicit response barriers interleave user actions with a suspended refresh.
final class RecoveryResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivery: (() -> Void)?
    private var released = false
    private var received = false
    var hasRequest: Bool {
        lock.lock(); defer { lock.unlock() }; return received
    }
    func hold(_ delivery: @escaping () -> Void) {
        lock.lock(); received = true
        if released { lock.unlock(); delivery() }
        else { self.delivery = delivery; lock.unlock() }
    }
    func release() {
        lock.lock(); released = true
        let delivery = self.delivery; self.delivery = nil
        lock.unlock(); delivery?()
    }
}

final class RecoveryServer: @unchecked Sendable {
    private let lock = NSLock()
    private let agentType: AgentType
    private var detail: [String: Any]
    private var connection: Any = NSNull()
    private var detailStatus = 200
    private var nextGate: RecoveryResponseGate?
    private var promptGate: RecoveryResponseGate?
    private var promptStatus = 200
    private var promptID: String?
    private var counts: [String: Int] = [:]
    private var unexpected: [String] = []
    private var requests: [(route: String, body: [String: Any])] = []
    private var feedbackSettings: [String: Any] = ["enabled": false]
    private var feedbackSettingsStatus = 200
    private var connectionSnapshot: Any = NSNull()
    private var snapshotGate: RecoveryResponseGate?
    private var feedbackResponses: [(status: Int, payload: [String: Any], gate: RecoveryResponseGate?)] = []

    init(agentType: AgentType = .claudeCode) {
        self.agentType = agentType
        detail = RecoveryFixtures.detail(text: "Old reply", agentType: agentType)
    }
    func setFeedbackEnabled(_ enabled: Bool, httpStatus: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        feedbackSettings = ["enabled": enabled]; feedbackSettingsStatus = httpStatus
    }
    func setConnectionSnapshot(_ payload: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        connectionSnapshot = payload.map { $0 as Any } ?? NSNull()
    }
    func holdNextConnectionSnapshot() -> RecoveryResponseGate {
        lock.lock(); defer { lock.unlock() }
        let gate = RecoveryResponseGate(); snapshotGate = gate; return gate
    }
    @discardableResult
    func enqueueFeedbackResponse(_ payload: [String: Any], httpStatus: Int = 200,
                                 held: Bool = false) -> RecoveryResponseGate? {
        lock.lock(); defer { lock.unlock() }
        let gate = held ? RecoveryResponseGate() : nil
        feedbackResponses.append((httpStatus, payload, gate))
        return gate
    }
    func bodies(_ route: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.route == route }.map { $0.body }
    }
    var requestedRoutes: [String] {
        lock.lock(); defer { lock.unlock() }; return requests.map { $0.route }
    }
    func setDetail(text: String, status: String = "pending_review", httpStatus: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        detail = RecoveryFixtures.detail(text: text, status: status, agentType: agentType); detailStatus = httpStatus
    }
    func setConnected(_ connected: Bool) {
        lock.lock(); defer { lock.unlock() }
        if connected { connection = ["connection_id": "connection-42", "event_seq": 12] }
        else { connection = NSNull() }
    }
    func setDetailPayload(_ payload: [String: Any]) {
        lock.lock(); defer { lock.unlock() }; detail = payload
    }
    func holdNextPrompt(httpStatus: Int = 200) -> RecoveryResponseGate {
        lock.lock(); defer { lock.unlock() }
        let gate = RecoveryResponseGate(); promptGate = gate; promptStatus = httpStatus; return gate
    }
    var submittedMessageID: String? {
        lock.lock(); defer { lock.unlock() }; return promptID
    }
    func holdNextDetail() -> RecoveryResponseGate {
        lock.lock(); defer { lock.unlock() }
        let gate = RecoveryResponseGate(); nextGate = gate; return gate
    }
    func count(_ route: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return counts[route, default: 0]
    }
    var unexpectedRequests: [String] {
        lock.lock(); defer { lock.unlock() }; return unexpected
    }
    func respond(to request: URLRequest, completion: @escaping (Int, Data) -> Void) {
        lock.lock()
        let route = request.url!.lastPathComponent
        counts[route, default: 0] += 1
        let body = Self.requestBody(request)
        requests.append((route, body))
        var status = 200
        var payload: Any = NSNull()
        var gate: RecoveryResponseGate?
        if request.httpMethod != "POST" || request.url?.path != "/api/\(route)" {
            unexpected.append("\(request.httpMethod ?? "nil") \(request.url!.path)"); status = 500
        } else {
            switch route {
            case "get_folder_conversation":
                payload = detail; status = detailStatus; gate = nextGate; nextGate = nil
            case "list_all_folder_details", "list_open_folder_details":
                var folder = RecoveryFixtures.folder
                folder["default_agent_type"] = agentType.rawValue
                payload = [folder]
            case "acp_list_agents": payload = []
            case "acp_find_connection_for_conversation": payload = connection
            case "acp_connect": payload = "connection-42"
            case "create_conversation": payload = 42
            case "acp_prompt":
                promptID = body["clientMessageId"] as? String
                gate = promptGate; promptGate = nil; status = promptStatus; promptStatus = 200
            case "acp_cancel": break
            case "get_feedback_settings":
                payload = feedbackSettings; status = feedbackSettingsStatus
            case "submit_session_feedback":
                if feedbackResponses.isEmpty {
                    payload = RecoveryFixtures.feedback(id: "feedback-\(counts[route]!)",
                                                         text: body["text"] as? String ?? "", status: "delivered")
                } else {
                    let response = feedbackResponses.removeFirst()
                    payload = response.payload; status = response.status; gate = response.gate
                }
            case "acp_get_session_snapshot_by_conversation": break
            case "acp_get_session_snapshot":
                payload = connectionSnapshot; gate = snapshotGate; snapshotGate = nil
            default: unexpected.append(route); status = 500
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        lock.unlock()
        if let gate { gate.hold { completion(status, data) } }
        else { completion(status, data) }
    }
    // URLSession may move an encoded body into a stream before URLProtocol sees it.
    private static func requestBody(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

final class RecoveryEventStream: SessionEventStream, @unchecked Sendable {
    let frames: AsyncStream<EventStream.Frame>
    private let continuation: AsyncStream<EventStream.Frame>.Continuation
    private let snapshot: LiveSessionSnapshot
    private let deliversSnapshot: Bool
    private let lock = NSLock()
    private var attachments: [(String, UInt64?)] = []
    private var closed = false
    init(snapshot: LiveSessionSnapshot, deliversSnapshot: Bool = true) {
        self.snapshot = snapshot
        self.deliversSnapshot = deliversSnapshot
        let pair = AsyncStream<EventStream.Frame>.makeStream()
        frames = pair.stream; continuation = pair.continuation
    }
    func start() { continuation.yield(.ready) }
    func attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64?) {
        lock.lock(); attachments.append((connectionId, sinceSeq)); lock.unlock()
        if deliversSnapshot { continuation.yield(.snapshot(snapshot)) }
    }
    func detach(subscriptionId: String) {}
    func close() {
        lock.lock(); closed = true; lock.unlock(); continuation.finish()
    }
    func emit(_ frame: EventStream.Frame) { continuation.yield(frame) }
    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }; return closed
    }
    var attachedWithoutReplay: Bool {
        lock.lock(); defer { lock.unlock() }
        return attachments.contains { $0.0 == "connection-42" && $0.1 == nil }
    }
    var attachCount: Int {
        lock.lock(); defer { lock.unlock() }; return attachments.count
    }
}

enum RecoveryFixtures {
    static let date = "2026-09-29T00:00:00Z"
    static let folder: [String: Any] = [
        "id": 7, "name": "Regression", "path": "/tmp/regression",
        "last_opened_at": date, "sort_order": 0, "color": "blue",
        "default_agent_type": "claude_code"
    ]
    static func detail(text: String, status: String = "pending_review", agentType: AgentType = .claudeCode) -> [String: Any] {
        ["summary": ["id": 42, "folder_id": 7, "title": "Recovery",
                     "agent_type": agentType.rawValue, "status": status,
                     "message_count": 2, "created_at": date, "updated_at": date],
         "turns": [["id": "user-1", "role": "user", "timestamp": date,
                    "blocks": [["type": "text", "text": "Explain recovery"]]],
                   ["id": "assistant-1", "role": "assistant", "timestamp": date,
                    "blocks": [["type": "text", "text": text]]]]]
    }
    static func snapshot(text: String? = nil, pending: Bool = false, messageID: String? = nil,
                         nativeSteeringAvailable: Bool? = nil, feedback: [[String: Any]]? = nil,
                         activeToolCalls: [[String: Any]]? = nil) throws -> LiveSessionSnapshot {
        var json: [String: Any] = ["connection_id": "connection-42", "conversation_id": 42,
                                   "status": text == nil ? "connected" : "prompting", "event_seq": 12]
        if let nativeSteeringAvailable { json["native_steering_available"] = nativeSteeringAvailable }
        if let feedback { json["feedback"] = feedback }
        if let activeToolCalls { json["active_tool_calls"] = activeToolCalls }
        if let text {
            var content: [[String: Any]] = [["kind": "text", "text": text]]
            content += (activeToolCalls ?? []).compactMap { tool -> [String: Any]? in
                guard let id = tool["id"] as? String else { return nil }
                return ["kind": "tool_call_ref", "tool_call_id": id]
            }
            json["live_message"] = ["content": content]
        }
        if let messageID { json["pending_user_message"] = ["message_id": messageID, "blocks": []] }
        if pending {
            json["pending_permission"] = ["request_id": "permission-1", "tool_call": [:], "options": []]
            json["pending_question"] = ["question_id": "question-1", "questions": []]
        }
        return try decode(json)
    }
    static func feedback(id: String, text: String, status: String = "pending") -> [String: Any] {
        ["id": id, "text": text, "status": status]
    }
    static func event(_ type: String, fields: [String: Any] = [:], seq: UInt64 = 13) throws -> EventStream.Frame {
        var json = fields
        json["type"] = type; json["connection_id"] = "connection-42"; json["seq"] = seq
        let envelope: EventEnvelope = try decode(json)
        return .event(envelope)
    }
    static func decode<T: Decodable>(_ json: [String: Any]) throws -> T {
        try CodegJSON.decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor
final class RecoveryHarness {
    let server: RecoveryServer
    let host = "\(UUID().uuidString.lowercased()).session-recovery.invalid"
    let session: URLSession
    var streams: [RecoveryEventStream] = []
    var nextSnapshot: LiveSessionSnapshot
    var nextDeliversSnapshot = true
    var model: SessionDetailViewModel!
    init(newSession: Bool = false, agentType: AgentType = .claudeCode) throws {
        server = RecoveryServer(agentType: agentType)
        nextSnapshot = try RecoveryFixtures.snapshot()
        RecoveryURLProtocol.register(server, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryURLProtocol.self]
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
        session = URLSession(configuration: config)
        let client = CodegClient(baseURL: URL(string: "https://\(host)")!, token: "test",
                                 session: session, readSession: session)
        let factory: () -> any SessionEventStream = { [unowned self] in
            let stream = RecoveryEventStream(snapshot: self.nextSnapshot, deliversSnapshot: self.nextDeliversSnapshot)
            self.streams.append(stream); return stream
        }
        if newSession {
            model = SessionDetailViewModel(client: client,
                                          newSession: NewSessionRequest(preselectedFolderID: 7),
                                          eventStreamFactory: factory)
        } else {
            model = SessionDetailViewModel(client: client, conversationID: 42, eventStreamFactory: factory)
        }
    }
    func close() {
        model.teardown(); session.invalidateAndCancel(); RecoveryURLProtocol.remove(host: host)
    }
    var persistedText: String { Self.text(model.turns) }
    var liveText: String {
        guard let live = model.liveTurn else { return "" }
        return Self.text([live.snapshotAsMessageTurn()])
    }
    static func text(_ turns: [MessageTurn]) -> String {
        turns.flatMap(\.blocks).compactMap { block -> String? in
            if case .text(let text) = block { return text }; return nil
        }.joined(separator: "\n")
    }
}
