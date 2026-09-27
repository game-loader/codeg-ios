import Foundation

/// A machine the codeg backend can reach over SSH: a Tailscale peer it
/// discovered, or a host added by hand (Rust `commands::machines::Machine`).
///
/// Machine responses are decoded with `MachineJSON.decoder`, which does NOT
/// convert snake_case keys: the shared decoder's conversion would also rewrite
/// the keys of `MachineSnapshot.metrics` (`memory_total` → `memoryTotal`), and
/// those keys go back to the agent verbatim in the machine context.
struct Machine: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    /// Tailscale MagicDNS name; empty for manual machines.
    let dnsName: String
    let addresses: [String]
    let os: String
    /// Tailscale's view of the peer; nil for a manual machine (known only by
    /// probing it).
    let online: Bool?
    /// Tailscale's `LastSeen`, passed through unparsed.
    let lastSeen: String?
    /// The backend's own node.
    let isSelf: Bool
    /// `tailscale` or `manual`.
    let source: String
    /// Used by the probe only for manual machines; a Tailscale probe takes the
    /// port from the backend's SSH config.
    let sshPort: Int
    let sshUser: String?

    var isManual: Bool { source == "manual" }

    enum CodingKeys: String, CodingKey {
        case id, name, addresses, os, online, source
        case dnsName = "dns_name"
        case lastSeen = "last_seen"
        case isSelf = "is_self"
        case sshPort = "ssh_port"
        case sshUser = "ssh_user"
    }

    init(
        id: String, name: String, dnsName: String = "", addresses: [String] = [], os: String = "",
        online: Bool? = nil, lastSeen: String? = nil, isSelf: Bool = false, source: String = "tailscale",
        sshPort: Int = 22, sshUser: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dnsName = dnsName
        self.addresses = addresses
        self.os = os
        self.online = online
        self.lastSeen = lastSeen
        self.isSelf = isSelf
        self.source = source
        self.sshPort = sshPort
        self.sshUser = sshUser
    }

    /// Lenient like the web types: `source`, `ssh_port` and `ssh_user` are
    /// newer than the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        dnsName = try c.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        online = try c.decodeIfPresent(Bool.self, forKey: .online)
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "tailscale"
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser)
    }
}

/// `list_machines`: Tailscale peers (self first) then manual machines. When
/// discovery fails the call still succeeds, with only the manual machines and
/// the reason in `discoveryError` (which may carry a Tailscale login URL).
struct MachineInventory: Decodable, Sendable {
    let machines: [Machine]
    let discoveryError: String?

    enum CodingKeys: String, CodingKey {
        case machines
        case discoveryError = "discovery_error"
    }
}

/// `probe_machine`: one SSH sample of a machine.
struct MachineSnapshot: Decodable, Hashable, Sendable {
    /// Freshly discovered (Tailscale) or marked online with the probed OS (manual).
    let machine: Machine
    /// RFC 3339 with a `+00:00` offset and 0–9 fractional digits.
    let sampledAt: String
    /// `user@host`, or `host` for a Tailscale probe with no user.
    let sshTarget: String
    /// Display strings keyed by `MachineMetric` raw values; only `hostname` and
    /// `os` are guaranteed.
    let metrics: [String: String]

    enum CodingKeys: String, CodingKey {
        case machine, metrics
        case sampledAt = "sampled_at"
        case sshTarget = "ssh_target"
    }
}

/// `save_manual_machine`'s `input`. `id` nil creates a machine; `password` nil
/// keeps the saved one when editing (required when creating). The password is
/// write-only: no response ever includes it.
struct ManualMachineInput: Encodable, Sendable {
    var id: String?
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String?
}

/// The metrics a probe can report, in the order the web shows them.
enum MachineMetric: String, CaseIterable, Sendable {
    case hostname
    case os
    case architecture
    case cpu
    case cpuCores = "cpu_cores"
    case memoryTotal = "memory_total"
    case memoryAvailable = "memory_available"
    case disk
    case load
    case uptime
    case gpu

