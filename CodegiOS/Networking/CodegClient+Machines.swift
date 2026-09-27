import Foundation

/// Machines: Tailscale peers the backend discovers plus hosts added by hand,
/// probed over SSH for a snapshot of their resources (`commands::machines`).
extension CodegClient {
    /// Discovery runs on every call (up to ~12s). A discovery failure still
    /// succeeds, with the manual machines only and the reason in
    /// `discoveryError`.
    func listMachines() async throws -> MachineInventory {
        try await machineCall("list_machines", EmptyBody())
    }

    /// One SSH sample. Can take ~25–40s (a Tailscale status refresh, then ssh;
    /// the server runs at most four at once). `sshUser` is only for Tailscale
    /// machines: a manual machine always uses its saved user, so pass nil.
    func probeMachine(id: String, sshUser: String?) async throws -> MachineSnapshot {
        try await machineCall("probe_machine", ProbeMachineBody(machineId: id, sshUser: sshUser))
    }

    /// Create (`input.id` nil) or update a manual machine; returns the saved entry.
    func saveManualMachine(_ input: ManualMachineInput) async throws -> Machine {
        try await machineCall("save_manual_machine", SaveManualMachineBody(input: input))
    }

    /// Remove a manual machine and its saved password. Response is `null`.
    func deleteManualMachine(id: String) async throws {
        try await send("delete_manual_machine", body: MachineIdBody(machineId: id), session: Self.probeSession)
    }

    /// Decoded without key conversion (see `Machine`), on the long-timeout
    /// session: discovery and probes run subprocesses with their own timeouts.
    private func machineCall<Req: Encodable, Res: Decodable>(_ path: String, _ body: Req) async throws -> Res {
        let data = try await send(path, body: body, session: Self.probeSession)
        do { return try MachineJSON.decoder.decode(Res.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }
}

private struct ProbeMachineBody: Encodable {
    let machineId: String
    let sshUser: String?
}

private struct SaveManualMachineBody: Encodable {
    let input: ManualMachineInput
}

private struct MachineIdBody: Encodable {
    let machineId: String
}

extension APIError {
    /// The server predates the endpoint: an unknown route answers 501
    /// `not_implemented` (404 on older builds).
    var isUnsupportedEndpoint: Bool {
        if case .server(let status, let code, _, _) = self {
            return status == 501 || code == "not_implemented" || (status == 404 && code == nil)
        }
        return false
    }

    /// What the web shows for a failed call: the server's `detail` when it has
    /// one (ssh stderr, a login URL), else its message.
    var displayMessage: String {
        if case .server(_, _, let message, let detail) = self {
            if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                return detail
            }
            return message
        }
        return errorDescription ?? String(describing: self)
    }
}
