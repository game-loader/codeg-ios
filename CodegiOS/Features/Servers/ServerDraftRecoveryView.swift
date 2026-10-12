import SwiftUI

struct ServerDraftRecoveryView: View {
    @Bindable var registry: ServerWorkspaceRegistry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Text("Drafts from replaced or removed servers are read-only. Copy them before deleting a recovery record.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                ForEach(registry.recoveredDrafts) { draft in
                    Section {
                        Text(draft.text).textSelection(.enabled)
                        ShareLink(item: draft.text) { Label("Export Draft", systemImage: "square.and.arrow.up") }
                        Button("Delete Recovery Record", role: .destructive) { registry.discardRecovery(draft.id) }
                    } header: { Text(draft.serverName) }
                    footer: { Text(draft.endpoint) }
                }
            }
            .navigationTitle("Recovered Drafts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