    /// Long values that get a whole row in the grid.
    var isWide: Bool { self == .disk || self == .gpu || self == .cpu }
}

enum MachineJSON {
    static let decoder = JSONDecoder()
}

// MARK: - Context for the conversation

enum MachineContext {
    /// The text the composer inserts for a machine, byte-for-byte what codeg web
    /// writes (`formatMachineContext` in `src/lib/machines.ts`): a fixed preamble
    /// line, then the observation as 2-space-indented JSON with the web's key
    /// order, then a newline. The machine fields are an allowlist, so a field an
    /// API adds later never reaches a conversation unreviewed.
    static func format(machine: Machine, snapshot: MachineSnapshot?, error: String?) -> String {
        let observed = snapshot?.machine ?? machine
        var fields: [(String, OrderedJSON)] = [
            ("id", .string(observed.id)),
            ("name", .string(observed.name)),
            ("source", .string(observed.source)),
            ("dns_name", .string(observed.dnsName)),
            ("addresses", .array(observed.addresses.map(OrderedJSON.string))),
            ("os", .string(observed.os)),
            ("online", observed.online.map(OrderedJSON.bool) ?? .null),
            ("last_seen", observed.lastSeen.map(OrderedJSON.string) ?? .null),
            ("is_self", .bool(observed.isSelf)),
        ]
        // A tailnet probe inherits its port from the backend's SSH config, so
        // the listed 22 was never observed; the web leaves the key out.
        if observed.isManual { fields.append(("ssh_port", .number(observed.sshPort))) }
        fields.append(("ssh_user", observed.sshUser.map(OrderedJSON.string) ?? .null))

        let metrics: OrderedJSON = snapshot.map { snapshot in
            .object(snapshot.metrics.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) })
        } ?? .null
        let root = OrderedJSON.object([
            ("machine", .object(fields)),
            ("sampled_at", snapshot.map { .string($0.sampledAt) } ?? .null),
            ("ssh_target", snapshot.map { .string($0.sshTarget) } ?? .null),
            ("probe_error", error.map(OrderedJSON.string) ?? .null),
            ("metrics", metrics),
        ])
        return "\(UserResources.machinePrefix)\n\(root.pretty())\n"
    }

    /// Appends a machine context to a draft on its own lines, the way the web
    /// composer frames it (`\n` + context + `\n`).
    static func draft(_ draft: String, appending context: String) -> String {
        if draft.isEmpty { return context + "\n" }
        return draft + (draft.hasSuffix("\n") ? "" : "\n") + "\n" + context + "\n"
    }

    /// The Tailscale login link in an error, if it carries one (web
    /// `tailscaleLoginUrl`): https, host exactly `login.tailscale.com`, no
    /// credentials.
    static func tailscaleLoginURL(in text: String) -> URL? {
        let ns = text as NSString
        for match in loginLink.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // Sentence punctuation after a link isn't part of it.
            var link = ns.substring(with: match.range)
            while let last = link.last, ".,;:!?)".contains(last) { link.removeLast() }
            guard let url = URL(string: link),
                  url.scheme == "https", url.host == "login.tailscale.com",
                  url.user == nil, url.password == nil else { continue }
            return url
        }
        return nil
    }

    private static let loginLink = try! NSRegularExpression(pattern: #"https://login\.tailscale\.com/[^\s"'<>]+"#)
}

/// A JSON value that keeps object keys in the order given, printed the way
/// JavaScript's `JSON.stringify(value, null, 2)` prints it.
indirect enum OrderedJSON {
    case null
    case bool(Bool)
    case number(Int)
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    func pretty(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return String(value)
        case .string(let value): return Self.quote(value)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.pretty(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            return "{\n" + fields.map { inner + Self.quote($0.0) + ": " + $0.1.pretty(indent: inner) }
                .joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    /// JSON string escaping as `JSON.stringify` does it: short escapes where
    /// JSON has them, `\u00xx` for other control characters, everything else
    /// (including `/` and non-ASCII) verbatim.
    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
