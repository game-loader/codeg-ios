import SwiftUI

private struct ConversationTagsModelKey: EnvironmentKey {
    static let defaultValue: ConversationTagsModel? = nil
}

private struct ConversationTagFilterKey: EnvironmentKey {
    static let defaultValue: SessionTagFilter? = nil
}

extension EnvironmentValues {
    /// Optional so previews and hosts without a saved client remain usable.
    var conversationTagsModel: ConversationTagsModel? {
        get { self[ConversationTagsModelKey.self] }
        set { self[ConversationTagsModelKey.self] = newValue }
    }

    var conversationTagFilter: SessionTagFilter? {
        get { self[ConversationTagFilterKey.self] }
        set { self[ConversationTagFilterKey.self] = newValue }
    }
}

struct ConversationTagChip: View {
    let tag: ConversationTagDetail

    private var tint: Color { Color(hexString: tag.color) ?? Theme.accent }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(verbatim: tag.name).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct ConversationTagChips: View {
    let tagIDs: [Int]
    let model: ConversationTagsModel

    private var tags: [ConversationTagDetail] {
        let ids = Set(tagIDs)
        return model.tags.filter { ids.contains($0.id) }
    }

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3)) { tag in
                    ConversationTagChip(tag: tag)
                }
                if tags.count > 3 {
                    Text(verbatim: "+\(tags.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("\(tags.count - 3) more tags")
                }
            }
            .accessibilityIdentifier("conversation.tags.chips")
        }
    }
}

struct ConversationTagsNotice: View {
    let model: ConversationTagsModel

    var body: some View {
        if model.isRetired {
            Label("This server configuration has changed. Reopen tags from its workspace.",
                  systemImage: "server.rack")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        } else if model.isUnsupported {
            Label("Tags require Codeg Server v0.35.1 or later. Tag filtering has been cleared.",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        } else if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: error).font(.footnote).foregroundStyle(Theme.danger)
                Button("Retry") { Task { await model.load() } }
                    .disabled(model.isBusy || model.isLoading)
            }
        } else if model.isLoading {
            ProgressView("Loading tags…")
        }
    }
}

struct ConversationTagScopeLabel: View {
    let folderID: Int?
    let folders: [FolderDetail]

    var body: some View {
        if let folderID, let folder = folders.first(where: { $0.id == folderID }) {
            Text(verbatim: folder.displayName)
        } else if folderID == nil {
            Text("Global Tags")
        } else {
            Text("Unavailable Folder")
        }
    }
}

struct ConversationTagSelectionRow: View {
    let tag: ConversationTagDetail
    let folders: [FolderDetail]
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    ConversationTagChip(tag: tag)
                    ConversationTagScopeLabel(folderID: tag.folderId, folders: folders)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("conversation.tag.\(tag.id)")
    }
}
