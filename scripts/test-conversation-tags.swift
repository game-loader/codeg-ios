import Foundation

// Run from the repository root:
//   swift scripts/test-conversation-tags.swift
// Linux Docker alternative (read-only repository; build files live in /tmp):
//   docker run --rm -v "$PWD:/repo:ro" -w /repo swift:6.2-jammy \
//     swift scripts/test-conversation-tags.swift
// The temporary package uses the actual feature sources and XCTest files.
// Only unrelated SwiftUI declarations/endpoints and Linux-unavailable URLSession
// connectivity options are removed from COPIES of pre-existing dependencies.

func runConversationTagTests() throws {
    let fileManager = FileManager.default
    let repository = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? fileManager.currentDirectoryPath)
    let temporary = fileManager.temporaryDirectory.appendingPathComponent("codeg-conversation-tags-\(UUID().uuidString)")
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporary) }

    func source(_ path: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }
    func section(_ text: String, from start: String, to end: String) throws -> String {
        guard let lower = text.range(of: start),
              let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
            throw NSError(domain: "ConversationTagChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Source boundary changed: \(start) / \(end)"])
        }
        return String(text[lower.lowerBound..<upper.lowerBound])
    }
    func write(_ text: String, _ path: String) throws {
        let target = temporary.appendingPathComponent(path)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }
    let foundationImports = "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n"
    try write("""
    #if os(Linux)
    extension String { init(localized: String) { self = localized } }
    #endif
    """, "Sources/Codeg/PortableLocalization.swift")

    try write("""
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(
        name: "ConversationTagChecks",
        platforms: [.macOS(.v14)],
        products: [.library(name: "Codeg", targets: ["Codeg"])],
        targets: [.target(name: "Codeg"), .testTarget(name: "CodegTests", dependencies: ["Codeg"])],
        swiftLanguageModes: [.v5]
    )
    """, "Package.swift")

    for path in [
        "CodegiOS/Models/ConversationTag.swift",
        "CodegiOS/Features/ConversationTags/ConversationTagsModel.swift",
        "CodegiOS/Networking/CodegClient+ConversationTags.swift",
        "CodegiOS/Networking/ServerBindingLifetime.swift",
        "CodegiOS/Networking/ServerBoundHTTP.swift",
        "CodegiOS/Networking/JSONCoding.swift",
        "CodegiOS/Networking/APIError.swift"
    ] {
        try write(source(path), "Sources/Codeg/" + URL(fileURLWithPath: path).lastPathComponent)
    }

    // Keep actual initializer, binding checks, request encoding, transport,
    // response/error decoding and read-session choice. No fake CodegClient.
    let client = try source("CodegiOS/Networking/CodegClient.swift")
    var transport = try section(client, from: "struct CodegClient:", to: "    // MARK: - Endpoints")
    transport += try section(client, from: "    func postJSON<", to: "    // MARK: - Bare-value helpers")
    transport += "}\n"
    #if os(Linux)
    transport = transport.replacingOccurrences(of: "        cfg.waitsForConnectivity = true\n", with: "")
    #endif
    try write(foundationImports + transport, "Sources/Codeg/CodegClient.swift")

    // The summary and folder wire shapes are copied intact. Remove only the
    // ConversationStatus SwiftUI label/tint and unrelated transcript types.
    let conversation = try source("CodegiOS/Models/Conversation.swift")
    var models = foundationImports
    models += try section(conversation, from: "struct FolderDetail:", to: "/// Lifecycle status")
    models += try section(conversation, from: "enum ConversationStatus:", to: "    var label:") + "}\n"
    models += try section(conversation, from: "struct ConversationSummary:", to: "/// Aggregate token/timing stats")
    try write(models, "Sources/Codeg/Conversation.swift")
    let agent = try source("CodegiOS/Models/AgentType.swift")
    try write(foundationImports + section(agent, from: "enum AgentType:", to: "    /// Readable fallback") + "}\n",
              "Sources/Codeg/AgentType.swift")
    let requests = try source("CodegiOS/Networking/WireRequests.swift")
    let empty = try section(requests, from: "struct EmptyBody:", to: "struct SubmitSessionFeedbackBody:")
    guard let serverErrorStart = requests.range(of: "struct ServerError:") else {
        throw NSError(domain: "ConversationTagChecks", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "ServerError source boundary changed"])
    }
    try write(foundationImports + empty + String(requests[serverErrorStart.lowerBound...]),
              "Sources/Codeg/WireRequests.swift")
    for name in ["ConversationTagWireTests.swift", "ConversationTagIsolationTests.swift"] {
        try write(source("CodegiOSTests/" + name), "Tests/CodegTests/" + name)
    }

    print("Testing actual conversation tag sources and URLProtocol XCTest fixtures in a temporary package.")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "test", "--package-path", temporary.path, "--jobs", "2"]
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "ConversationTagChecks", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "Conversation tag XCTest validation failed"])
    }
    print("Conversation tag wire, compatibility, scoping and isolation checks: PASS")
}

do { try runConversationTagTests() }
catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
