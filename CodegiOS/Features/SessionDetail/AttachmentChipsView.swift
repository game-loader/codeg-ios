import SwiftUI

/// A horizontal strip of image thumbnails and document chips above the composer.
struct AttachmentChipsView: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void
    let onRetry: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        attachment: attachment,
                        onRemove: { onRemove(attachment.id) },
                        onRetry: { onRetry(attachment.id) }
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void
    let onRetry: () -> Void

    private static let side: CGFloat = 56
    @ScaledMetric(relativeTo: .caption) private var fileHeight: CGFloat = 116
    @ScaledMetric(relativeTo: .caption2) private var statusHeight: CGFloat = 36

    @ViewBuilder
    var body: some View {
        if attachment.isImage {
            imageChip
        } else {
            fileChip
        }
    }

    private var imageChip: some View {
        thumbnail
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm)
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Remove attachment")
            }
    }

    private var fileChip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: fileSymbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: attachment.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove attachment")
            }
            Spacer(minLength: 0)
            fileStatus
                .font(.caption2)
                .frame(height: statusHeight)
        }
        .padding(8)
        .frame(width: 224, height: fileHeight, alignment: .topLeading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var fileStatus: some View {
        if attachment.uploadFailure != nil {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.danger)
                    .accessibilityHidden(true)
                Text(verbatim: uploadFailureText)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: statusHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tint(Theme.accent)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Retry attachment upload")
            }
        } else if attachment.isReady {
            Label("Ready", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.textSecondary)
        } else if let progress = attachment.uploadProgress {
            let fraction = progress.isFinite ? min(max(progress, 0), 1) : 0
            HStack(spacing: 6) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .accessibilityLabel("Uploading attachment")
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
                Text("Waiting to upload…")
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var uploadFailureText: String {
        // Show the model's fixed, localized reasons; never surface an unknown
        // provider/transport diagnostic that could contain a private URL.
        let knownFailures = [
            String(localized: "Authentication failed. Check the server token and retry."),
            String(localized: "File exceeds the server upload limit."),
            String(localized: "The server upload storage is full."),
            String(localized: "Upload failed. Check your connection and retry."),
            String(localized: "Upload interrupted. Retry when ready.")
        ]
        return knownFailures.first { $0 == attachment.uploadFailure } ?? String(localized: "Upload failed")
    }

    private var fileSymbol: String {
        let mime = attachment.mimeType.lowercased()
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff"].contains(ext) { return "photo" }
        if mime == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if mime.hasPrefix("audio/") || ["mp3", "wav", "m4a", "flac", "aac"].contains(ext) { return "waveform" }
        if mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "webm"].contains(ext) { return "film" }
        if mime.contains("zip") || mime.contains("compressed") || ["zip", "gz", "tar", "rar", "7z"].contains(ext) { return "doc.zipper" }
        if mime.contains("spreadsheet") || mime.contains("excel") || mime == "text/csv" || ["csv", "xls", "xlsx", "xlsm", "xlsb", "numbers"].contains(ext) { return "tablecells" }
        if mime.contains("presentation") || ["ppt", "pptx", "key"].contains(ext) { return "rectangle.on.rectangle" }
        if mime.contains("wordprocessing") || ["doc", "docx", "rtf", "pages"].contains(ext) { return "doc.richtext" }
        if mime.contains("json") || mime.contains("xml") || ["swift", "py", "js", "ts", "html", "css", "rs", "go", "c", "cpp", "h", "sh", "yml", "yaml"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if mime.hasPrefix("text/") || ["txt", "md", "log"].contains(ext) { return "doc.text" }
        return "doc"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
