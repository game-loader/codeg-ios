import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Codeg

@MainActor
final class WorktreeWireTests: XCTestCase {
    func testCompleteInventoryPreservesDetachedBareLockedAndPrunableFlags() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.setInventory([
            WorktreeTestServer.entry("/repo", branch: "main", main: true),
            WorktreeTestServer.entry("/detached", branch: nil, detached: true, locked: "", prunable: "missing"),
            WorktreeTestServer.entry("/bare", branch: nil, bare: true, head: nil),
            WorktreeTestServer.entry("/linked", locked: "maintenance", prunable: "")
        ])
        let inventory = try await fixture.client.gitWorktrees(path: "/repo")
        XCTAssertEqual(inventory.count, 4)
        XCTAssertTrue(inventory[0].isMain)
        XCTAssertEqual(inventory[0].rootPath, "/repo")
        XCTAssertNil(inventory[0].locked)
        XCTAssertFalse(inventory[0].isLocked)
        XCTAssertTrue(inventory[1].detached)
        XCTAssertNil(inventory[1].branch)
        XCTAssertEqual(inventory[1].locked, "")
        XCTAssertTrue(inventory[1].isLocked)
        XCTAssertEqual(inventory[1].prunable, "missing")
        XCTAssertTrue(inventory[2].bare)
        XCTAssertNil(inventory[2].head)
        XCTAssertEqual(inventory[3].locked, "maintenance")
        XCTAssertTrue(inventory[3].isPrunable)
        XCTAssertEqual(inventory[3].prunable, "")
        XCTAssertEqual(Set(fixture.server.bodies("git_list_worktrees")[0].keys), ["path"])

        let older = Data(#"{"path":"/repo","head":null,"branch":null,"detached":true,"bare":false,"is_main":true}"#.utf8)
        let decoded = try CodegJSON.decoder.decode(GitWorktreeInfo.self, from: older)
        XCTAssertNil(decoded.rootPath)
        XCTAssertNil(decoded.locked)
        XCTAssertNil(decoded.prunable)
    }

    func testAddUsesCamelCaseBaseAndKeepsLegacyCallersAndBodies() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        try await fixture.client.gitWorktreeAdd(path: "/repo", branchName: "feature/base", worktreePath: "/new", base: "origin/main")
        try await fixture.client.gitWorktreeAdd(path: "/repo", branchName: "legacy", worktreePath: "/legacy")
        let bodies = fixture.server.bodies("git_worktree_add")
        XCTAssertEqual(Set(bodies[0].keys), ["path", "branchName", "worktreePath", "base"])
        XCTAssertEqual(bodies[0]["branchName"] as? String, "feature/base")
        XCTAssertEqual(bodies[0]["worktreePath"] as? String, "/new")
        XCTAssertEqual(bodies[0]["base"] as? String, "origin/main")
        XCTAssertEqual(Set(bodies[1].keys), ["path", "branchName", "worktreePath"])
        let oldBody = GitWorktreeAddBody(path: "/repo", branchName: "legacy", worktreePath: "/legacy")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CodegJSON.encoder.encode(oldBody)) as? [String: Any])
        XCTAssertNil(object["base"])
    }

    func testRemovalConvenienceResolvesSourceOnItsHostAndDecodesReconciliation() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        let removed = try await fixture.client.gitWorktreeRemoveByPath(path: "/repo", worktreePath: "/linked", deleteBranch: true)
        XCTAssertEqual(removed, GitWorktreeRemoval(worktreePath: "/linked", branchDeleted: true, folderId: 8, reparented: 2))
        let body = try XCTUnwrap(fixture.server.bodies("git_remove_worktree_path").first)
        XCTAssertEqual(Set(body.keys), ["path", "worktreePath", "sourceFolderId", "deleteBranch", "force"])
        XCTAssertEqual(body["sourceFolderId"] as? Int, 7)
        XCTAssertEqual(body["deleteBranch"] as? Bool, true)
        XCTAssertEqual(body["force"] as? Bool, false)
        XCTAssertEqual(fixture.server.count("list_all_folder_details"), 1)
        let retry = try CodegJSON.decoder.decode(GitWorktreeRemoval.self, from: Data(
            #"{"worktree_path":null,"branch_deleted":false,"folder_id":null,"reparented":0}"#.utf8))
        XCTAssertNil(retry.worktreePath)
        XCTAssertNil(retry.folderId)
        XCTAssertFalse(retry.branchDeleted)
    }

    func testExplicitSourceRemovalDefaultsAndBranchCleanupUseExactBodies() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        _ = try await fixture.client.gitWorktreeRemoveByPath(path: "/repo", worktreePath: "/linked", sourceFolderId: 7)
        let body = try XCTUnwrap(fixture.server.bodies("git_remove_worktree_path").first)
        XCTAssertEqual(body["deleteBranch"] as? Bool, false)
        XCTAssertEqual(body["force"] as? Bool, false)
        XCTAssertEqual(fixture.server.count("list_all_folder_details"), 0)
        let result = try await fixture.client.gitWorktreeDeleteBranch(path: "/repo", branchName: "topic", force: true)
        XCTAssertEqual(result, "Deleted branch topic")
        let cleanup = try XCTUnwrap(fixture.server.bodies("git_delete_branch").first)
        XCTAssertEqual(Set(cleanup.keys), ["path", "branchName", "force"])
        XCTAssertEqual(cleanup["branchName"] as? String, "topic")
        XCTAssertEqual(cleanup["force"] as? Bool, true)
    }

    func testMissingInventoryRouteRequiresUpgradeAndChatAndFilesRemainUsable() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.enqueue("git_list_worktrees", .failure(status: 404, code: nil, message: "Not Found"))
        do {
            _ = try await fixture.client.gitWorktrees(path: "/repo")
            XCTFail("Missing endpoint must show an upgrade message")
        } catch WorktreeAPIError.upgradeRequired { }
        catch { XCTFail("Unexpected error: \(error)") }
        let conversations = try await fixture.client.listConversations()
        XCTAssertTrue(conversations.isEmpty)
        let file = try await fixture.client.readFilePreview(rootPath: "/repo", path: "README.md")
        XCTAssertEqual(file.content, "Fixture file")
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testTypedMissingCheckoutIsNotMistakenForUnsupportedEndpoint() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.enqueue("git_remove_worktree_path", .failure(status: 404, code: "not_found", message: "Checkout missing"))
        do {
            _ = try await fixture.client.gitWorktreeRemoveByPath(path: "/repo", worktreePath: "/linked", sourceFolderId: 7)
            XCTFail("A missing checkout should fail")
        } catch APIError.server(let status, let code, _, _) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "not_found")
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}

