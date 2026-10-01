import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The pinned bottom compose bar. A leading "+" sits to the left of a growing
/// multiline field; send / queue and Stop controls sit on the right.
/// Attachment chips appear above the field. The "agent is
/// working" state is shown as a node at the tail of the transcript timeline (a
/// thinking tick, a running tool, a streaming reply) — not as a status line here.
///
/// The "+" owns the attachment pickers (Photo Library / Camera / Files) because
/// `PhotosPicker` / `.fileImporter` must be hosted on a view in the bar. (The
/// agent avatar lives in the session's navigation bar, not here.)
struct ComposeBar: View {
    @Binding var text: String
    let isInFlight: Bool
    let notice: String?
    let attachments: [Attachment]
    let canAttachMore: Bool
    let onAddAttachments: ([Attachment]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onRetryAttachment: (UUID) -> Void
    let onNotice: (String) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onDismissNotice: () -> Void
    /// Backs the "+" menu's text-insert pickers (quick messages / experts / commands).
    let insertModel: ComposeInsertModel

    @FocusState private var focused: Bool
    /// Bumped on each send tap to fire a light "sent" impact immediately (rather
    /// than waiting for the turn to start streaming).
    @State private var sendHaptic = 0
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var presentedInsert: ComposeInsertModel.Source?
    @State private var showMachinePicker = false
    @State private var preparingFileCount = 0
    @State private var filePreparationTask: Task<Void, Never>?
    @State private var filePreparationID: UUID?
    @State private var acceptsAttachmentResults = true

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool {
        (hasText || !attachments.isEmpty)
            && preparingFileCount == 0
            && attachments.allSatisfy(\.isReady)
    }
    private var canChooseAttachments: Bool {
        canAttachMore && preparingFileCount == 0
    }
    private var remainingSlots: Int {
        max(0, AttachmentPrep.maxCount - attachments.count)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let notice {
                NoticeBanner(message: notice, onDismiss: onDismissNotice)
            }

            if !attachments.isEmpty {
                AttachmentChipsView(
                    attachments: attachments,
                    onRemove: onRemoveAttachment,
                    onRetry: onRetryAttachment
                )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if preparingFileCount > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                    Text("Preparing files…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            if isInFlight {
                Text("Queue a message without stopping the current task.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    addButton
                    TextField("Message", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(1...6)
                        // Match the transcript body so the text you type reads at
                        // the same size as the reply it produces (was `.callout`,
                        // visibly smaller than the messages).
                        .font(Theme.Typography.messageBody)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .focused($focused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        // `xl` radius clamps to a capsule while the field is one
                        // line (rhyming with the round +/send buttons) and relaxes
                        // to a rounded rect as it grows — no hard switch needed.
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                        .hairlineBorder(Theme.Radius.xl)

                    actionButtons
                }
            }
        }
        // Idle, the bar floats as a narrower pill (36pt side margins) so it reads
        // as a compact resting affordance. Focusing the field (keyboard up) widens
        // it to the transcript's 16pt gutter, so typing gets the same width as the
        // messages it answers. The change animates with the focus transition below.
        .padding(.horizontal, focused ? 16 : 36)
        .padding(.top, 8)
        // Hosted in a bottom `safeAreaInset`. Keyboard DOWN: float a full
        // home-indicator inset (~34pt) above the edge; a small negative bottom
        // padding dips the idle bar lower while staying clear of the indicator
        // line. Keyboard UP: the inset rides just above the keyboard, so a positive
        // gap is required — the old negative pad tucked the bar *under* the
        // keyboard's top edge (part of it was obscured).
        .padding(.bottom, focused ? 8 : -10)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: max(1, remainingSlots),
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoItems) { _, items in handlePhotoItems(items) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in addCaptured(image) }
                .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in handleFiles(result) }
        .sheet(item: $presentedInsert) { source in
            ComposeInsertSheet(source: source, model: insertModel) { transform in
                text = transform(text)
                focused = true
            }
        }
        .sheet(isPresented: $showMachinePicker) {
            MachinePickerSheet(client: insertModel.client) { context in
                text = MachineContext.draft(text, appending: context)
            }
        }
        .onAppear { acceptsAttachmentResults = true }
        .onDisappear {
            acceptsAttachmentResults = false
            cancelFilePreparation()
        }
        .animation(Theme.Motion.expand, value: isInFlight)
        .animation(Theme.Motion.expand, value: notice)
        .animation(Theme.Motion.expand, value: attachments)
        // Width + keyboard-gap shift on focus change, kept just slightly slower
        // than the keyboard's own animation so the bar settles into place.
        .animation(.snappy(duration: 0.26), value: focused)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: sendHaptic)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var addButton: some View {
        Menu {
            // Attach files or images. Disabled while staging or when the budget is full,
            // so the insert actions below stay reachable.
            Section("Attach") {
                Button { showPhotoPicker = true } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                .disabled(!canChooseAttachments)
                if isCameraAvailable {
                    Button { showCamera = true } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    .disabled(!canChooseAttachments)
                }
                Button { showFileImporter = true } label: {
                    Label("Files", systemImage: "folder")
                }
                .disabled(!canChooseAttachments)
            }
            // Insert text: agent mentions, quick messages, experts, commands.
            Section("Insert") {
                ForEach(ComposeInsertModel.Source.allCases) { source in
                    Button { presentedInsert = source } label: {
                        Label(source.title, systemImage: source.systemImage)
                    }
                }
                // A machine's probe as context (the web's `/machine`).
                Button { showMachinePicker = true } label: {
                    Label("Machine…", systemImage: "server.rack")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
        .tint(Theme.textSecondary)
        .accessibilityLabel("Add or insert")
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !isInFlight || hasText || !attachments.isEmpty || preparingFileCount > 0 {
            Button(action: send) {
                Image(systemName: isInFlight ? "text.badge.plus" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .clipShape(Circle())
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.5)
            .transition(.opacity)
            .accessibilityLabel(isInFlight ? Text("Send to queue") : Text("Send"))
        }

        if isInFlight {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.danger)
            .clipShape(Circle())
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Stop")
        }
    }

    private func send() {
        guard canSend else { return }
        sendHaptic &+= 1
        onSend()
    }

    // MARK: - Attachment intake

    private func handlePhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let slots = remainingSlots
        let attempted = items.count
        Task { @MainActor in
            var prepared: [Attachment] = []
            for item in items.prefix(slots) {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                if let attachment = await Task.detached(priority: .userInitiated, operation: {
                    AttachmentPrep.make(fromImageData: data, name: "image")
                }).value {
                    prepared.append(attachment)
                }
            }
            // Notice first so the view model's more specific size/count notice (if
            // any) wins when it also drops some during add.
            if prepared.count < attempted { onNotice("Some images couldn't be added.") }
            if !prepared.isEmpty { onAddAttachments(prepared) }
            photoItems = []
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        guard acceptsAttachmentResults, preparingFileCount == 0 else { return }
        let urls: [URL]
        switch result {
        case .success(let selected):
            urls = selected
        case .failure(let error):
            let failure = error as NSError
            guard !(error is CancellationError),
                  !(failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.Code.userCancelled.rawValue) else { return }
            onNotice(String(localized: "Couldn't open the selected files. Try selecting them again."))
            return
        }
        guard !urls.isEmpty else { return }
        let selected = Array(urls.prefix(remainingSlots))
        guard !selected.isEmpty else {
            onNotice(String(localized: "Some files weren't added because the attachment limit was reached."))
            return
        }

        let preparationID = UUID()
        filePreparationID = preparationID
        preparingFileCount = selected.count
        filePreparationTask = Task { @MainActor in
            defer {
                // An old completion must never clear a newer preparation's state.
                if filePreparationID == preparationID {
                    filePreparationID = nil
                    filePreparationTask = nil
                    preparingFileCount = 0
                }
            }
            var prepared: [Attachment] = []
            var failures: [String] = []
            var omittedFailures = 0
            for url in selected {
                guard !Task.isCancelled, acceptsAttachmentResults,
                      filePreparationID == preparationID else { return }
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    // Staging owns security scope, iCloud coordination and the
                    // regular-file check; identified images keep their image prep.
                    let attachment = try AttachmentPrep.makeFile(from: url)
                    try Task.checkCancellation()
                    return attachment
                }
                do {
                    let attachment = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    guard !Task.isCancelled, acceptsAttachmentResults,
                          filePreparationID == preparationID else { return }
                    prepared.append(attachment)
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError), acceptsAttachmentResults,
                          filePreparationID == preparationID else { return }
                    // Bound the notice to three per-file errors plus summaries.
                    // Never show NSError descriptions/userInfo: providers can
                    // put private URLs and credentials in them.
                    if failures.count < 3 {
                        failures.append(Self.filePreparationFailure(error, name: url.lastPathComponent))
                    } else {
                        omittedFailures += 1
                    }
                }
                preparingFileCount -= 1
            }
            guard !Task.isCancelled, acceptsAttachmentResults,
                  filePreparationID == preparationID else { return }
            if omittedFailures > 0 {
                failures.append(String(localized: "\(omittedFailures) more files couldn't be added."))
            }
            if urls.count > selected.count {
                failures.append(String(localized: "Some files weren't added because the attachment limit was reached."))
            }
            // The model's more specific budget notice takes precedence.
            if !failures.isEmpty { onNotice(failures.joined(separator: "\n")) }
            if !prepared.isEmpty { onAddAttachments(prepared) }
        }
    }

    private func cancelFilePreparation() {
        filePreparationID = nil
        filePreparationTask?.cancel()
        filePreparationTask = nil
        preparingFileCount = 0
    }

    private static func filePreparationFailure(_ error: Error, name: String) -> String {
        if let stagingError = error as? AttachmentFileError {
            switch stagingError {
            case .notARegularFile:
                return String(localized: "Couldn't add “\(name)”. Choose a regular file; folders cannot be attached.")
            case .emptyFile:
                return String(localized: "Couldn't add “\(name)”. The file is empty.")
            case .unreadableFile:
                return String(localized: "Couldn't add “\(name)”. The file couldn't be read. Download it in Files and try again.")
            case .changedFile:
                return String(localized: "Couldn't add “\(name)”. The file changed during preparation. Select it again.")
            }
        }
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain {
            switch failure.code {
            case CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue:
                return String(localized: "Couldn't add “\(name)”. Access to the file was denied.")
            case CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue:
                return String(localized: "Couldn't add “\(name)”. The file is no longer available.")
            case CocoaError.Code.fileReadTooLarge.rawValue:
                return String(localized: "Couldn't add “\(name)”. The file is too large.")
            case CocoaError.Code.fileWriteOutOfSpace.rawValue:
                return String(localized: "Couldn't add “\(name)”. There isn't enough space on this device.")
            default:
                break
            }
        }
        return String(localized: "Couldn't add “\(name)”. Make sure it is a downloaded file and try again.")
    }

    /// Camera capture is a single image and small enough to prep inline on the
    /// main actor (avoids sending a non-Sendable `UIImage` across a task boundary).
    private func addCaptured(_ image: UIImage) {
        guard remainingSlots > 0, let attachment = AttachmentPrep.make(from: image, name: "camera") else { return }
        onAddAttachments([attachment])
    }
}

/// A dismissible non-fatal notice (e.g. "a turn is already running").
private struct NoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.accent.opacity(0.35))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
