import SwiftUI

struct ConversationTagManagerView: View {
    let model: ConversationTagsModel
    let location: String
    @State private var folders: [FolderDetail]
    @State private var folderError: String?
    @State private var editor: TagEditorRequest?
    @State private var deleting: ConversationTagDetail?
    @Environment(\.dismiss) private var dismiss

    init(model: ConversationTagsModel, folders: [FolderDetail], location: String) {
        self.model = model
        self.location = location
        _folders = State(initialValue: folders)
    }

    private var unavailable: Bool { model.isUnsupported || model.isRetired || model.isBusy }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(location, systemImage: "server.rack").font(.caption)
                    ConversationTagsNotice(model: model)
                    if let folderError {
                        Text(verbatim: folderError).font(.footnote).foregroundStyle(Theme.danger)
                        Button("Retry Folder Scopes") { Task { await loadFolders() } }
                    }
                }
                Section {
                    if model.tags.isEmpty, !model.isLoading, !model.isUnsupported, !model.isRetired {
                        Text("No tags yet. Create a global tag or a tag for a root folder.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(model.tags) { tag in
                        managerRow(tag)
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Global tags are available everywhere on this server. Folder tags also apply to its worktrees.")
                }
                Section {
                    Button {
                        editor = TagEditorRequest(tag: nil)
                    } label: {
                        Label("Create Tag", systemImage: "plus")
                    }
                    .disabled(unavailable || model.isLoading)
                    .accessibilityIdentifier("conversation.tags.create")
                }
            }
            .navigationTitle("Manage Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await model.load() }
        }
        .task {
            if folders.isEmpty { await loadFolders() }
            else { model.updateFolders(folders) }
            await model.load()
        }
        .sheet(item: $editor) { request in
            ConversationTagEditorSheet(model: model, editing: request.tag,
                                       folders: folders, location: location)
        }
        .alert("Delete Tag?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { tag in
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { deleteConfirmedTag(tag) }
        } message: { _ in
            Text("This tag will be removed from all sessions on this server. This can't be undone.")
        }
        .presentationDragIndicator(.visible)
    }

    private func managerRow(_ tag: ConversationTagDetail) -> some View {
        HStack {
            Button {
                editor = TagEditorRequest(tag: tag)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    ConversationTagChip(tag: tag)
                    ConversationTagScopeLabel(folderID: tag.folderId, folders: folders)
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversation.tags.edit.\(tag.id)")
            Button(role: .destructive) { deleting = tag } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete Tag")
            .accessibilityIdentifier("conversation.tags.delete.\(tag.id)")
        }
        .disabled(unavailable)
    }

    private func loadFolders() async {
        do {
            let loaded = try await model.client.listFolders()
            guard !Task.isCancelled, !model.isRetired else { return }
            folders = loaded
            model.updateFolders(loaded)
            folderError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, !model.isRetired else { return }
            folderError = error.localizedDescription
        }
    }

    private func deleteConfirmedTag(_ tag: ConversationTagDetail) {
        guard !unavailable else { deleting = nil; return }
        deleting = nil
        Task {
            if await model.delete(tagID: tag.id) {
                NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
                // Only the subsequent successful full catalog may prune filters.
                await model.load()
            }
        }
    }
}

private struct TagEditorRequest: Identifiable {
    let id = UUID()
    let tag: ConversationTagDetail?
}
