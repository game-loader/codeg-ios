import Foundation

/// Injectable transport boundary; the session still owns the captured client.
protocol TerminalSocketConnection: Sendable {
    var frames: AsyncStream<TerminalFrame> { get }
    func start()
    func close()
}

/// A live WebSocket to `/ws/events` that surfaces **only** the terminal firehose
/// frames. PTY output/exit are broadcast by the server as legacy
/// `{channel, payload}` frames (NOT the attach protocol that ``EventStream``
/// speaks), e.g. `{channel:"terminal://output/<id>", payload:{terminal_id,data}}`.
/// ``EventStream`` deliberately drops those, so the terminal feature gets its own
/// thin socket here — keeping the streaming-critical session stream untouched.
///
/// The broadcaster only sends while at least one receiver is subscribed, so a
/// consumer must `start()` and await `.ready` (the server's `__ready__` frame)
/// **before** calling `terminal_spawn`, or the first output is lost.
///
/// Reuses ``EventStream``'s connection plumbing (token subprotocol, websocket
/// URL, the no-idle-timeout `streamSession`, and a keepalive ping that detects a
/// genuinely dead socket).
final class TerminalSocket: TerminalSocketConnection, @unchecked Sendable {
    typealias Frame = TerminalFrame

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let url: URL
    private let token: String
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var isClosed = false

    private static let pingInterval: TimeInterval = 20

    init(baseURL: URL, token: String, session: URLSession = EventStream.streamSession) {
        self.token = token
        self.session = session
        self.url = EventStream.websocketURL(from: baseURL)
        var captured: AsyncStream<Frame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingOldest(4096)) { captured = $0 }
        self.continuation = captured
    }

    func start() {
        let protocols = ["codeg-events", "codeg-token.\(EventStream.base64URLNoPad(token))"]
        let newTask = session.webSocketTask(with: url, protocols: protocols)
        lock.lock()
        guard !isClosed, task == nil else { lock.unlock(); return }
        task = newTask
        lock.unlock()
        newTask.resume()
        receiveLoop()
        scheduleNextPing()
    }

    func close() {
        lock.lock()
        let already = isClosed
        isClosed = true
        let t = task
        lock.unlock()
        guard !already else { return }
        t?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    // MARK: - Receive

    private func receiveLoop() {
        lock.lock(); let t = task; lock.unlock()
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(reason: error.localizedDescription)
            case .success(let message):
                self.handle(message)
                self.lock.lock(); let closed = self.isClosed; self.lock.unlock()
                if !closed { self.receiveLoop() }
            }
        }
    }

    private func finish(reason: String?) {
        lock.lock()
        let already = isClosed
        isClosed = true
        let t = task
        lock.unlock()
        guard !already else { return }
        t?.cancel(with: .goingAway, reason: nil)
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let frame = Frame.decode(data) else { return }
        if case .dropped = continuation.yield(frame) {
            // Force a fresh snapshot instead of silently losing sequenced output.
            finish(reason: "Terminal socket buffer exceeded its limit")
        }
    }

    // MARK: - Keepalive

    private func scheduleNextPing() {
        lock.lock(); let closed = isClosed; lock.unlock()
        guard !closed else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.pingInterval) { [weak self] in
            self?.sendKeepalivePing()
        }
    }

    private func sendKeepalivePing() {
        lock.lock(); let closed = isClosed; let t = task; lock.unlock()
        guard !closed, let t else { return }
        t.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(reason: error.localizedDescription)
            } else {
                self.scheduleNextPing()
            }
        }
    }
}
