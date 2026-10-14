import Foundation
import SwiftUI
import SwiftTerm

/// Drives one server-side PTY for a folder: owns the native ``SwiftTerm/TerminalView``
/// (the keep-alive anchor — retained for the model's life so flipping between the
/// detail's Files/Changes/Commits/Terminal tabs preserves scrollback and the
/// running process), spawns the PTY in the folder's directory, pumps input/resize
/// to the server, and feeds output from the ``TerminalSocket`` firehose back into
/// the view.
///
/// Lifecycle mirrors the web client (`terminal-view.tsx`): open the socket and
/// await `__ready__` **before** `terminal_spawn` so no early output is dropped;
/// kill the PTY on teardown (the server does not reap it when the socket closes).
/// Retained by `ProjectWorkspaceCache` for bound server generations; unbound
/// clients keep the original screen-local lifetime.
///
/// Teardown-critical handles (socket, write queue, tasks, terminal id) live in a
/// `Sendable` ``TerminalRuntime`` box held as a `let`, so the non-isolated
/// `deinit` can release them and kill the PTY without touching MainActor state.
@MainActor
@Observable
final class TerminalSession {
    enum Phase: Equatable {
        case idle          // not started yet (lazy — first appearance of the tab)
        case connecting    // socket opening / awaiting ready / spawning
        case running       // PTY live
        case exited        // process ended (output still readable)
        case failed(message: String)
    }

    /// The native terminal emulator view. Retained here (not recreated by the
    /// SwiftUI wrapper) so it survives tab switches.
    let view: SwiftTerm.TerminalView

    private(set) var phase: Phase = .idle
    /// Legacy means the socket is live but the server cannot recover a gap.
    private(set) var recoveryState: TerminalSnapshotRecovery.State = .streaming

    private let client: CodegClient
    private let folderPath: String
    private let runtime: TerminalRuntime
    private let delegate: TerminalIODelegate
    private let socketFactory: @Sendable (CodegClient) -> any TerminalSocketConnection
    private var recovery: TerminalSnapshotRecovery?
    private var socketEpoch = UUID()
    private var hasSpawned = false
    private var snapshotsUnsupported = false
    private var isRebuilding = false

    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var readyToken = 0   // invalidates a superseded generation's ready timeout
    private var didReady = false
    private var reconnectAttempts = 0
    private var desiredCols = 0   // latest size SwiftTerm reported
    private var desiredRows = 0
    private var sentCols = 0      // latest size acknowledged to the PTY
    private var sentRows = 0
    private var appliedDark: Bool?
    private var isRetired = false

