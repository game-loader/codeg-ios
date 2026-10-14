import SwiftUI

/// The model and selection belong to the initiating workspace, independent of
/// whichever pane or server is focused while this sheet is visible.
struct ConversationTagFilterSheet: View {
    let model: ConversationTagsModel
    @Bindable var filter: SessionTagFilter
    let folders: [FolderDetail]
    let location: String
    @Environment(\.dismiss) private var dismiss
    @State private var showManager = false

    private var unavailable: Bool { model.isUnsupported || model.isRetired }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(location, systemImage: "server.rack")
                        .font(.caption)
                    ConversationTagsNotice(model: model)
                }
                Section("Match Tags") {
                    Picker("Match Tags", selection: $filter.mode) {
                        Text("Any Selected Tag").tag(SessionTagFilter.MatchMode.any)
                        Text("All Selected Tags").tag(SessionTagFilter.MatchMode.all)
                    }
                    .pickerStyle(.segmented)
                    .disabled(unavailable)
                    .accessibilityIdentifier("conversation.tags.matchMode")
                    Button("Clear Tag Filter") { filter.clear() }
                        .disabled(!filter.isActive)
                }
                Section {
                    if model.tags.isEmpty, !model.isLoading, !unavailable {
                        Text("No tags yet. Create one in Manage Tags.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(model.tags) { tag in
                        ConversationTagSelectionRow(tag: tag, folders: folders,
                                                    isSelected: filter.selectedIDs.contains(tag.id)) {
                            if !filter.selectedIDs.insert(tag.id).inserted {
                                filter.selectedIDs.remove(tag.id)
                            }
                        }
                        .disabled(unavailable || model.isBusy)
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Tag filters are kept on this device for this server workspace.")
                }
                Section {
                    Button("Manage Tags") { showManager = true }
                        .disabled(model.isRetired)
                }
            }
            .navigationTitle("Filter by Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showManager) {
            ConversationTagManagerView(model: model, folders: folders, location: location)
        }
        .presentationDragIndicator(.visible)
    }
}
