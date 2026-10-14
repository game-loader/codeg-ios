import Foundation

// MARK: - Terminal endpoints

/// Server-side PTY control. The codeg server runs the actual shell process in
/// the folder's directory; the client drives it over these HTTP calls and reads
/// its output from the `/ws/events` firehose (see ``TerminalSocket``). Mirrors
/// the web client's `terminalSpawn`/`terminalWrite`/… in `src/lib/api.ts`.
extension CodegClient {
    /// Existing PTY recovery operation. An untyped route 404 means an older
    /// server; structured resource errors and authentication failures are errors.
    func terminalSnapshot(terminalId: String) async throws -> TerminalSnapshot {
        do {
            return try await postJSON("terminal_snapshot", TerminalIdBody(terminalId: terminalId))
        } catch {
            try checkBinding()
            if case APIError.server(404, nil, _, nil) = error {
                throw TerminalSnapshotAPIError.unsupported
            }
            throw error
        }
    }

    /// Spawn a PTY in `workingDir`. The server honors a client-supplied
    /// `terminalId` (we pass a UUID so we can subscribe to its output channel
    /// *before* spawning — matching the web's subscribe-before-spawn ordering so
    /// no early output is dropped). Returns the terminal id (a bare JSON string).
    func terminalSpawn(
        workingDir: String,
        shell: String? = nil,
        initialCommand: String? = nil,
        terminalId: String? = nil
    ) async throws -> String {
        let data = try await send(
            "terminal_spawn",
            body: TerminalSpawnBody(
                workingDir: workingDir,
                shell: shell,
                initialCommand: initialCommand,
                terminalId: terminalId
            )
        )
        guard let id = try? CodegJSON.decoder.decode(String.self, from: data),
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decoding("terminal_spawn did not return a terminal id")
        }
        return id
    }

    /// Send raw input bytes (as a string) to the PTY. Server does `.as_bytes()`,
    /// so control sequences ride through unchanged.
    func terminalWrite(terminalId: String, data: String) async throws {
        _ = try await send("terminal_write", body: TerminalWriteBody(terminalId: terminalId, data: data))
    }

    /// Resize the PTY to `cols`×`rows` (the terminal emulator computes these from
    /// the view size and reports them via its delegate).
    func terminalResize(terminalId: String, cols: Int, rows: Int) async throws {
        _ = try await send("terminal_resize", body: TerminalResizeBody(terminalId: terminalId, cols: cols, rows: rows))
    }

    /// Kill the PTY. The server does **not** auto-reap PTYs when the WebSocket
    /// closes (they outlive the socket), so the client must call this explicitly
    /// on teardown to avoid orphan shells.
    func terminalKill(terminalId: String) async throws {
        _ = try await send("terminal_kill", body: TerminalIdBody(terminalId: terminalId))
    }
}

enum TerminalSnapshotAPIError: Error, Sendable {
    case unsupported
}

// MARK: - Request bodies

struct TerminalSpawnBody: Encodable, Sendable {
    let workingDir: String
    let shell: String?
    let initialCommand: String?
    let terminalId: String?
}

struct TerminalWriteBody: Encodable, Sendable {
    let terminalId: String
    let data: String
}

struct TerminalResizeBody: Encodable, Sendable {
    let terminalId: String
    let cols: Int
    let rows: Int
}

struct TerminalIdBody: Encodable, Sendable {
    let terminalId: String
}