    init(client: CodegClient, folder: FolderDetail,
         socketFactory: @escaping @Sendable (CodegClient) -> any TerminalSocketConnection = {
             TerminalSocket(baseURL: $0.baseURL, token: $0.token)
         }) {
        self.client = client
        self.folderPath = folder.path
        self.runtime = TerminalRuntime(client: client)
        self.socketFactory = socketFactory
        let term = SwiftTerm.TerminalView(
            frame: .zero,
            font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        self.view = term
        self.delegate = TerminalIODelegate()
        self.delegate.session = self
        term.terminalDelegate = delegate
        // Replace SwiftTerm's stock accessory bar (which shipped a no-op mouse-
        // reporting toggle and a confusing custom-keyboard swap where a dismiss
        // button is expected) with a clean, shell-focused one. See ``TerminalKeyBar``.
        term.inputAccessoryView = TerminalKeyBar(terminalView: term)
    }

    // MARK: - Start / restart

    /// Idempotent lazy start — called from the tab's `.task`.
    func start() {
        guard !isRetired, client.bindingLifetime?.isValid != false, phase == .idle else { return }
        phase = .connecting
        let id = UUID().uuidString
        runtime.setId(id)
        recovery = TerminalSnapshotRecovery(terminalID: id)
        recoveryState = .streaming
        runtime.setBootstrap(Task { [weak self] in await self?.bootstrap(id: id) })
    }

    /// Kill the current PTY and spawn a fresh one (the "Restart" action).
    func restart() {
        guard !isRetired, client.bindingLifetime?.isValid != false else { return }
        resumeReadyIfPending()
        recovery?.retire()
        socketEpoch = UUID()
        runtime.teardown(kill: true)
        view.feed(text: clearSequence)
        phase = .idle
        didReady = false
        hasSpawned = false
        reconnectAttempts = 0
        sentCols = 0
        sentRows = 0
        start()
    }

    /// Stop local terminal resources on permanent generation retirement, even
    /// when a disappearing view or in-flight bootstrap still retains the model.
    /// Keeps the existing best-effort teardown; a retired binding rejects its
    /// network cleanup. Never bypasses binding checks or cancels remote agents.
    func retire() {
        guard !isRetired else { return }
        isRetired = true
        resumeReadyIfPending()
        recovery?.retire()
        recoveryState = .retired
        socketEpoch = UUID()
        runtime.teardown(kill: true)
        runtime.setId(nil)
        phase = .exited
        view.resignFirstResponder()
    }

    /// Clear the visible screen + scrollback locally (does not disturb the shell).
    func clear() {
        view.feed(text: clearSequence)
    }

    func dismissKeyboard() {
        view.resignFirstResponder()
    }

    /// `restart()` can cancel an in-flight `bootstrap` and immediately start a new
    /// one with a fresh id. A stale bootstrap that resumes after an `await` must not
    /// touch the new generation's state — so every side effect is gated on
    /// `isCurrent(id)` (the runtime still owns this id) plus `!Task.isCancelled`,
    /// and any PTY the stale generation spawned is killed by its explicit local `id`.
    private func bootstrap(id: String) async {
        let shell = (try? await client.systemTerminalSettings())?.defaultShell
        guard !Task.isCancelled, isCurrent(id) else { return }
        openSocket(id: id)
        await awaitReady()
        guard !Task.isCancelled, isCurrent(id), phase == .connecting else { return }

        // The write queue needs the id; create it now that we have one.
        runtime.replaceWriteQueue(TerminalWriteQueue { [client] data in
            try? await client.terminalWrite(terminalId: id, data: data)
        })

        do {
            let spawnSocketEpoch = socketEpoch
            _ = try await client.terminalSpawn(workingDir: folderPath, shell: shell, terminalId: id)
            guard !Task.isCancelled, isCurrent(id) else {
                // A restart superseded us after the PTY was created — kill the orphan.
                try? await client.terminalKill(terminalId: id)
                return
            }
            hasSpawned = true
            if phase == .connecting { phase = .running }
            // A gap can occur while the spawn HTTP response is in flight. The
            // replacement socket may have become ready before we knew it existed.
            if socketEpoch != spawnSocketEpoch, didReady {
                beginSnapshotRecovery(id: id, epoch: socketEpoch)
            }
            // Push current view dimensions now the PTY exists — a `sizeChanged` that
            // fired before spawn would otherwise leave the PTY at its default size.
            scheduleResizeFlush()
        } catch {
            // Best-effort kill the explicit local id (not the mutable runtime id) in
            // case the server created the PTY but the response failed (e.g. timed out).
            // Done regardless of cancellation so a superseded spawn can't leak.
            try? await client.terminalKill(terminalId: id)
            guard !Task.isCancelled, isCurrent(id) else { return }   // superseded — restart owns cleanup now
            phase = .failed(message: error.localizedDescription)
            view.feed(text: "\r\n\u{1b}[31m[Failed to start terminal: \(error.localizedDescription)]\u{1b}[0m\r\n")
            runtime.replaceSocket(nil)
            runtime.replaceWriteQueue(nil)
        }
    }

    /// True while the runtime still owns `id` — i.e. no `restart()` has replaced it.
    private func isCurrent(_ id: String) -> Bool {
        !isRetired && client.bindingLifetime?.isValid != false && runtime.currentId() == id
    }

    // MARK: - Socket + output

    private func openSocket(id: String) {
        // Guard against a stale bootstrap/reconnect resurrecting a superseded id.
        guard isCurrent(id), phase == .running || phase == .connecting else { return }
        didReady = false
        socketEpoch = UUID()
        let epoch = socketEpoch
        runtime.setRecovery(nil)
        if hasSpawned {
            _ = recovery?.beginReconnect()
            recoveryState = recovery?.state ?? .recovering
        }
        let socket = socketFactory(client)
        runtime.replaceSocket(socket)
        socket.start()
        // Per-iteration `weak self`: the loop must NOT hold `self` across `await`.
        // A running `self.consume()` would retain the session for the socket's whole
        // lifetime, so `deinit` (which kills the PTY) would never fire while a shell
        // is alive — popping the folder detail would orphan the WebSocket + PTY.
        // Here `self` is only held for each frame's handling, then released before
        // the next `await`, so dropping the owning `@State` deinits the session
        // promptly for unbound clients. Bound projects keep the session until
        // generation retirement explicitly closes the socket and ends this loop.
        runtime.setConsumer(Task { [weak self] in
            for await frame in socket.frames {
                guard let self else { break }
                if !self.handle(frame: frame, id: id, epoch: epoch) { return }
            }
            // Includes a bounded socket buffer finishing before it could enqueue
            // its closed frame. Epoch fencing prevents duplicate reconnects.
            guard let self, !Task.isCancelled, self.socketEpoch == epoch, self.isCurrent(id) else { return }
            self.handleSocketClosed(id: id)
        })
        runtime.setReadyTimeout(Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.socketEpoch == epoch,
                  self.isCurrent(id), self.hasSpawned, !self.didReady else { return }
            self.applyRecoveryEffects([.unavailable(.request("Terminal socket did not become ready"))])
        })
    }

