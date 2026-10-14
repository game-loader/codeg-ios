import SwiftUI
import UIKit

struct ConversationTagEditorSheet: View {
    let model: ConversationTagsModel
    let editing: ConversationTagDetail?
    let folders: [FolderDetail]
    let location: String
    @State private var name: String
    @State private var color: Color
    @State private var folderID: Int?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(model: ConversationTagsModel, editing: ConversationTagDetail?,
         folders: [FolderDetail], location: String) {
        self.model = model
        self.editing = editing
        self.folders = folders
        self.location = location
        _name = State(initialValue: editing?.name ?? "")
        _color = State(initialValue: Color(hexString: editing?.color ?? "#3b82f6") ?? .blue)
        _folderID = State(initialValue: editing?.folderId)
    }

    private var roots: [FolderDetail] {
        ConversationTagsModel.creationScopes(folders: folders)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedName.isEmpty && !isSaving && !model.isBusy && !model.isRetired && !model.isUnsupported
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(location, systemImage: "server.rack").font(.caption)
                    ConversationTagsNotice(model: model)
                }
                Section("Tag") {
                    TextField("Tag Name", text: $name)
                        .accessibilityIdentifier("conversation.tags.name")
                    ColorPicker("Tag Color", selection: $color, supportsOpacity: false)
                }
                Section {
                    if editing == nil {
                        Picker("Tag Scope", selection: $folderID) {
                            Text("Global Tags").tag(Optional<Int>.none)
                            ForEach(roots) { folder in
                                Text(verbatim: folder.displayName).tag(Optional(folder.id))
                            }
                        }
                        .accessibilityIdentifier("conversation.tags.scope")
                    } else {
                        HStack {
                            Text("Tag Scope")
                            Spacer()
                            ConversationTagScopeLabel(folderID: folderID, folders: folders)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                } footer: {
                    Text("A folder tag is available in that root folder and its worktrees.")
                }
            }
            .disabled(isSaving || model.isRetired)
            .navigationTitle(editing == nil ? Text("Create Tag") : Text("Edit Tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("conversation.tags.save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDragIndicator(.visible)
    }

    private func save() {
        guard canSave else { return }
        let savedName = trimmedName
        let savedColor = Self.hex(color)
        let savedFolderID = folderID
        isSaving = true
        Task {
            let result: ConversationTagDetail?
            if let editing {
                result = await model.update(tagID: editing.id, name: savedName, color: savedColor)
            } else {
                model.updateFolders(folders)
                result = await model.create(name: savedName, color: savedColor, folderID: savedFolderID)
            }
            isSaving = false
            if result != nil { dismiss() }
        }
    }

    private static func hex(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }

    private static func byte(_ component: CGFloat) -> Int {
        Int((min(1, max(0, component)) * 255).rounded())
    }
}
