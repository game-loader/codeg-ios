import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class BoundHTTPFixture: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var held: (() -> Void)?
    nonisolated(unsafe) static var requested: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".bound-http.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        Self.lock.lock()
        Self.requested.append(host)
        let deliver: () -> Void = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"folder_id\":1,\"host\":\"\(host)\"}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if host == "a.bound-http.invalid" { Self.held = deliver; Self.lock.unlock() }
        else { Self.lock.unlock(); deliver() }
    }
    override func stopLoading() {}
    static func hasHeldResponse() -> Bool { lock.lock(); defer { lock.unlock() }; return held != nil }
    static func release() {
        lock.lock(); let delivery = held; held = nil; lock.unlock(); delivery?()
    }
    static func hosts() -> [String] { lock.lock(); defer { lock.unlock() }; return requested }
}

@main struct BoundHTTPChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let a = ServerBindingLifetime(), b = ServerBindingLifetime()
        let requestA = URLRequest(url: URL(string: "https://a.bound-http.invalid/api/get_folder")!)
        let requestB = URLRequest(url: URL(string: "https://b.bound-http.invalid/api/get_folder")!)
        let pendingA = Task { try await ServerBoundHTTP.perform(requestA, session: session, lifetime: a) }
        for _ in 0..<100 where !BoundHTTPFixture.hasHeldResponse() {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(BoundHTTPFixture.hasHeldResponse(), "A must actually await its own response")
        let (bodyB, _) = try await ServerBoundHTTP.perform(requestB, session: session, lifetime: b)
        precondition(String(decoding: bodyB, as: UTF8.self).contains("b.bound-http.invalid"))
        a.invalidate()
        BoundHTTPFixture.release()
        do { _ = try await pendingA.value; fatalError("retired A returned stale data") }
        catch is CancellationError {}
        let count = BoundHTTPFixture.hosts().count
        do { _ = try await ServerBoundHTTP.perform(requestA, session: session, lifetime: a); fatalError("retired A sent a new request") }
        catch is CancellationError {}
        precondition(BoundHTTPFixture.hosts().count == count)
        _ = try await ServerBoundHTTP.perform(requestB, session: session, lifetime: b)
        precondition(BoundHTTPFixture.hosts().filter { $0 == "b.bound-http.invalid" }.count == 2)
        print("Fixed HTTP A/B routing, delayed response retirement and independent B: PASS (5 invariants)")
    }
}