    /// Handle one firehose frame on the MainActor. Returns `false` when the loop
    /// should stop (process exit / socket closed). `self` is held only for this call.
    private func handle(frame: TerminalSocket.Frame, id: String, epoch: UUID) -> Bool {
        // A `restart()` may have superseded this consumer's id. Stop the stale loop
        // before it can feed the shared view or mutate the new generation's state
        // (e.g. a buffered `.exit` for the old id flipping the new session to exited).
        guard !Task.isCancelled, isCurrent(id), socketEpoch == epoch else { return false }
        switch frame {
        case .ready:
            guard !didReady else { return true }
            didReady = true
            reconnectAttempts = 0
            resumeReadyIfPending()
            runtime.setReadyTimeout(nil)
            if hasSpawned { beginSnapshotRecovery(id: id, epoch: epoch) }
            return true
        case .output, .exit:
            let effects = recovery?.receive(frame) ?? []
            recoveryState = recovery?.state ?? recoveryState
            applyRecoveryEffects(effects)
            return phase == .running || phase == .connecting
        case .closed:
            handleSocketClosed(id: id)
            return false
        }
    }

    private func beginSnapshotRecovery(id: String, epoch: UUID) {
        guard isCurrent(id), socketEpoch == epoch, didReady,
              phase == .running || phase == .connecting else { return }
        let request = recovery?.beginReconnect() ?? 0
        recoveryState = recovery?.state ?? .recovering
        runtime.setResize(nil)
        if snapshotsUnsupported {
            let effects = recovery?.unsupported(request: request) ?? []
            recoveryState = recovery?.state ?? recoveryState
            applyRecoveryEffects(effects)
            scheduleResizeFlush()
            return
        }
        // Do not hold the session while awaiting HTTP, or teardown could never
        // release it. Both transport and post-await guards use this fixed client.
        let capturedClient = client
        runtime.setRecovery(Task { [weak self] in
            do {
                let snapshot = try await capturedClient.terminalSnapshot(terminalId: id)
                try capturedClient.checkBinding()
                guard let self, self.isCurrent(id), self.socketEpoch == epoch else { return }
                let effects = self.recovery?.resolve(snapshot, request: request) ?? []
                self.recoveryState = self.recovery?.state ?? self.recoveryState
                self.applyRecoveryEffects(effects)
            } catch {
                guard !Task.isCancelled, capturedClient.bindingLifetime?.isValid != false,
                      let self, self.isCurrent(id), self.socketEpoch == epoch else { return }
                let effects: [TerminalSnapshotRecovery.Effect]
                if error is TerminalSnapshotAPIError, self.recovery?.accepts(request) == true {
                    self.snapshotsUnsupported = true
                    effects = self.recovery?.unsupported(request: request) ?? []
                    self.view.feed(text: "\r\n\u{1b}[90m[Connected without snapshot recovery; output or exit during the gap may be missing]\u{1b}[0m\r\n")
                } else {
                    effects = self.recovery?.failed(error.localizedDescription, request: request) ?? []
                }
                self.recoveryState = self.recovery?.state ?? self.recoveryState
                self.applyRecoveryEffects(effects)
                if self.recoveryState == .legacy { self.scheduleResizeFlush() }
            }
        })
    }

