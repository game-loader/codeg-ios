import Foundation

/// Run with the real Foundation-only serializer; no app or simulator required.
@main
struct AgentMentionChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }

        let codex = "[@Codex](codeg://agent/codex)"
        check(AgentMentionReference.markdown(name: "Codex", agentType: "codex") == codex,
              "Must match desktop's wire representation")
        check(AgentMentionReference.markdown(name: "", agentType: "custom:my-agent")
              == "[@custom:my-agent](codeg://agent/custom:my-agent)",
              "Custom routing IDs must survive unchanged with an empty label")

        let label = "审查 [A](B) \\ `x` *y* _z_ ~q~ <r>\n第二行"
        let escaped = #"审查 \[A\]\(B\) \\ \`x\` \*y\* \_z\_ \~q\~ \<r\> 第二行"#
        let link = AgentMentionReference.markdown(name: label, agentType: "claude_code")!
        check(link == "[@\(escaped)](codeg://agent/claude_code)",
              "Labels must be escaped and flattened like desktop")
        // This is the server's visible-agent-link grammar, so an escaped label
        // must still yield exactly one route with the intended wire type.
        let routes = try NSRegularExpression(pattern: #"\[(?:\\.|[^\]\\\r\n])+\]\(codeg://agent/([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\)"#)
        let matches = routes.matches(in: link, range: NSRange(link.startIndex..., in: link))
        check(matches.count == 1, "Escaped labels must still be recognizable by the server")
        check((link as NSString).substring(with: matches[0].range(at: 1)) == "claude_code",
              "The display label must never change the route")

        for invalid in ["", "codex)", "codex\n", "a/b", "a b", String(repeating: "a", count: 129)] {
            check(AgentMentionReference.markdown(name: "Agent", agentType: invalid) == nil,
                  "Reject invalid routing IDs")
            check(AgentMentionReference.appending(name: "Agent", agentType: invalid, to: "保留草稿") == "保留草稿",
                  "Invalid references must preserve the draft")
        }
        check(AgentMentionReference.appending(name: "Codex", agentType: "codex", to: "") == codex + " ",
              "An empty draft needs no leading separator")
        check(AgentMentionReference.appending(name: "Codex", agentType: "codex", to: "请审查") == "请审查 " + codex + " ",
              "Preserve existing prose and separate the mention")
        check(AgentMentionReference.appending(name: "Codex", agentType: "codex", to: "第一行\n") == "第一行\n" + codex + " ",
              "Preserve multiline drafts without redundant spaces")
        let first = AgentMentionReference.appending(name: "Codex", agentType: "codex", to: "") + "修复测试；"
        let multiple = AgentMentionReference.appending(name: "Claude", agentType: "claude_code", to: first)
        check(multiple == codex + " 修复测试； [@Claude](codeg://agent/claude_code) ",
              "Adding another agent must retain the first agent's task")
        print("Agent mention serialization and draft checks passed")
    }
}