// Standalone fixtures shared by the two worktree suites. They do not depend on
// session recovery support or global URLProtocol installation. All three
// sessions on each client are explicitly injected and scoped to a unique host.
@MainActor
final class WorktreeTestFixture {
    let host = "\(UUID().uuidString.lowercased()).worktree-tests.invalid"
    let server = WorktreeTestServer()
    let session: URLSession
    let client: CodegClient
    let folder: FolderDetail

    init() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorktreeTestURLProtocol.self]
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)
        client = CodegClient(baseURL: URL(string: "https://\(host)")!, token: "fixture-\(host)",
                             session: session, readSession: session, probeSession: session)
        folder = try CodegJSON.decoder.decode(FolderDetail.self, from: WorktreeTestReply.json(WorktreeTestServer.folder("/repo", id: 7)))
        WorktreeTestURLProtocol.register(server, host: host)
    }

    func close() {
        session.invalidateAndCancel()
        WorktreeTestURLProtocol.remove(host: host)
    }
}

struct WorktreeTestReply {
    var status = 200
    var data: Data
    var gate: WorktreeTestGate?
    var error: URLError?
    var removedPath: String?

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    static func failure(status: Int = 500, code: String? = "external_command_failed", message: String = "Git failed",
                        removedPath: String? = nil) -> WorktreeTestReply {
        WorktreeTestReply(status: status, data: try! json(["code": code as Any? ?? NSNull(), "message": message]),
                          removedPath: removedPath)
    }
}

