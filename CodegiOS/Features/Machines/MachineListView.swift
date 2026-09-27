import SwiftUI

/// Machines the codeg backend can reach over SSH: its tailnet peers (listed
/// by Tailscale) and hosts added by hand. A machine opens to a live SSH probe
/// of its resources, which can be inserted into a message as context.
struct MachineListView: View {
    let client: CodegClient?

    @State private var inventory: MachineInventory?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var unsupported = false
    @State private var search = ""
    @State private var editor: ManualMachineEditor.Mode?

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .navigationTitle("Machines")
        .toolbar {
            if client != nil, !unsupported {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editor = .add } label: { Image(systemName: "plus") }
                        .tint(Theme.accent)
                        .accessibilityLabel("Add Machine")
                }
            }
        }
        .searchable(text: $search, prompt: "Search machines")
        // Re-runs on every return to the list, so edits and removals made on the
        // detail screen show up.
        .task { await load() }
        .sheet(item: $editor) { mode in
            if let client {
                ManualMachineEditor(client: client, mode: mode) { _ in
                    Task { await load() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if client == nil {
            EmptyStateView(
                icon: "server.rack",
                title: "No Server Selected",
                message: "Pick a server in the Chats tab to see its machines."
            )
        } else if unsupported {
            EmptyStateView(
                icon: "server.rack",
                title: "Machines Unavailable",
                message: "This server doesn't support machines yet. Update codeg on the server to use them."
            )
        } else if inventory == nil, let loadError {
            InlineErrorView(message: loadError) { Task { await load() } }
        } else if inventory == nil {
            LoadingView(label: "Loading machines…")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                if let discoveryError = inventory?.discoveryError {
                    DiscoveryNotice(message: discoveryError)
                }
                if let loadError {
                    NoticeCard(tone: .error, title: "Couldn’t refresh", message: loadError)
                }
                let machines = filtered
                if machines.isEmpty {
                    emptyNote
                } else {
                    GlassCard(cornerRadius: Theme.Radius.lg, padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                                if index > 0 { InsetDivider(leading: MachineRow.dividerInset) }
                                NavigationLink(value: Route.machine(machine)) {
                                    MachineRow(machine: machine, probeOutcome: probeOutcome(machine))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, Theme.Layout.screenTopInset)
            .padding(.bottom, Theme.Layout.screenBottomInset)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    @ViewBuilder
    private var emptyNote: some View {
        if search.isEmpty {
            EmptyStateView(
                icon: "server.rack",
                title: "No Machines",
                message: "Machines on the server’s tailnet appear here. Add other SSH hosts with +."
            )
            .padding(.top, 24)
        } else {
            Text("No machines match “\(search)”.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        }
    }

    /// The web's search: name, MagicDNS name, OS and addresses.
    private var filtered: [Machine] {
        let machines = inventory?.machines ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return machines }
        return machines.filter { machine in
            ([machine.name, machine.dnsName, machine.os] + machine.addresses)
                .contains { $0.lowercased().contains(query) }
        }
    }

    private func probeOutcome(_ machine: Machine) -> Bool? {
        guard let client else { return nil }
        return MachineProbeCache.outcome(machine: machine.id, scope: client.serverScope)
    }

    private func load() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            inventory = try await client.listMachines()
            loadError = nil
        } catch let error as APIError where error.isUnsupportedEndpoint {
            unsupported = true
        } catch {
            // Leaving the screen cancels the request; that is not a failure.
            guard !Task.isCancelled else { return }
            loadError = (error as? APIError)?.displayMessage ?? error.localizedDescription
        }
    }
}

// MARK: - Row

private struct MachineRow: View {
    let machine: Machine
    /// The last probe's outcome for a manual machine (Tailscale reports its own).
    let probeOutcome: Bool?

    static let tileSize: CGFloat = 36
    static var dividerInset: CGFloat { SettingsRowMetrics.hInset + tileSize + 12 }

    var body: some View {
        GroupedRow(vInset: 12) {
            HStack(spacing: 12) {
                Image(systemName: machine.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Self.tileSize, height: Self.tileSize)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: machine.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if machine.isSelf {
                            Text("This machine")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.surface, in: Capsule())
                        }
                    }
                    Text(verbatim: machine.addressLine)
                        .font(.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(machine.kindLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                MachineStatusLabel(status: machine.listStatus(probeOutcome: probeOutcome))

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Where a machine stands: Tailscale's online flag, or the last probe's
/// outcome for a manual machine.
enum MachineStatus {
    case online, offline, reachable, unreachable, probing, notProbed

    var title: LocalizedStringKey {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .reachable: "Reachable"
        case .unreachable: "Unreachable"
        case .probing: "Probing…"
        case .notProbed: "Not probed"
        }
    }

    var color: Color {
        switch self {
        case .online, .reachable: DiffPalette.addText
        case .unreachable: Theme.danger
        case .probing: Theme.warning
        case .offline, .notProbed: Theme.textTertiary
        }
    }
}

struct MachineStatusLabel: View {
    let status: MachineStatus

    var body: some View {
        HStack(spacing: 5) {
            IndicatorDot(color: status.color, hollow: status == .notProbed)
            Text(status.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .fixedSize()
    }
}

extension Machine {
    var symbol: String {
        if isManual { return "server.rack" }
        let os = os.lowercased()
        if os.contains("ios") { return "iphone" }
        if os.contains("android") { return "smartphone" }
        if os.contains("mac") || os.contains("darwin") { return "laptopcomputer" }
        if os.contains("windows") { return "pc" }
        return "desktopcomputer"
    }

    /// How the backend reaches it: addresses (or the MagicDNS name), plus the
    /// port for a manual machine.
    var addressLine: String {
        let host = addresses.isEmpty ? dnsName : addresses.joined(separator: ", ")
        return isManual ? "\(host) · \(sshPort)" : host
    }

    var kindLabel: LocalizedStringKey {
        if isManual { return "Manual SSH" }
        return os.isEmpty ? "Tailscale" : "Tailscale · \(os)"
    }

    func listStatus(probeOutcome: Bool?) -> MachineStatus {
        if isManual {
            return probeOutcome.map { $0 ? .reachable : .unreachable } ?? .notProbed
        }
        return online.map { $0 ? .online : .offline } ?? .notProbed
    }
}

// MARK: - Discovery problems

/// Why the tailnet couldn't be listed. A logged-out Tailscale is the common
/// case, and the error carries the link that fixes it.
private struct DiscoveryNotice: View {
    let message: String

    var body: some View {
        if let login = MachineContext.tailscaleLoginURL(in: message) {
            NoticeCard(tone: .warning, title: "Tailscale login required", message: message) {
                Link(destination: login) {
                    Label("Log in to Tailscale", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.semibold))
                }
                .tint(Theme.accent)
                Text("After authorizing, pull down to refresh.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            NoticeCard(tone: .error, title: "Machine discovery failed", message: message) {
                Text("Manually added machines are still listed.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Per-server client state

/// The last probe outcome per machine, so the list can mark a manual machine
/// reachable or not (Tailscale reports online state itself). In memory only.
@MainActor
enum MachineProbeCache {
    private static var outcomes: [String: Bool] = [:]

    static func record(_ reachable: Bool, machine: String, scope: String) {
        outcomes["\(scope)|\(machine)"] = reachable
    }

    static func outcome(machine: String, scope: String) -> Bool? {
        outcomes["\(scope)|\(machine)"]
    }
}

/// The SSH user to probe a Tailscale machine as, per server and machine — a
/// client-side preference, like the web's localStorage entry.
enum MachineSSHUserStore {
    static func user(for machine: String, scope: String) -> String {
        UserDefaults.standard.string(forKey: key(machine, scope)) ?? ""
    }

    static func set(_ user: String, for machine: String, scope: String) {
        if user.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(machine, scope))
        } else {
            UserDefaults.standard.set(user, forKey: key(machine, scope))
        }
    }

    private static func key(_ machine: String, _ scope: String) -> String {
        "codeg.machines.sshUser.\(scope).\(machine)"
    }
}

extension CodegClient {
    /// Identifies the server for client-side per-server state.
    var serverScope: String { baseURL.absoluteString }
}
