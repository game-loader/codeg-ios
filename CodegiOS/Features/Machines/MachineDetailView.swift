import SwiftUI

/// One machine: probed over SSH on arrival (and on demand) for a snapshot of
/// its resources. A Tailscale machine can be probed as a chosen SSH user; a
/// manual one can be edited or removed. With `onInsert` (the composer's picker)
/// the snapshot — or the probe's failure — can be inserted into the message.
struct MachineDetailView: View {
    let client: CodegClient
    var onInsert: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var machine: Machine
    @State private var snapshot: MachineSnapshot?
    @State private var probeError: String?
    @State private var isProbing = false
    @State private var sshUser: String
    /// The SSH user the shown result was probed as: inserting is refused once
    /// the field no longer matches it (the web's rule).
    @State private var probedUser: String?
    @State private var editor: ManualMachineEditor.Mode?
    @State private var confirmRemove = false
    @State private var isRemoving = false
    @State private var removeError: String?

    init(client: CodegClient, machine: Machine, onInsert: ((String) -> Void)? = nil) {
        self.client = client
        self.onInsert = onInsert
        _machine = State(initialValue: machine)
        _sshUser = State(initialValue: MachineSSHUserStore.user(for: machine.id, scope: client.serverScope))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                    header
                    if !machine.isManual { sshUserSection }
                    if let probeError { ProbeErrorNotice(message: probeError) }
                    if let removeError { NoticeCard(tone: .error, title: "Couldn’t remove", message: removeError) }
                    if let snapshot { snapshotSection(snapshot) }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, Theme.Layout.screenTopInset)
                .padding(.bottom, Theme.Layout.screenBottomInset)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(Text(verbatim: machine.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if onInsert != nil { insertBar }
        }
        .task {
            if snapshot == nil, probeError == nil { await probe() }
        }
        .sheet(item: $editor) { mode in
            ManualMachineEditor(client: client, mode: mode) { saved in
                machine = saved
                Task { await probe() }
            }
        }
        .alert(
            Text("Remove \(machine.name)?"),
            isPresented: $confirmRemove
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("This removes the saved connection and password from codeg. The machine itself is unaffected.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await probe() } } label: {
                if isProbing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isProbing)
            .tint(Theme.accent)
            .accessibilityLabel("Probe")
        }
        if machine.isManual {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editor = .edit(machine) } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .disabled(isRemoving)
                .tint(Theme.accent)
            }
        }
    }

    // MARK: - Sections

    private var status: MachineStatus {
        if isProbing { return .probing }
        if machine.isManual {
            if snapshot != nil { return .reachable }
            return probeError == nil ? .notProbed : .unreachable
        }
        return machine.listStatus(probeOutcome: nil)
    }

    private var header: some View {
        GlassCard(cornerRadius: Theme.Radius.lg, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: machine.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: machine.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        MachineStatusLabel(status: status)
                    }
                    Spacer(minLength: 0)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        LabeledValue(label: "Source", value: machine.isManual ? String(localized: "Manual SSH") : "Tailscale")
                        LabeledValue(label: "OS", value: snapshot?.machine.os ?? machine.os)
                    }
                    GridRow {
                        LabeledValue(label: "Address", value: machine.addressLine, monospaced: true)
                            .gridCellColumns(2)
                    }
                    if machine.isManual {
                        GridRow {
                            LabeledValue(label: "SSH User", value: machine.sshUser, monospaced: true)
                            LabeledValue(label: "Port", value: String(machine.sshPort), monospaced: true)
                        }
                    } else if !machine.dnsName.isEmpty, !machine.addresses.isEmpty {
                        GridRow {
                            LabeledValue(label: "DNS Name", value: machine.dnsName, monospaced: true)
                                .gridCellColumns(2)
                        }
                    }
                    if let lastSeen = MachineDates.lastSeen(machine.lastSeen) {
                        GridRow {
                            LabeledValue(label: "Last Seen", value: lastSeen.formatted(.relative(presentation: .named)))
                                .gridCellColumns(2)
                        }
                    }
                }
            }
        }
    }

    private var sshUserSection: some View {
        EditorSection(
            title: "SSH User",
            footer: "Empty uses the server’s SSH configuration. Saved on this device."
        ) {
            FieldRow(label: "User") {
                HStack(spacing: 8) {
                    TextField("Default user", text: $sshUser)
                        .font(.mono(15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.go)
                        .onSubmit { Task { await probe() } }
                    Button("Probe") { Task { await probe() } }
                        .buttonStyle(.glass)
                        .tint(Theme.accent)
                        .disabled(isProbing)
                }
            }
        }
    }

    private func snapshotSection(_ snapshot: MachineSnapshot) -> some View {
        EditorSection(title: "Snapshot") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(verbatim: snapshot.sshTarget)
                        .font(.mono(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let sampled = MachineDates.parse(snapshot.sampledAt) {
                        Text(sampled.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    ForEach(Array(MachineMetric.gridRows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row, id: \.self) { metric in
                                LabeledValue(
                                    label: metric.title,
                                    value: metric.display(snapshot.metrics[metric.rawValue]),
                                    monospaced: metric == .load
                                )
                                .gridCellColumns(row.count == 1 ? 2 : 1)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var insertBar: some View {
        PrimaryGlassButton(title: "Insert into Message", systemImage: "text.insert", isLoading: isProbing) {
            onInsert?(MachineContext.format(machine: machine, snapshot: snapshot, error: probeError))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .disabled(!canInsert)
    }

    private var trimmedUser: String { sshUser.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canInsert: Bool {
        guard !isProbing, snapshot != nil || probeError != nil else { return false }
        return machine.isManual || trimmedUser == probedUser
    }

    // MARK: - Actions

    private func probe() async {
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
        let user = trimmedUser
        if !machine.isManual {
            MachineSSHUserStore.set(user, for: machine.id, scope: client.serverScope)
        }
        do {
            // A manual machine always uses its saved user; any other value is
            // refused by the server.
            let result = try await client.probeMachine(
                id: machine.id,
                sshUser: machine.isManual || user.isEmpty ? nil : user
            )
            snapshot = result
            probeError = nil
            MachineProbeCache.record(true, machine: machine.id, scope: client.serverScope)
        } catch {
            guard !Task.isCancelled else { return }
            snapshot = nil
            probeError = (error as? APIError)?.displayMessage ?? error.localizedDescription
            MachineProbeCache.record(false, machine: machine.id, scope: client.serverScope)
        }
        probedUser = user
    }

    private func remove() async {
        isRemoving = true
        removeError = nil
        do {
            try await client.deleteManualMachine(id: machine.id)
            isRemoving = false
            dismiss()
        } catch {
            isRemoving = false
            removeError = (error as? APIError)?.displayMessage ?? error.localizedDescription
        }
    }
}

/// A failed probe, with the Tailscale login link when that's what stands in
/// the way (Tailscale SSH's check mode prints one and waits).
private struct ProbeErrorNotice: View {
    let message: String

    var body: some View {
        if let login = MachineContext.tailscaleLoginURL(in: message) {
            NoticeCard(tone: .warning, title: "Tailscale login required", message: message) {
                Link(destination: login) {
                    Label("Log in to Tailscale", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.semibold))
                }
                .tint(Theme.accent)
                Text("After authorizing, probe again.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            NoticeCard(tone: .error, title: "SSH probe failed", message: message)
        }
    }
}

extension MachineMetric {
    var title: LocalizedStringKey {
        switch self {
        case .hostname: "Hostname"
        case .os: "OS"
        case .architecture: "Architecture"
        case .cpu: "CPU"
        case .cpuCores: "CPU Cores"
        case .memoryTotal: "Memory"
        case .memoryAvailable: "Available Memory"
        case .disk: "Disk"
        case .load: "Load Average"
        case .uptime: "Uptime"
        case .gpu: "GPU"
        }
    }

    /// Two metrics to a row; long ones get a row to themselves.
    static let gridRows: [[MachineMetric]] = {
        var rows: [[MachineMetric]] = []
        var pending: MachineMetric?
        for metric in allCases {
            if metric.isWide {
                if let held = pending { rows.append([held]); pending = nil }
                rows.append([metric])
            } else if let held = pending {
                rows.append([held, metric])
                pending = nil
            } else {
                pending = metric
            }
        }
        if let held = pending { rows.append([held]) }
        return rows
    }()

    /// Linux reports uptime as `N seconds`; shown as a duration.
    func display(_ value: String?) -> String? {
        guard let value, self == .uptime,
              let match = value.wholeMatch(of: #/(\d+) seconds/#), let seconds = Double(match.1) else { return value }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? value
    }
}

enum MachineDates {
    static func parse(_ raw: String) -> Date? { ISO8601.parse(raw) }

    /// Tailscale sends Go's zero time for a peer it has never seen.
    static func lastSeen(_ raw: String?) -> Date? {
        guard let raw, let date = ISO8601.parse(raw),
              Calendar(identifier: .gregorian).component(.year, from: date) > 1970 else { return nil }
        return date
    }
}

// MARK: - Add / edit

/// Add a machine by IP address, SSH port, user and password, or edit one. The
/// password goes to the server's secret store and never comes back.
struct ManualMachineEditor: View {
    enum Mode: Identifiable {
        case add
        case edit(Machine)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let machine): machine.id
            }
        }
    }

    let client: CodegClient
    let mode: Mode
    let onSaved: (Machine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password = ""
    @State private var isSaving = false
    @State private var error: String?

    init(client: CodegClient, mode: Mode, onSaved: @escaping (Machine) -> Void) {
        self.client = client
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _host = State(initialValue: "")
            _port = State(initialValue: "22")
            _username = State(initialValue: "root")
        case .edit(let machine):
            _name = State(initialValue: machine.name)
            _host = State(initialValue: machine.addresses.first ?? "")
            _port = State(initialValue: String(machine.sshPort))
            _username = State(initialValue: machine.sshUser ?? "root")
        }
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        EditorSection(title: "Machine") {
                            FieldRow(label: "Name") {
                                TextField("Rented GPU", text: $name)
                            }
                            Divider().overlay(Theme.hairline)
                            FieldRow(label: "IP Address") {
                                TextField("203.0.113.10", text: $host)
                                    .font(.mono(15))
                                    .keyboardType(.numbersAndPunctuation)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                            }
                        }
                        EditorSection(
                            title: "SSH",
                            footer: isAdding
                                ? LocalizedStringKey("The password is stored on the codeg server and is never included in conversations.")
                                : LocalizedStringKey("Leave the password empty to keep the saved one.")
                        ) {
                            FieldRow(label: "Port") {
                                TextField("22", text: $port)
                                    .font(.mono(15))
                                    .keyboardType(.numberPad)
                            }
                            Divider().overlay(Theme.hairline)
                            FieldRow(label: "User") {
                                TextField("root", text: $username)
                                    .font(.mono(15))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                            }
                            Divider().overlay(Theme.hairline)
                            FieldRow(label: "Password") {
                                SecureField(isAdding ? LocalizedStringKey("Required") : LocalizedStringKey("Unchanged"), text: $password)
                                    .font(.mono(15))
                                    .textContentType(.password)
                            }
                        }
                        if let error {
                            NoticeCard(tone: .error, message: error)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(isAdding ? Text("Add Machine") : Text("Edit Machine"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                        .disabled(isSaving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryGlassButton(title: "Save", systemImage: "checkmark", isLoading: isSaving) {
                    Task { await save() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
                .disabled(!canSave)
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
    }

    private var portNumber: Int? {
        Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    private var canSave: Bool {
        !isSaving && portNumber != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isAdding || !password.isEmpty)
    }

    private func save() async {
        guard let port = portNumber else { return }
        var id: String?
        if case .edit(let machine) = mode { id = machine.id }
        isSaving = true
        error = nil
        do {
            let saved = try await client.saveManualMachine(ManualMachineInput(
                id: id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password.isEmpty ? nil : password
            ))
            isSaving = false
            onSaved(saved)
            dismiss()
        } catch {
            isSaving = false
            var message = (error as? APIError)?.displayMessage ?? error.localizedDescription
            // Never echo a typed password back, whatever the server said.
            if !password.isEmpty { message = message.replacingOccurrences(of: password, with: "••••••") }
            self.error = message
        }
    }
}

// MARK: - Composer picker

/// The composer's "Machine…" insert: pick a machine, look at its probe, and
/// insert it into the draft as context.
struct MachinePickerSheet: View {
    let client: CodegClient
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MachineListView(client: client)
                .navigationDestination(for: Route.self) { route in
                    if case .machine(let machine) = route {
                        MachineDetailView(client: client, machine: machine) { context in
                            onInsert(context)
                            dismiss()
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .tint(Theme.textSecondary)
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}
