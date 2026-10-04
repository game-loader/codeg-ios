import SwiftUI

/// Creates the draft binding inside this leaf, not in the transcript's parent.
/// SwiftUI reads a binding's current value while constructing it; observing the
/// draft here keeps every keyboard/IME edit out of SessionDetailView's body.
struct SessionComposeBar: View {
    @Bindable var model: SessionDetailViewModel

    var body: some View {
        ComposeBar(
            text: $model.draft,
            isInFlight: model.isInFlight || model.isSubmittingPrompt,
            notice: model.notice,
            attachments: model.attachments,
            canAttachMore: model.canAttachMore,
            onAddAttachments: { model.addAttachments($0) },
            onRemoveAttachment: { model.removeAttachment($0) },
            onRetryAttachment: { model.retryAttachment($0) },
            onNotice: { model.notice = $0 },
            onSend: { model.send() },
            onStop: { model.cancel() },
            onDismissNotice: { model.notice = nil },
            insertModel: model.insertModel
        )
    }
}
