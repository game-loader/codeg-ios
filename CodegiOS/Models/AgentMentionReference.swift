import Foundation

/// Desktop-compatible @Agent links. The server derives delegation routing from
/// these visible links in text blocks; no separate prompt metadata is required.
enum AgentMentionReference {
    static func appending(name: String, agentType: String, to draft: String) -> String {
        guard let reference = markdown(name: name, agentType: agentType) else { return draft }
        let separator = !draft.isEmpty && !(draft.last?.isWhitespace ?? false) ? " " : ""
        return draft + separator + reference + " "
    }

    static func markdown(name: String, agentType: String) -> String? {
        // Match the server's reference grammar, preserving custom agent IDs.
        guard agentType.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z"#,
                              options: .regularExpression) != nil else { return nil }
        let flatName = name.replacingOccurrences(of: #"\s*[\r\n]+\s*"#,
                                                 with: " ", options: .regularExpression)
        let label = flatName.isEmpty ? agentType : flatName
        // Escape the same inline punctuation as desktop referenceToMarkdown.
        let punctuation = Set("\\`*_~[]()<>")
        let escaped = label.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
        return "[@\(escaped)](codeg://agent/\(agentType))"
    }
}
