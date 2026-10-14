import Foundation

/// `terminal_snapshot`: `data` is raw UTF-8 PTY output, including escapes, not
/// base64. `alive` describes the process; `exists` also includes retained exits.
struct TerminalSnapshot: Decodable, Equatable, Sendable {
    let exists: Bool
    let alive: Bool
    let data: String
    let seq: UInt64
    let generation: String?
    let exitCode: UInt32?
    let cols: Int?
    let rows: Int?

    init(exists: Bool, alive: Bool, data: String, seq: UInt64 = 0,
         generation: String? = nil, exitCode: UInt32? = nil,
         cols: Int? = nil, rows: Int? = nil) {
        self.exists = exists; self.alive = alive; self.data = data
        self.seq = seq; self.generation = generation; self.exitCode = exitCode
        self.cols = cols; self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case exists, alive, data, seq, generation, exitCode, cols, rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alive = try c.decode(Bool.self, forKey: .alive)
        data = try c.decode(String.self, forKey: .data)
        // Earlier servers had only alive/data/seq. Their missing terminal was
        // alive:false with empty data. Do not treat malformed objects as missing.
        exists = try c.decodeIfPresent(Bool.self, forKey: .exists) ?? (alive || !data.isEmpty)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        generation = try c.decodeIfPresent(String.self, forKey: .generation)
        exitCode = try c.decodeIfPresent(UInt32.self, forKey: .exitCode)
        cols = try c.decodeIfPresent(Int.self, forKey: .cols)
        rows = try c.decodeIfPresent(Int.self, forKey: .rows)
    }
}

/// Foundation-only wire boundary shared by the real socket and recovery tests.
enum TerminalFrame: Equatable, Sendable {
    case ready
    case output(id: String, data: String, seq: UInt64? = nil, generation: String? = nil)
    case exit(id: String, seq: UInt64? = nil, generation: String? = nil)
    case closed(reason: String?)

    static func decode(_ data: Data) -> TerminalFrame? {
        struct Envelope: Decodable {
            let channel: String
            let payload: Payload?
        }
        struct Payload: Decodable {
            let terminal_id: String?
            let data: String?
            let seq: UInt64?
            let generation: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        if envelope.channel == "__ready__" { return .ready }
        let output = "terminal://output/", exit = "terminal://exit/"
        let isOutput = envelope.channel.hasPrefix(output)
        guard isOutput || envelope.channel.hasPrefix(exit) else { return nil }
        let id = String(envelope.channel.dropFirst(isOutput ? output.count : exit.count))
        guard !id.isEmpty, envelope.payload?.terminal_id == nil || envelope.payload?.terminal_id == id else {
            return nil
        }
        let p = envelope.payload
        if isOutput {
            guard let text = p?.data, !text.isEmpty else { return nil }
            return .output(id: id, data: text, seq: p?.seq, generation: p?.generation)
        }
        return .exit(id: id, seq: p?.seq, generation: p?.generation)
    }
}