    private func applyRecoveryEffects(_ effects: [TerminalSnapshotRecovery.Effect]) {
        let rebuilt = effects.contains { if case .rebuild = $0 { return true }; return false }
        for effect in effects {
            switch effect {
            case .rebuild(let snapshot):
                isRebuilding = true
                view.getTerminal().resetToInitialState()
                if let cols = snapshot.cols, let rows = snapshot.rows {
                    // Resize before feed; SwiftTerm's view resize performs a soft
                    // reset and reports sizeChanged. Suppress that HTTP callback.
                    view.resize(cols: cols, rows: rows)
                    sentCols = cols; sentRows = rows
                }
                view.feed(text: snapshot.data)
            case .output(let text):
                view.feed(text: text)
            case .exited(let code):
                handleProcessExited(code: code)
            case .unavailable(let reason):
                recovery?.retire()
                recoveryState = .unavailable(reason)
                phase = .failed(message: reason.message)
                view.feed(text: "\r\n\u{1b}[31m[\(reason.message)]\u{1b}[0m\r\n")
                runtime.setRecovery(nil)
                runtime.setReconnect(nil)
                runtime.setReadyTimeout(nil)
                runtime.setResize(nil)
                runtime.replaceSocket(nil)
                runtime.replaceWriteQueue(nil)
            }
        }
        if isRebuilding {
            // Reflow to the retained pane only after all replayed bytes. The
            // emulator resize preserves restored modes (view.resize soft-resets).
            if desiredCols > 0, desiredRows > 0 {
                view.getTerminal().resize(cols: desiredCols, rows: desiredRows)
            }
            isRebuilding = false
            view.setNeedsDisplay()
        }
        if rebuilt, phase == .running, recoveryState == .streaming || recoveryState == .legacy {
            scheduleResizeFlush()
        }
    }

    private func handleProcessExited(code: UInt32? = nil) {
        guard phase == .running || phase == .connecting else { return }
        phase = .exited
        let message = code.map { "Process exited (\($0))" } ?? "Process exited"
        view.feed(text: "\r\n\u{1b}[90m[\(message)]\u{1b}[0m\r\n")
        runtime.setRecovery(nil)
        runtime.setReconnect(nil)
        runtime.setReadyTimeout(nil)
        runtime.setResize(nil)
        runtime.replaceWriteQueue(nil)
        // The consumer loop has stopped; close the now-idle WebSocket so it doesn't
        // keep pinging/buffering frames with no reader. (Don't kill — the PTY is
        // already gone; `restart()` spawns a fresh id.)
        runtime.replaceSocket(nil)
    }

