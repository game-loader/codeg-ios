import Foundation

/// Server-owned feedback IDs make snapshot/event merging replay-safe.
struct SessionFeedback: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let text: String
    var status: String
}

/// A complete draft retained until the server accepts it. A failed/uncertain
/// delivery requires an explicit retry, because feedback POSTs aren't idempotent.
struct QueuedSessionMessage: Identifiable {
    let id = UUID()
    let text: String
    let attachments: [Attachment]
    var isSending = false
    var failure: String?

    var previewText: String {
        guard text.isEmpty else { return text }
        return attachments.contains { !$0.isImage }
            ? String(localized: "File message")
            : String(localized: "Image message")
    }

    var steeringText: String { previewText }
    var canSteer: Bool {
        // @Agent routing is applied by acp_prompt, not the feedback endpoint.
        // Keep delegation drafts (and oversized notes) for ordinary delivery.
        attachments.allSatisfy(\.isReady)
            && !text.contains("codeg://agent/")
            && steeringText.unicodeScalars.count <= 4096
    }
    var blocks: [PromptInputBlock] {
        (text.isEmpty ? [] : [.text(text)]) + attachments.compactMap(\.promptInputBlock)
    }
}
