import SwiftUI

/// The coding agents codeg can drive. Wire value is snake_case (serde
/// `rename_all = "snake_case"` on the Rust `AgentType` enum); a user-registered
/// ACP agent travels as `custom:<registry-id>` (e.g. `custom:goose`). Enum
/// *values* are unaffected by the decoder's key strategy, so raw values match
/// directly.
///
/// `.other` carries any wire value this build doesn't know — a built-in added
/// to the server after this release, or a custom agent — verbatim, so it
/// round-trips back to the server unchanged. Never coerce an unknown value to a
/// known case: an agent type is echoed into `acp_connect`, the agent settings
/// writes and install/uninstall, so a coerced value resumes, reconfigures or
/// uninstalls the WRONG agent.
enum AgentType: RawRepresentable, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case claudeCode
    case codex
    case openCode
    case gemini
    case openClaw
    case cline
    case hermes
    case codeBuddy
    case kimiCode
    case pi
    case grok
    case cursor
    case deepSeek
    case qoder
    case antigravity
    /// An agent this build doesn't know, keeping its raw wire value.
    case other(String)

    /// The built-in agents, in the server's declaration order. `.other` values
    /// only come from the server, so they are never listed here.
    static let allCases: [AgentType] = [
        .claudeCode, .codex, .openCode, .gemini, .openClaw, .cline, .hermes,
        .codeBuddy, .kimiCode, .pi, .grok, .cursor, .deepSeek, .qoder, .antigravity,
    ]

    /// Wire prefix of a user-registered ACP agent (`custom:<registry-id>`).
    static let customPrefix = "custom:"

    /// Known wire names map to their case; any other non-empty value becomes
    /// `.other`. Only an empty string fails, so a missing stored value reads as
    /// "none" rather than as an agent named "".
    init?(rawValue: String) {
        switch rawValue {
        case "claude_code": self = .claudeCode
        case "codex": self = .codex
        case "open_code": self = .openCode
        case "gemini": self = .gemini
        case "open_claw": self = .openClaw
        case "cline": self = .cline
        case "hermes": self = .hermes
        case "code_buddy": self = .codeBuddy
        case "kimi_code": self = .kimiCode
        case "pi": self = .pi
        case "grok": self = .grok
        case "cursor": self = .cursor
        case "deepseek": self = .deepSeek
        case "qoder": self = .qoder
        case "antigravity": self = .antigravity
        case "": return nil
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .claudeCode: return "claude_code"
        case .codex: return "codex"
        case .openCode: return "open_code"
        case .gemini: return "gemini"
        case .openClaw: return "open_claw"
        case .cline: return "cline"
        case .hermes: return "hermes"
        case .codeBuddy: return "code_buddy"
        case .kimiCode: return "kimi_code"
        case .pi: return "pi"
        case .grok: return "grok"
        case .cursor: return "cursor"
        case .deepSeek: return "deepseek"
        case .qoder: return "qoder"
        case .antigravity: return "antigravity"
        case .other(let raw): return raw
        }
    }

    var id: String { rawValue }

    /// Never fails: an unknown agent type keeps its raw value (see the type doc),
    /// so one new server-side agent can't break a whole list decode either.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentType(rawValue: raw) ?? .other(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // Identity is the wire value, so `.other("codex")` built by hand still equals
    // `.codex`.
    static func == (lhs: AgentType, rhs: AgentType) -> Bool { lhs.rawValue == rhs.rawValue }
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    /// The registry id of a custom agent (`custom:goose` → `goose`), else nil.
    var customAgentID: String? {
        guard case .other(let raw) = self, raw.hasPrefix(Self.customPrefix) else { return nil }
        let id = String(raw.dropFirst(Self.customPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Readable fallback for an agent this build doesn't know: the custom
    /// registry id or the raw wire value, word-split and capitalized
    /// (`custom:my-agent` → "My Agent"). The server's `AcpAgentInfo.name` is
    /// better where one is at hand.
    private static func fallbackName(for raw: String) -> String {
        let base = raw.hasPrefix(customPrefix) ? String(raw.dropFirst(customPrefix.count)) : raw
        let words = base.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        guard !words.isEmpty else { return raw }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .openCode: return "OpenCode"
        case .gemini: return "Gemini CLI"
        case .openClaw: return "OpenClaw"
        case .cline: return "Cline"
        case .hermes: return "Hermes"
        case .codeBuddy: return "CodeBuddy"
        case .kimiCode: return "Kimi Code"
        case .pi: return "Pi"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .deepSeek: return "DeepSeek Harness"
        case .qoder: return "Qoder"
        case .antigravity: return "Google Antigravity"
        case .other(let raw): return Self.fallbackName(for: raw)
        }
    }

    /// Short label for dense badges.
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .gemini: return "Gemini"
        case .openClaw: return "OpenClaw"
        case .cline: return "Cline"
        case .hermes: return "Hermes"
        case .codeBuddy: return "CodeBuddy"
        case .kimiCode: return "Kimi"
        case .pi: return "Pi"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .deepSeek: return "DeepSeek"
        case .qoder: return "Qoder"
        case .antigravity: return "Antigravity"
        case .other(let raw): return Self.fallbackName(for: raw)
        }
    }

    /// SF Symbol fallback, used when there is no brand asset (always the case for
    /// `.other`).
    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .openCode: return "curlybraces"
        case .gemini: return "diamond"
        case .openClaw: return "pawprint"
        case .cline: return "terminal"
        case .hermes: return "bolt.horizontal.circle"
        case .codeBuddy: return "hammer"
        case .kimiCode: return "moon.stars"
        case .pi: return "pi"
        case .grok: return "line.diagonal"
        case .cursor: return "cursorarrow"
        case .deepSeek: return "fish"
        case .qoder: return "q.circle"
        case .antigravity: return "a.circle"
        case .other: return "puzzlepiece.extension"
        }
    }

    /// Name of the brand-icon image set in `Assets.xcassets` (the per-agent SVGs
    /// ported verbatim from the web client's `agent-icon.tsx`). Rendered by
    /// `AgentIcon`. Empty for `.other`, which has no bundled asset and falls
    /// back to `symbolName`.
    var iconAsset: String {
        switch self {
        case .claudeCode: return "AgentClaudeCode"
        case .codex: return "AgentCodex"
        case .openCode: return "AgentOpenCode"
        case .gemini: return "AgentGemini"
        case .openClaw: return "AgentOpenClaw"
        case .cline: return "AgentCline"
        case .hermes: return "AgentHermes"
        case .codeBuddy: return "AgentCodeBuddy"
        case .kimiCode: return "AgentKimiCode"
        case .pi: return "AgentPi"
        case .grok: return "AgentGrok"
        case .cursor: return "AgentCursor"
        case .deepSeek: return "AgentDeepSeek"
        case .qoder: return "AgentQoder"
        case .antigravity: return "AgentAntigravity"
        case .other: return ""
        }
    }

    /// Whether the brand asset is a monochrome (template) glyph that should be
    /// tinted by the caller. Mirrors the web's `MONO_ICONS` set (OpenCode, Cline,
    /// Hermes, CodeBuddy, Grok, Cursor, Qoder, Antigravity); the others carry
    /// their own brand colors/gradients and render as-is.
    var iconIsTemplate: Bool {
        switch self {
        case .openCode, .cline, .hermes, .codeBuddy, .grok, .cursor, .qoder, .antigravity, .other: return true
        case .claudeCode, .codex, .gemini, .openClaw, .kimiCode, .pi, .deepSeek: return false
        }
    }

    /// Accent color used for badges / avatars per agent.
    var accent: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.52, blue: 0.34) // claude clay
        case .codex: return Color(red: 0.45, green: 0.78, blue: 0.66)      // teal
        case .openCode: return Color(red: 0.55, green: 0.62, blue: 0.95)   // indigo
        case .gemini: return Color(red: 0.50, green: 0.70, blue: 0.98)     // blue
        case .openClaw: return Color(red: 0.92, green: 0.62, blue: 0.42)   // amber
        case .cline: return Color(red: 0.62, green: 0.78, blue: 0.50)      // green
        case .hermes: return Color(red: 0.60, green: 0.50, blue: 0.85)     // violet
        case .codeBuddy: return Color(red: 0.20, green: 0.47, blue: 0.96)  // tencent blue
        case .kimiCode: return Color(red: 0.09, green: 0.51, blue: 1.0)    // moonshot blue
        case .pi: return Color(red: 0.22, green: 0.22, blue: 0.26)         // pi slate
        // xAI's mark is monochrome (web `bg-neutral-900`); a static near-black
        // would vanish on the dark card, so tint dynamically — near-black in
        // light, near-white in dark — mirroring the brand while staying legible.
        case .grok: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        // Cursor's cube mark is monochrome too (web renders it at plain
        // `text-foreground`), so it gets the same appearance-following tint.
        case .cursor: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        case .deepSeek: return Color(red: 0.30, green: 0.42, blue: 1.0)    // deepseek #4D6BFE
        case .qoder: return Color(red: 0.42, green: 0.30, blue: 0.95)      // qoder #6C4CF1
        case .antigravity: return Color(red: 0.10, green: 0.45, blue: 0.91) // google #1A73E8
        case .other: return Color(red: 0.55, green: 0.58, blue: 0.64)      // neutral slate
        }
    }
}