    /// A transport blip — the PTY survives server-side, so re-open the socket with
    /// backoff, then snapshot on readiness before releasing buffered events.
    private func handleSocketClosed(id: String) {
        guard phase == .running || phase == .connecting else { return }
        socketEpoch = UUID()
        didReady = false
        recovery?.cancelRequest()
        if hasSpawned {
            _ = recovery?.beginReconnect()
            recoveryState = .recovering
        }
        runtime.setRecovery(nil)
        runtime.setReadyTimeout(nil)
        runtime.setResize(nil)
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 8.0)
        runtime.setReconnect(Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.openSocket(id: id)
        })
    }

    // MARK: - Ready gate

    private func awaitReady() async {
        if didReady { return }
        readyToken &+= 1
        let token = readyToken
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readyContinuation = cont
            // Bounded fallback: proceed even if `__ready__` never arrives (an older
            // server, a hung task) rather than hang the tab. Matches the web's 5s cap.
            // Token-gated so a timeout from a superseded generation can't resolve a
            // NEW generation's gate (which would let it spawn before its own `__ready__`).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.readyToken == token else { return }
                self.resumeReadyIfPending()
            }
        }
    }

    private func resumeReadyIfPending() {
        guard let cont = readyContinuation else { return }
        readyContinuation = nil
        cont.resume()
    }

    // MARK: - Input / resize (called by the delegate on the main thread)

    func handleInput(_ text: String) {
        guard !isRetired, client.bindingLifetime?.isValid != false, phase == .running,
              recoveryState == .streaming || recoveryState == .legacy, !isRebuilding,
              !text.isEmpty else { return }
        // Don't leak xterm focus in/out reports into the shell prompt (web parity).
        if text == "\u{1b}[I" || text == "\u{1b}[O" { return }
        runtime.enqueueWrite(text)
    }

    func handleResize(cols: Int, rows: Int) {
        guard !isRebuilding, cols > 0, rows > 0 else { return }
        desiredCols = cols
        desiredRows = rows
        scheduleResizeFlush()
    }

    /// Debounced resize push. Only sends once the PTY exists (`.running`), and is
    /// also called right after spawn so a `sizeChanged` that fired before the PTY
    /// was created still reaches it (otherwise the PTY stays at its default size).
    private func scheduleResizeFlush() {
        runtime.setResize(Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))   // debounce drag/rotation
            guard !Task.isCancelled, let self, self.phase == .running,
                  self.recoveryState == .streaming || self.recoveryState == .legacy,
                  self.desiredCols > 0, self.desiredRows > 0,
                  let id = self.runtime.currentId(),
                  self.isCurrent(id),
                  self.desiredCols != self.sentCols || self.desiredRows != self.sentRows
            else { return }
            let cols = self.desiredCols, rows = self.desiredRows
            do {
                try await self.client.terminalResize(terminalId: id, cols: cols, rows: rows)
                // Mark acknowledged only on success AND only if this is still the
                // current generation — otherwise a late resize for the OLD PTY could
                // mark the NEW PTY's geometry as sent and skip its initial resize.
                guard !Task.isCancelled, self.isCurrent(id) else { return }
                self.sentCols = cols
                self.sentRows = rows
            } catch {
                // keep sent* unchanged → retry on the next flush
            }
        })
    }

    // MARK: - Theming

    /// Apply the dark/light terminal palette. Cheap-guarded so it only re-installs
    /// (a full redraw) when the color scheme actually flips.
    func applyTheme(dark: Bool) {
        guard appliedDark != dark else { return }
        appliedDark = dark
        let palette = dark ? TerminalPalette.dark : TerminalPalette.light
        view.installColors(palette.ansi)
        view.nativeForegroundColor = palette.foreground
        view.nativeBackgroundColor = palette.background
    }

    func backgroundColor(dark: Bool) -> SwiftUI.Color {
        SwiftUI.Color(uiColor: dark ? TerminalPalette.dark.background : TerminalPalette.light.background)
    }

    deinit {
        // The server does not reap PTYs on socket close — kill explicitly so a
        // released session leaves no orphan shell. `runtime` is a `Sendable`
        // `let`, so the non-isolated deinit may touch it.
        runtime.teardown(kill: true)
    }

    private let clearSequence = "\u{1b}[3J\u{1b}[2J\u{1b}[H"
}

// MARK: - Runtime box (deinit-safe)

/// Holds the session's teardown-critical handles behind a lock so the
/// non-isolated `deinit` (and the MainActor methods) can both touch them safely.
/// All mutation happens on the MainActor in practice; `deinit` runs once at end
/// of life. `@unchecked Sendable` + the lock cover the formal requirement.
final class TerminalRuntime: @unchecked Sendable {
    let client: CodegClient
    private let lock = NSLock()
    private var terminalId: String?
    private var socket: (any TerminalSocketConnection)?
    private var writeQueue: TerminalWriteQueue?
    private var bootstrapTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?

    init(client: CodegClient) { self.client = client }

    func currentId() -> String? { lock.withLock { terminalId } }
    func setId(_ id: String?) { lock.withLock { terminalId = id } }

    func replaceSocket(_ s: (any TerminalSocketConnection)?) {
        let old = lock.withLock { () -> (any TerminalSocketConnection)? in let o = socket; socket = s; return o }
        old?.close()
    }

    func replaceWriteQueue(_ q: TerminalWriteQueue?) {
        let old = lock.withLock { () -> TerminalWriteQueue? in let o = writeQueue; writeQueue = q; return o }
        old?.finish()
    }

    func enqueueWrite(_ text: String) {
        lock.withLock { writeQueue }?.enqueue(text)
    }

    func setBootstrap(_ t: Task<Void, Never>?) {
        let old = lock.withLock { () -> Task<Void, Never>? in let o = bootstrapTask; bootstrapTask = t; return o }
        old?.cancel()
    }
    func setConsumer(_ t: Task<Void, Never>?) {
        let old = lock.withLock { () -> Task<Void, Never>? in let o = consumerTask; consumerTask = t; return o }
        old?.cancel()
    }
    func setReconnect(_ t: Task<Void, Never>?) {
        let old = lock.withLock { () -> Task<Void, Never>? in let o = reconnectTask; reconnectTask = t; return o }
        old?.cancel()
    }
    func setResize(_ t: Task<Void, Never>?) {
        let old = lock.withLock { () -> Task<Void, Never>? in let o = resizeTask; resizeTask = t; return o }
        old?.cancel()
    }
    func setRecovery(_ t: Task<Void, Never>?) {
        let old = lock.withLock { () -> Task<Void, Never>? in let o = recoveryTask; recoveryTask = t; return o }
        old?.cancel()
    }
    func setReadyTimeout(_ t: Task<Void, Never>?) {
        let old = lock.withLock { () -> Task<Void, Never>? in let o = readyTimeoutTask; readyTimeoutTask = t; return o }
        old?.cancel()
    }

