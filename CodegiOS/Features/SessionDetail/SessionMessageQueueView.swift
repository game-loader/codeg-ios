import SwiftUI

/// Drafts awaiting delivery and server feedback receipts, pinned above the composer.
/// Delivery and draft restoration stay owned by the session model.
struct SessionMessageQueueView: View {
    let queuedMessages: [QueuedSessionMessage]
    let feedbackNotes: [SessionFeedback]
    let isRunning: Bool
    let usesToolBoundaryDelivery: Bool
    let onRemove: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onRestoreFeedback: (String) -> Void
    let onDismissFeedback: (String) -> Void

    @State private var contentHeight: CGFloat = 0
    private static let maxHeight: CGFloat = 180

    private func waitingStatus(_ message: QueuedSessionMessage) -> LocalizedStringKey {
        if !isRunning { return "Queued" }
        return usesToolBoundaryDelivery && message.canSteer ? "After next tool call" : "After this reply"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(queuedMessages) { message in
                    queuedRow(message)
                    if message.id != queuedMessages.last?.id || !feedbackNotes.isEmpty {
                        Divider().overlay(Theme.hairline)
                    }
                }
                ForEach(feedbackNotes) { note in
                    feedbackRow(note)
                    if note.id != feedbackNotes.last?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // Match the interactive cards: fit short content and scroll only on overflow.
        .frame(height: min(max(contentHeight, 1), Self.maxHeight))
        .scrollBounceBehavior(.basedOnSize)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued messages and feedback")
    }

    private func queuedRow(_ message: QueuedSessionMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Localize the image-only fallback in the view's current locale.
            if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Image message")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Text(verbatim: message.previewText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
            if !message.attachments.isEmpty {
                Label("Images: \(message.attachments.count)", systemImage: "photo.on.rectangle")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let failure = message.failure, !message.isSending {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                queueStatus(message)
                    .font(.caption2)
                Spacer(minLength: 0)
                if message.failure != nil {
                    Button("Retry") { onRetry(message.id) }
                        .frame(minHeight: 44)
                        .opacity(message.isSending ? 0.5 : 1)
                } else if !isRunning {
                    Button("Send") { onRetry(message.id) }
                        .frame(minHeight: 44)
                }
                Button { onRemove(message.id) } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove queued message")
                .opacity(message.isSending ? 0.5 : 1)
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .tint(Theme.accent)
            .foregroundStyle(Theme.accent)
            .disabled(message.isSending)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func queueStatus(_ message: QueuedSessionMessage) -> some View {
        if message.isSending {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
                Text("Sending…")
            }
            .foregroundStyle(Theme.textSecondary)
        } else if message.failure != nil {
            Label("Send failed", systemImage: "exclamationmark.circle")
                .foregroundStyle(Theme.danger)
        } else {
            Label(waitingStatus(message), systemImage: "clock")
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func feedbackRow(_ note: SessionFeedback) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: note.text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                feedbackStatus(note)
                    .font(.caption2)
                Spacer(minLength: 0)
                if note.status == "pending", !isRunning {
                    Button("Restore") { onRestoreFeedback(note.id) }
                        .frame(minHeight: 44)
                        .accessibilityLabel("Restore to composer")
                }
                Button { onDismissFeedback(note.id) } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss feedback")
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .tint(Theme.accent)
            .foregroundStyle(Theme.accent)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func feedbackStatus(_ note: SessionFeedback) -> some View {
        if note.status == "delivered" {
            Label("Received", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.accent)
        } else if isRunning {
            Label("Waiting to be read", systemImage: "clock")
                .foregroundStyle(Theme.textSecondary)
        } else {
            Label("Not read", systemImage: "envelope.badge")
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
