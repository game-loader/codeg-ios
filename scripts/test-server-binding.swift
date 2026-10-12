import Foundation

@main struct ServerBindingChecks {
    static func main() async throws {
        let a = ServerBindingLifetime()
        let b = ServerBindingLifetime()
        try a.check()
        try b.check()
        a.invalidate()
        do { try a.check(); fatalError("retired A accepted an operation") }
        catch is CancellationError {}
        try b.check()
        a.invalidate()
        precondition(!a.isValid && b.isValid)
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Old server","urlString":"https://a.invalid","createdAt":0}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(ServerProfile.self, from: legacy)
        let encoded = try JSONEncoder().encode(old)
        let reloaded = try JSONDecoder().decode(ServerProfile.self, from: encoded)
        precondition(reloaded.configurationRevision == old.configurationRevision)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("token"))
        print("Server binding lifetime and profile revision migration: PASS (6 invariants)")
    }
}
