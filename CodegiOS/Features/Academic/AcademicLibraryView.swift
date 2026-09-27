import SwiftUI

/// The server's Zotero library (through the Codeg Bridge plugin in the Zotero
/// app on the server host). Opening an item prepares it as a paper — the
/// research agent finds the PDF, analyzes it and looks for its code — and
/// papers open into conversations that carry the paper as context.
struct AcademicLibraryView: View {
    let client: CodegClient?
    /// Pushes a paper (or anything it opens) onto the owning stack.
    let onOpen: (Route) -> Void

    @State private var settings: AcademicSettings?
    @State private var library: AcademicLibrary?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var unsupported = false
    @State private var search = ""
    @State private var collectionKey: String?
    @State private var showSettings = false
    @State private var showImport = false
    @State private var confirmItem: AcademicItem?
    @State private var openingItem: String?
    @State private var openError: String?

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .navigationTitle("Academic")
        .toolbar { toolbar }
        .searchable(text: $search, prompt: "Search papers")
        .task { if library == nil { await load() } }
        .sheet(isPresented: $showSettings) {
            if let client {
                AcademicSettingsSheet(client: client, settings: settings) { saved in
                    settings = saved
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $showImport) {
            if let client, let library {
                AcademicImportSheet(client: client, collections: library.collections, defaultCollection: collectionKey) { item in
                    Task {
                        await load()
                        // Importing says "prepare this": no second confirmation.
                        await open(item)
                    }
                }
            }
        }
        .confirmationDialog(
            Text(verbatim: confirmItem?.title ?? ""),
            isPresented: Binding(get: { confirmItem != nil }, set: { if !$0 { confirmItem = nil } }),
            titleVisibility: .visible,
            presenting: confirmItem
        ) { item in
            Button("Open Paper") { Task { await open(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("If this paper hasn’t been prepared yet, the research agent starts now: it finds the PDF, analyzes the paper and looks for its code. This runs on the server and can take several minutes.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if client != nil, !unsupported {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "plus") }
                    .disabled(library?.collections.isEmpty ?? true)
                    .tint(Theme.accent)
                    .accessibilityLabel("Add Paper")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .tint(Theme.accent)
                    .accessibilityLabel("Zotero Settings")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if client == nil {
            EmptyStateView(
                icon: "books.vertical",
                title: "No Server Selected",
                message: "Pick a server in the Chats tab to use its library."
            )
        } else if unsupported {
            EmptyStateView(
                icon: "books.vertical",
                title: "Academic Unavailable",
                message: "This server doesn't support the academic workbench. Update codeg on the server to use it."
            )
        } else if let settings, !settings.paired {
            EmptyStateView(
                icon: "link",
                title: "Pair Zotero",
                message: "Install the Codeg Bridge plugin in Zotero on the server’s computer, then enter the pairing token it shows.",
                actionTitle: "Zotero Settings",
                action: { showSettings = true }
            )
        } else if library == nil, let loadError {
            InlineErrorView(message: loadError) { Task { await load() } }
        } else if library == nil {
            LoadingView(label: "Loading library from Zotero…")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let loadError {
                    NoticeCard(tone: .error, title: "Couldn’t refresh", message: loadError)
                }
                if let openError {
                    NoticeCard(tone: .error, title: "Couldn’t open the paper", message: openError)
                }
                collectionPicker
                let items = filteredItems
                if items.isEmpty {
                    (search.isEmpty ? Text("No papers in this collection.") : Text("No papers match your search."))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    GlassCard(cornerRadius: Theme.Radius.lg, padding: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { InsetDivider(leading: SettingsRowMetrics.hInset) }
                                Button { select(item) } label: {
                                    AcademicItemRow(
                                        item: item,
                                        collections: collectionNames(item),
                                        isPrepared: paperID(for: item) != nil,
                                        isOpening: openingItem == item.key
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(openingItem != nil)
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

    private var collectionPicker: some View {
        Menu {
            Picker(selection: $collectionKey) {
                Text("All Papers").tag(String?.none)
                ForEach(collectionTree) { entry in
                    Text(verbatim: String(repeating: "  ", count: entry.depth) + entry.collection.name)
                        .tag(Optional(entry.collection.key))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.subheadline.weight(.semibold))
                Group {
                    if let name = selectedCollectionName {
                        Text(verbatim: name)
                    } else {
                        Text("All Papers")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                Spacer(minLength: 0)
                Text("\(filteredItems.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Derived

    private var selectedCollectionName: String? {
        guard let collectionKey else { return nil }
        return library?.collections.first { $0.key == collectionKey }?.name
    }

    /// Collections depth-first under their parents (the web's tree); ones whose
    /// parent is unknown sit at the root.
    private var collectionTree: [CollectionEntry] {
        let collections = library?.collections ?? []
        let keys = Set(collections.map(\.key))
        var children: [String?: [AcademicCollection]] = [:]
        for collection in collections {
            let parent = collection.parentKey.flatMap { keys.contains($0) ? $0 : nil }
            children[parent, default: []].append(collection)
        }
        var out: [CollectionEntry] = []
        func walk(_ parent: String?, _ depth: Int) {
            let sorted = (children[parent] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            for collection in sorted {
                out.append(CollectionEntry(collection: collection, depth: depth))
                if depth < 8 { walk(collection.key, depth + 1) }
            }
        }
        walk(nil, 0)
        return out
    }

    private struct CollectionEntry: Identifiable {
        let collection: AcademicCollection
        let depth: Int
        var id: String { collection.key }
    }

    /// The selected collection and everything below it.
    private var collectionScope: Set<String>? {
        guard let collectionKey else { return nil }
        var scope: Set<String> = [collectionKey]
        var frontier = [collectionKey]
        let collections = library?.collections ?? []
        while let key = frontier.popLast() {
            for child in collections where child.parentKey == key && !scope.contains(child.key) {
                scope.insert(child.key)
                frontier.append(child.key)
            }
        }
        return scope
    }

    /// The web's search: title, authors and collection names.
    private var filteredItems: [AcademicItem] {
        var items = library?.items ?? []
        if let scope = collectionScope {
            items = items.filter { !scope.isDisjoint(with: $0.collections) }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            items = items.filter { item in
                item.title.lowercased().contains(query)
                    || item.authors.contains { $0.lowercased().contains(query) }
                    || collectionNames(item).contains { $0.lowercased().contains(query) }
            }
        }
        return items
    }

    private func collectionNames(_ item: AcademicItem) -> [String] {
        let collections = library?.collections ?? []
        return item.collections.compactMap { key in collections.first { $0.key == key }?.name }
    }

    private func paperID(for item: AcademicItem) -> String? {
        guard let client, let library else { return nil }
        return AcademicPaperIndex.paperID(item: item.key, library: library, scope: client.serverScope)
    }

    // MARK: - Actions

    private func select(_ item: AcademicItem) {
        openError = nil
        if let id = paperID(for: item) {
            onOpen(.paper(id))
        } else {
            confirmItem = item
        }
    }

    /// `academic_select`: returns the item's paper, creating it (and starting
    /// preparation) the first time. Remembered, so reopening skips the call —
    /// it refetches the whole library from Zotero first.
    private func open(_ item: AcademicItem) async {
        guard let client, let library, openingItem == nil else { return }
        openingItem = item.key
        defer { openingItem = nil }
        do {
            let paper = try await client.academicSelect(
                itemKey: item.key,
                preferences: AcademicPreferences.forResearchAgent(settings?.agentType)
            )
            AcademicPaperIndex.remember(paper: paper.id, item: item.key, library: library, scope: client.serverScope)
            onOpen(.paper(paper.id))
        } catch {
            guard !Task.isCancelled else { return }
            openError = (error as? APIError)?.displayMessage ?? error.localizedDescription
        }
    }

    private func load() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let current = try await client.academicSettings()
            settings = current
            guard current.paired else { return }
            library = try await client.academicLibrary()
            loadError = nil
        } catch let error as APIError where error.isUnsupportedEndpoint {
            unsupported = true
        } catch {
            guard !Task.isCancelled else { return }
            loadError = (error as? APIError)?.displayMessage ?? error.localizedDescription
        }
    }
}

private struct AcademicItemRow: View {
    let item: AcademicItem
    let collections: [String]
    let isPrepared: Bool
    let isOpening: Bool

    var body: some View {
        GroupedRow(vInset: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.title.isEmpty ? item.key : item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if !item.authors.isEmpty {
                        Text(verbatim: AcademicFormat.authors(item.authors))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    if !collections.isEmpty {
                        Text(verbatim: collections.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isOpening {
                    ProgressView().controlSize(.small)
                } else if isPrepared {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ReferencePalette.commit)
                        .accessibilityLabel("Prepared")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
            }
        }
    }
}

enum AcademicFormat {
    /// Up to three authors, then "et al.".
    static func authors(_ authors: [String]) -> String {
        authors.count > 3 ? authors.prefix(3).joined(separator: ", ") + " et al." : authors.joined(separator: ", ")
    }
}

/// The research agent's mode and config for a select / prepare: whatever was
/// last chosen for that agent in a session (the web sends its composer prefs
/// the same way). Nil for an agent the app doesn't know, letting the server
/// use the configured agent's defaults.
enum AcademicPreferences {
    static func forResearchAgent(_ agentType: String?) -> AcademicAgentPreferences? {
        guard let agentType, let agent = AgentType(rawValue: agentType) else { return nil }
        let prefs = SelectorPrefsStore.prefs(for: agent)
        return AcademicAgentPreferences(
            agentType: agentType,
            modeId: prefs.modeId,
            configValues: prefs.configValues ?? [:]
        )
    }
}

/// Which paper each library item became, per server — so reopening an item
/// fetches the paper directly instead of `academic_select`, which refetches
/// the whole library from Zotero first.
enum AcademicPaperIndex {
    private static let key = "codeg.academic.paperIndex.v1"

    static func paperID(item: String, library: AcademicLibrary, scope: String) -> String? {
        all()[entry(item, library, scope)]
    }

    static func remember(paper: String, item: String, library: AcademicLibrary, scope: String) {
        var map = all()
        map[entry(item, library, scope)] = paper
        UserDefaults.standard.set(map, forKey: key)
    }

    static func forget(paper: String) {
        let map = all().filter { $0.value != paper }
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func entry(_ item: String, _ library: AcademicLibrary, _ scope: String) -> String {
        "\(scope)|\(library.instanceId)|\(library.libraryId)|\(item)"
    }
}

// MARK: - Settings

/// Pairing with the Zotero plugin, and the agent that prepares papers.
struct AcademicSettingsSheet: View {
    let client: CodegClient
    let settings: AcademicSettings?
    let onSaved: (AcademicSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var agentType: String
    @State private var port: String
    @State private var token = ""
    @State private var agents: [AgentType] = []
    @State private var isSaving = false
    @State private var error: String?

    init(client: CodegClient, settings: AcademicSettings?, onSaved: @escaping (AcademicSettings) -> Void) {
        self.client = client
        self.settings = settings
        self.onSaved = onSaved
        _agentType = State(initialValue: settings?.agentType ?? AgentType.codex.rawValue)
        _port = State(initialValue: String(settings?.bridgePort ?? 23119))
    }

    private var isPaired: Bool { settings?.paired ?? false }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        EditorSection(
                            title: "Research Agent",
                            footer: "Prepares papers: finds the PDF, analyzes it and verifies its code repository."
                        ) {
                            FieldRow(label: "Agent") {
                                Picker(selection: $agentType) {
                                    ForEach(agentChoices, id: \.rawValue) { agent in
                                        Text(verbatim: agent.displayName).tag(agent.rawValue)
                                    }
                                } label: {
                                    EmptyView()
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                        }
                        EditorSection(
                            title: "Zotero Bridge",
                            footer: isPaired
                                ? LocalizedStringKey("Paired. Enter a new token only to re-pair.")
                                : LocalizedStringKey("Install the Codeg Bridge plugin in Zotero on the server’s computer, then paste the pairing token it shows.")
                        ) {
                            FieldRow(label: "Port") {
                                TextField("23119", text: $port)
                                    .font(.mono(15))
                                    .keyboardType(.numberPad)
                            }
                            Divider().overlay(Theme.hairline)
                            FieldRow(label: "Pairing Token") {
                                SecureField(isPaired ? LocalizedStringKey("Unchanged") : LocalizedStringKey("Required"), text: $token)
                                    .font(.mono(15))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
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
            .navigationTitle("Zotero Settings")
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
            .task { await loadAgents() }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
    }

    /// Installed, enabled agents, plus the configured one even if it isn't.
    private var agentChoices: [AgentType] {
        var choices = agents
        if let current = AgentType(rawValue: agentType), !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    private var portNumber: Int? {
        Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    private var canSave: Bool {
        !isSaving && portNumber != nil && (isPaired || !token.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func loadAgents() async {
        guard let list = try? await client.listAgents() else { return }
        var seen: [AgentType] = []
        for agent in list.filter({ $0.available && $0.enabled }).sorted(by: { $0.sortOrder < $1.sortOrder })
        where !seen.contains(agent.agentType) {
            seen.append(agent.agentType)
        }
        agents = seen
    }

    private func save() async {
        guard let port = portNumber else { return }
        let trimmedToken = token.trimmingCharacters(in: .whitespaces)
        isSaving = true
        error = nil
        do {
            let saved = try await client.setAcademicSettings(
                agentType: agentType,
                bridgePort: port,
                token: trimmedToken.isEmpty ? nil : trimmedToken
            )
            isSaving = false
            onSaved(saved)
            dismiss()
        } catch {
            isSaving = false
            var message = (error as? APIError)?.displayMessage ?? error.localizedDescription
            if !trimmedToken.isEmpty { message = message.replacingOccurrences(of: trimmedToken, with: "••••••") }
            self.error = message
        }
    }
}

// MARK: - Import

/// Add a paper to a Zotero collection by arXiv identifier or DOI.
struct AcademicImportSheet: View {
    let client: CodegClient
    let collections: [AcademicCollection]
    let onImported: (AcademicItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var collectionKey: String
    @State private var isImporting = false
    @State private var error: String?

    init(client: CodegClient, collections: [AcademicCollection], defaultCollection: String?,
         onImported: @escaping (AcademicItem) -> Void) {
        self.client = client
        self.collections = collections
        self.onImported = onImported
        let sorted = collections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        _collectionKey = State(initialValue: defaultCollection ?? sorted.first?.key ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        EditorSection(
                            title: "Paper",
                            footer: "An arXiv identifier or URL, or a DOI. The paper is added to Zotero, then prepared."
                        ) {
                            FieldRow(label: "Identifier") {
                                TextField("2401.12345 or 10.1000/xyz", text: $identifier)
                                    .font(.mono(15))
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                            }
                            Divider().overlay(Theme.hairline)
                            FieldRow(label: "Collection") {
                                Picker(selection: $collectionKey) {
                                    ForEach(collections.sorted {
                                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                                    }) { collection in
                                        Text(verbatim: collection.name).tag(collection.key)
                                    }
                                } label: {
                                    EmptyView()
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
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
            }
            .navigationTitle("Add Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                        .disabled(isImporting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryGlassButton(title: "Add to Zotero", systemImage: "plus", isLoading: isImporting) {
                    Task { await importPaper() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
                .disabled(isImporting || identifier.trimmingCharacters(in: .whitespaces).isEmpty || collectionKey.isEmpty)
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isImporting)
    }

    private func importPaper() async {
        isImporting = true
        error = nil
        do {
            let item = try await client.academicImport(
                identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                collectionKey: collectionKey
            )
            isImporting = false
            dismiss()
            onImported(item)
        } catch {
            isImporting = false
            self.error = (error as? APIError)?.displayMessage ?? error.localizedDescription
        }
    }
}
