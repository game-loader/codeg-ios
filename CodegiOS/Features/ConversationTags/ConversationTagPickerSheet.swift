import SwiftUI

/// Tracks only edits made in the picker. Unknown/out-of-scope assignments and
/// concurrent changes to untouched tags are preserved by the server's deltas.
struct ConversationTagAssignmentSelection {
    let initialIDs: Set<Int>
    private(set) var selectedIDs: Set<Int>

    init(tagIDs: [Int]) {
        initialIDs = Set(tagIDs)
        selectedIDs = initialIDs
    }

    mutating func toggle(_ tagID: Int) {
        if !selectedIDs.insert(tagID).inserted { selectedIDs.remove(tagID) }
    }

    func delta(availableIDs: Set<Int>) -> (add: [Int], remove: [Int]) {
        (selectedIDs.subtracting(initialIDs).intersection(availableIDs).sorted(),
         initialIDs.subtracting(selectedIDs).intersection(availableIDs).sorted())
    }
}

struct ConversationTagPickerSheet: View {
    let model: ConversationTagsModel
    let conversation: ConversationSummary
    let location: String
    let onAssigned: (ConversationSummary) async -> Void
    @State private var folders: [FolderDetail] = []
    @State private var selection: ConversationTagAssignmentSelection
    @State private var hasLoadedFolders = false
    @State private var folderError: String?
    @State private var assignmentError: String?
    @State private var isSaving = false
    @State private var showManager = false
    @Environment(\.dismiss) private var dismiss

    init(model: ConversationTagsModel, conversation: ConversationSummary,
         location: String, onAssigned: @escaping (ConversationSummary) async -> Void) {
        self.model = model
        self.conversation = conversation
        self.location = location
        self.onAssigned = onAssigned
        _selection = State(initialValue: ConversationTagAssignmentSelection(tagIDs: conversation.tagIds))
    }

    private var availableTags: [ConversationTagDetail] {
        model.availableTags(folderID: conversation.folderId, folders: folders)
    }

    private var changes: (add: [Int], remove: [Int]) {
        selection.delta(availableIDs: Set(availableTags.map(\.id)))
    }

    private var unavailable: Bool {
        model.isUnsupported || model.isRetired || model.isBusy || isSaving
    }

    private var canSave: Bool {
        hasLoadedFolders && !unavailable && !model.isLoading
            && (!changes.add.isEmpty || !changes.remove.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(location, systemImage: "server.rack").font(.caption)
                    (conversation.trimmedTitle.map { Text(verbatim: $0) } ?? Text("Untitled session"))
                    ConversationTagsNotice(model: model)
                    folderNotice
                    if let assignmentError {
                        Text(LocalizedStringKey(assignmentError)).font(.footnote).foregroundStyle(Theme.danger)
                    }
                }
                Section {
                    if availableTags.isEmpty, !model.isLoading, hasLoadedFolders, !model.isUnsupported, !model.isRetired {
                        Text("No tags are available for this session.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(availableTags) { tag in
                        ConversationTagSelectionRow(tag: tag, folders: folders,
                                                    isSelected: selection.selectedIDs.contains(tag.id)) {
                            selection.toggle(tag.id)
                        }
                        .disabled(unavailable || !hasLoadedFolders)
                    }
                } header: {
                    Text("Session Tags")
                } footer: {
                    Text("Choose global tags or tags for this session's root folder.")
                }
                Section {
                    Button("Manage Tags") { showManager = true }
                        .disabled(unavailable || !hasLoadedFolders)
                }
            }
            .navigationTitle("Session Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("conversation.tags.assign")
                }
            }
        }
        .task {
            await model.load()
            await loadFolders()
        }
        .sheet(isPresented: $showManager) {
            ConversationTagManagerView(model: model, folders: folders, location: location)
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var folderNotice: some View {
        if !hasLoadedFolders {
            ProgressView("Loading tag scopes…")
        } else if let folderError {
            Text("Folder scopes could not be loaded. Only global tags are available.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            Text(verbatim: folderError).font(.caption).foregroundStyle(Theme.danger)
            Button("Retry Folder Scopes") { Task { await loadFolders() } }
                .disabled(unavailable)
        }
    }

    private func loadFolders() async {
        guard !model.isRetired else { return }
        do {
            let loaded = try await model.client.listFolders()
            guard !Task.isCancelled, !model.isRetired else { return }
            folders = loaded
            model.updateFolders(loaded)
            folderError = nil
            hasLoadedFolders = true
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, !model.isRetired else { return }
            folderError = error.localizedDescription
            hasLoadedFolders = true
        }
    }

    private func save() {
        guard canSave else { return }
        let delta = changes
        let capturedID = conversation.id
        isSaving = true
        assignmentError = nil
        Task {
            guard let summary = await model.assign(conversationID: capturedID,
                                                   add: delta.add, remove: delta.remove) else {
                isSaving = false
                return
            }
            guard summary.id == capturedID else {
                assignmentError = "The server returned a different session. Reopen the tag picker."
                isSaving = false
                return
            }
            await onAssigned(summary)
            NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
            isSaving = false
            dismiss()
        }
    }
}
