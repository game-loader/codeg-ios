import Foundation

/// Pure reconnect sequencing. Its ticket fences HTTP results independently of
/// terminal UUID, PTY generation, and the retained client's binding lifetime.
struct TerminalSnapshotRecovery {
    enum Failure: Equatable, Sendable {
        case missing, generationChanged, sequenceRegressed, bufferOverflow, invalidSnapshot
        case request(String)

        var message: String {
            switch self {
            case .missing: return "Terminal is no longer available. Restart to create a new process."
            case .generationChanged: return "Terminal process changed. Restart to create a new process."
            case .sequenceRegressed: return "Terminal snapshot cursor moved backwards. Restart to recover."
            case .bufferOverflow: return "Terminal recovery buffer exceeded its limit. Restart to recover."
            case .invalidSnapshot: return "Terminal snapshot exceeded its output or dimension limits. Restart to recover."
            case .request(let message): return "Terminal recovery failed: \(message)"
            }
        }
    }

    enum State: Equatable, Sendable {
        case streaming, recovering, legacy, exited, unavailable(Failure), retired
    }

    enum Effect: Equatable, Sendable {
        case rebuild(TerminalSnapshot)
        case output(String)
        case exited(UInt32?)
        case unavailable(Failure)
    }

    static let maximumSnapshotBytes = 1024 * 1024
    private(set) var state: State = .streaming
    private(set) var generation: String?
    private(set) var snapshotWatermark: UInt64 = 0
    private var watermarkGeneration: String?
    private var ticket: UInt64 = 0
    private var buffered: [TerminalFrame] = []
    private var bufferedBytes = 0
    private let maximumBufferedBytes: Int
    private let maximumBufferedFrames: Int
    let terminalID: String

    init(terminalID: String, maximumBufferedBytes: Int = 1024 * 1024,
         maximumBufferedFrames: Int = 4096) {
        self.terminalID = terminalID
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumBufferedFrames = maximumBufferedFrames
    }

    mutating func beginReconnect() -> UInt64 {
        switch state {
        case .retired, .exited, .unavailable: return ticket
        default: break
        }
        ticket &+= 1
        state = .recovering
        // Preserve unread chunks if a second transport gap supersedes an HTTP
        // request. The next snapshot can cover them; a legacy fallback cannot.
        return ticket
    }

    mutating func cancelRequest() {
        ticket &+= 1
    }

    mutating func retire() {
        cancelRequest()
        clearBuffer()
        state = .retired
    }

    func accepts(_ request: UInt64) -> Bool { request == ticket && state == .recovering }

    mutating func receive(_ frame: TerminalFrame) -> [Effect] {
        switch frame {
        case .output(let id, _, _, let g), .exit(let id, _, let g):
            guard id == terminalID, matchesGeneration(g) else { return [] }
        default: return []
        }
        switch state {
        case .recovering:
            let bytes: Int
            if case .output(_, let text, _, _) = frame { bytes = text.utf8.count } else { bytes = 0 }
            guard bytes <= maximumBufferedBytes - bufferedBytes,
                  buffered.count < maximumBufferedFrames else { return fail(.bufferOverflow) }
            buffered.append(frame)
            bufferedBytes += bytes
            return []
        case .streaming, .legacy:
            return deliver(frame)
        case .exited, .unavailable, .retired:
            return []
        }
    }

    mutating func resolve(_ snapshot: TerminalSnapshot, request: UInt64) -> [Effect] {
        guard accepts(request) else { return [] }
        guard snapshot.exists else { return fail(.missing) }
        guard matchesGeneration(snapshot.generation) else { return fail(.generationChanged) }
        guard snapshot.data.utf8.count <= Self.maximumSnapshotBytes,
              validDimensions(snapshot) else { return fail(.invalidSnapshot) }
        if watermarkGeneration == snapshot.generation, snapshot.seq < snapshotWatermark {
            return fail(.sequenceRegressed)
        }
        generation = snapshot.generation ?? generation
        watermarkGeneration = snapshot.generation
        snapshotWatermark = snapshot.seq
        state = .streaming
        var effects: [Effect] = [.rebuild(snapshot)]
        let pending = buffered
        clearBuffer()
        // Exit seq is ALWAYS zero. Replay all newer output before reporting an
        // exit, even when that exit was already retained by the snapshot.
        for frame in pending {
            if case .output = frame { effects += deliver(frame) }
        }
        let exit = pending.contains { frame in
            if case .exit(_, _, let g) = frame { return matchesGeneration(g) }
            return false
        }
        if !snapshot.alive || exit {
            state = .exited
            effects.append(.exited(snapshot.exitCode))
        }
        return effects
    }

    mutating func unsupported(request: UInt64) -> [Effect] {
        guard accepts(request) else { return [] }
        state = .legacy
        let pending = buffered
        clearBuffer()
        return pending.flatMap { deliver($0) }
    }

    mutating func failed(_ message: String, request: UInt64) -> [Effect] {
        guard accepts(request) else { return [] }
        return fail(.request(message))
    }

    private func matchesGeneration(_ incoming: String?) -> Bool {
        generation == nil || incoming == nil || incoming == generation
    }

    private mutating func deliver(_ frame: TerminalFrame) -> [Effect] {
        guard state == .streaming || state == .legacy else { return [] }
        switch frame {
        case .output(_, let text, let seq, let g):
            guard matchesGeneration(g) else { return [] }
            generation = generation ?? g
            // Missing/zero cursors and missing generations retain the legacy
            // path. Only comparable snapshot-covered output may be discarded.
            if let seq, seq > 0, g == watermarkGeneration, seq <= snapshotWatermark { return [] }
            return [.output(text)]
        case .exit(_, _, let g):
            guard matchesGeneration(g) else { return [] }
            generation = generation ?? g
            state = .exited
            return [.exited(nil)]
        default: return []
        }
    }

    private func validDimensions(_ snapshot: TerminalSnapshot) -> Bool {
        switch (snapshot.cols, snapshot.rows) {
        case (nil, nil): return true
        case let (cols?, rows?):
            return (1...4096).contains(cols) && (1...4096).contains(rows) && cols * rows <= 1_000_000
        default: return false
        }
    }

    private mutating func clearBuffer() { buffered.removeAll(keepingCapacity: false); bufferedBytes = 0 }

    private mutating func fail(_ reason: Failure) -> [Effect] {
        clearBuffer()
        state = .unavailable(reason)
        return [.unavailable(reason)]
    }
}