final class WorktreeTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivery: (() -> Void)?
    private var released = false
    private var received = false
    var hasRequest: Bool { lock.lock(); defer { lock.unlock() }; return received }

    func hold(_ delivery: @escaping () -> Void) {
        lock.lock()
        received = true
        if released { lock.unlock(); delivery() }
        else { self.delivery = delivery; lock.unlock() }
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

final class WorktreeTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var inventory = [entry("/repo", branch: "main", main: true), entry("/linked")]
    private var folders = [folder("/repo", id: 7)]
    private var replies: [String: [WorktreeTestReply]] = [:]
    private var requests: [(String, [String: Any])] = []
    private var unexpectedRequests: [String] = []

    static func entry(_ path: String, branch: String? = "topic", main: Bool = false, detached: Bool = false,
                      bare: Bool = false, head: String? = "abcdef", locked: String? = nil, prunable: String? = nil) -> [String: Any] {
        ["path": path, "head": head as Any? ?? NSNull(), "branch": branch as Any? ?? NSNull(),
         "is_main": main, "detached": detached, "bare": bare, "locked": locked as Any? ?? NSNull(),
         "prunable": prunable as Any? ?? NSNull(), "root_path": "/repo"]
    }

    static func folder(_ path: String, id: Int = 8, parent: Int? = nil) -> [String: Any] {
        ["id": id, "name": "fixture", "path": path, "git_branch": "topic", "last_opened_at": "2026-10-12T00:00:00Z",
         "sort_order": 0, "color": "", "kind": "regular", "parent_id": parent as Any? ?? NSNull()]
    }

    func enqueue(_ route: String, _ reply: WorktreeTestReply) {
        lock.lock(); defer { lock.unlock() }
        replies[route, default: []].append(reply)
    }

    func setInventory(_ entries: [[String: Any]]) { lock.lock(); inventory = entries; lock.unlock() }
    func setFolders(_ entries: [[String: Any]]) { lock.lock(); folders = entries; lock.unlock() }
    func count(_ route: String) -> Int { bodies(route).count }
    func bodies(_ route: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.0 == route }.map { $0.1 }
    }
    var unexpected: [String] { lock.lock(); defer { lock.unlock() }; return unexpectedRequests }

    func respond(to request: URLRequest) throws -> WorktreeTestReply {
        let route = request.url?.lastPathComponent ?? ""
        let body = try Self.body(request)
        lock.lock(); defer { lock.unlock() }
        requests.append((route, body))
        guard request.httpMethod == "POST", request.url?.path == "/api/\(route)",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-\(request.url!.host!)",
              request.value(forHTTPHeaderField: "Content-Type") == "application/json" else {
            unexpectedRequests.append("Invalid request: \(route)")
            throw URLError(.badServerResponse)
        }
        if var queue = replies[route], !queue.isEmpty {
            let reply = queue.removeFirst()
            replies[route] = queue
            if let path = reply.removedPath { inventory.removeAll { $0["path"] as? String == path } }
            return reply
        }
        let value: Any
        switch route {
        case "git_list_worktrees": value = inventory
        case "list_all_folder_details": value = folders
        case "git_worktree_add":
            guard let path = body["worktreePath"] as? String, let branch = body["branchName"] as? String else {
                throw URLError(.badServerResponse)
            }
            inventory.append(Self.entry(path, branch: branch))
            value = NSNull()
        case "open_worktree_folder", "open_folder":
            guard let path = body["path"] as? String, inventory.contains(where: { $0["path"] as? String == path }) else {
                throw URLError(.fileDoesNotExist)
            }
            let id = path == "/repo" ? 7 : (path == "/linked" ? 8 : 9)
            let folder = folders.first { $0["path"] as? String == path } ?? Self.folder(path, id: id, parent: body["sourceFolderId"] as? Int)
            folders.removeAll { $0["path"] as? String == path }
            folders.append(folder)
            value = folder
        case "git_remove_worktree_path":
            guard let path = body["worktreePath"] as? String else { throw URLError(.badServerResponse) }
            inventory.removeAll { $0["path"] as? String == path }
            folders.removeAll { $0["path"] as? String == path }
            value = ["worktree_path": path, "branch_deleted": body["deleteBranch"] as? Bool ?? false,
                     "folder_id": 8, "reparented": 2]
        case "git_delete_branch": value = "Deleted branch \(body["branchName"] as? String ?? "")"
        case "list_all_conversations": value = [Any]()
        case "read_file_preview": value = ["path": body["path"] as? String ?? "", "content": "Fixture file"]
        default:
            unexpectedRequests.append(route)
            throw URLError(.unsupportedURL)
        }
        return WorktreeTestReply(data: try WorktreeTestReply.json(value))
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
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
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return body
    }
}

final class WorktreeTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var servers: [String: WorktreeTestServer] = [:]
    private let lock = NSLock()
    private var stopped = false

    static func register(_ server: WorktreeTestServer, host: String) {
        registryLock.lock(); servers[host] = server; registryLock.unlock()
    }
    static func remove(host: String) { registryLock.lock(); servers.removeValue(forKey: host); registryLock.unlock() }
    // Trap every request on injected sessions, including any unexpected host.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }

    override func startLoading() {
        Self.registryLock.lock()
        let server = Self.servers[request.url?.host ?? ""]
        Self.registryLock.unlock()
        do {
            guard request.url?.host?.hasSuffix(".worktree-tests.invalid") == true, let server else {
                throw URLError(.resourceUnavailable)
            }
            let reply = try server.respond(to: request)
            let delivery = { [weak self] in self?.deliver(reply) }
            if let gate = reply.gate { gate.hold { delivery() } }
            else { delivery() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func deliver(_ reply: WorktreeTestReply) {
        lock.lock(); let stopped = self.stopped; lock.unlock()
        guard !stopped else { return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