    func teardown(kill: Bool) {
        let (s, q, b, c, r, z, h, w, id) = lock.withLock {
            let vals = (socket, writeQueue, bootstrapTask, consumerTask, reconnectTask, resizeTask, recoveryTask, readyTimeoutTask, terminalId)
            socket = nil; writeQueue = nil
            bootstrapTask = nil; consumerTask = nil; reconnectTask = nil; resizeTask = nil
            recoveryTask = nil; readyTimeoutTask = nil
            return vals
        }
        b?.cancel(); c?.cancel(); r?.cancel(); z?.cancel()
        h?.cancel(); w?.cancel()
        s?.close(); q?.finish()
        if kill, let id {
            let client = self.client
            Task.detached { try? await client.terminalKill(terminalId: id) }
        }
    }
}

// MARK: - Delegate forwarder

/// SwiftTerm's `TerminalViewDelegate` is non-isolated and its callbacks fire on
/// the main thread. This thin forwarder hops into the `@MainActor` session so all
/// state lives there, keeping the session free of `NSObject`/isolation juggling.
final class TerminalIODelegate: NSObject, TerminalViewDelegate {
    weak var session: TerminalSession?

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        let text = String(decoding: data, as: UTF8.self)
        MainActor.assumeIsolated { session?.handleInput(text) }
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { session?.handleResize(cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let str = String(bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

// MARK: - Ordered single-flight write queue

/// Sends terminal input to the PTY in exact FIFO order (one in-flight HTTP write
/// at a time), so a fast burst of keystrokes / a paste can't be reordered by
/// transport timing. Mirrors the web client's `createWriteQueue`.
final class TerminalWriteQueue: @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let task: Task<Void, Never>

    init(_ send: @escaping @Sendable (String) async -> Void) {
        let (stream, cont) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont
        self.task = Task { for await chunk in stream { await send(chunk) } }
    }

    func enqueue(_ text: String) { continuation.yield(text) }
    func finish() { continuation.finish(); task.cancel() }
}

// MARK: - Palette

/// Terminal color palettes, ported from the web client's `DARK_THEME` /
/// `LIGHT_THEME` (`terminal-view.tsx`). `ansi` is the 16-color base palette in
/// standard order (0–7 normal, 8–15 bright).
private struct TerminalPalette {
    let ansi: [SwiftTerm.Color]
    let foreground: UIColor
    let background: UIColor

    static let dark = TerminalPalette(
        ansi: [
            c(0x1a1a1a), c(0xf87171), c(0x4ade80), c(0xfacc15),
            c(0x60a5fa), c(0xc084fc), c(0x22d3ee), c(0xe0e0e0),
            c(0x737373), c(0xfca5a5), c(0x86efac), c(0xfde68a),
            c(0x93c5fd), c(0xd8b4fe), c(0x67e8f9), c(0xffffff),
        ],
        foreground: ui(0xe0e0e0),
        background: ui(0x1a1a1a)
    )

    static let light = TerminalPalette(
        ansi: [
            c(0x1a1a1a), c(0xdc2626), c(0x16a34a), c(0xca8a04),
            c(0x2563eb), c(0x9333ea), c(0x0891b2), c(0xe5e5e5),
            c(0xa3a3a3), c(0xef4444), c(0x22c55e), c(0xeab308),
            c(0x3b82f6), c(0xa855f7), c(0x06b6d4), c(0xffffff),
        ],
        foreground: ui(0x1a1a1a),
        background: ui(0xffffff)
    )

    /// 24-bit hex → SwiftTerm 16-bit-per-channel color (0xFF → 0xFFFF via ×257).
    private static func c(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xff) * 257,
            green: UInt16((hex >> 8) & 0xff) * 257,
            blue: UInt16(hex & 0xff) * 257
        )
    }

    private static func ui(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}
