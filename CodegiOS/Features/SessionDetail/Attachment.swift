import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// Images retain their compact inline payload. Other files own a local disk
/// copy until uploaded, then send only a reference to the server's copy.
struct Attachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let mimeType: String
    let data: Data
    let file: StagedAttachmentFile?
    var uploaded: UploadedAttachment?
    var uploadProgress: Double?
    var uploadFailure: String?

    init(id: UUID = UUID(), name: String, mimeType: String, data: Data) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.file = nil
    }

    init(id: UUID = UUID(), file: StagedAttachmentFile) {
        self.id = id
        self.name = file.name
        self.mimeType = file.mimeType
        self.data = Data()
        self.file = file
    }

    var byteCount: Int { file.map { Int(clamping: $0.size) } ?? data.count }
    var base64: String { data.base64EncodedString() }
    var isImage: Bool { file == nil }
    var isReady: Bool { file == nil || (uploaded != nil && uploadProgress == nil && uploadFailure == nil) }

    /// The wire block sent in `acp_prompt`.
    var promptInputBlock: PromptInputBlock? {
        if isImage { return .image(data: base64, mimeType: mimeType, uri: nil) }
        guard isReady, let uploaded else { return nil }
        return .resourceLink(uri: uploaded.fileURI, name: uploaded.name, mimeType: uploaded.mimeType ?? mimeType)
    }

    var fileReference: String? {
        guard !isImage, let uploaded else { return nil }
        let label = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(label)](\(uploaded.fileURI))"
    }

    /// Optimistic turns use the same file reference the persisted transcript
    /// renders, while images retain their prepared thumbnail bytes.
    var optimisticBlock: ContentBlock {
        if isImage { return .image(ImageData(data: base64, mimeType: mimeType, uri: nil)) }
        return .text(fileReference ?? name)
    }
}

/// Prepares picked/captured images into compact `Attachment`s: downscales to a
/// sane max dimension and re-encodes large images as JPEG so a full-res photo
/// doesn't become a multi-megabyte base64 blob on the wire.
enum AttachmentPrep {
    static let maxDimension: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.75
    /// Hard cap on a single prepared image (sanity bound; the aggregate budget
    /// below is the binding limit in practice).
    static let maxBytes = 4 * 1024 * 1024
    /// Aggregate cap on the RAW bytes of all staged images. `acp_prompt` rides
    /// Axum's default 2 MiB JSON body limit, and base64 inflates by ~33%, so the
    /// combined payload (base64 + text + JSON overhead) must stay well under
    /// 2 MiB. ~1.3 MB raw → ~1.73 MB base64, leaving comfortable headroom.
    static let maxTotalBytes = 1_300_000
    /// Max simultaneous attachments on one prompt (secondary to the byte budget).
    static let maxCount = 10

    /// File-provider reads and disk copying run off the UI actor. Do not try to
    /// decode arbitrary documents (or large images) into an in-memory bitmap.
    static func makeFile(from url: URL) throws -> Attachment {
        let file = try StagedAttachmentFile.copy(from: url)
        if file.mimeType.hasPrefix("image/"), file.size <= Int64(maxBytes),
           let raw = try? Data(contentsOf: file.url),
           let image = make(fromImageData: raw, name: file.name) {
            return image
        }
        if file.mimeType.hasPrefix("image/"),
           let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
                kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary),
           let image = make(from: UIImage(cgImage: thumbnail), name: file.name) {
            try Task.checkCancellation()
            return image
        }
        return Attachment(file: file)
    }

    /// Prepare an in-memory image (camera capture or Photos pick) as a
    /// downscaled JPEG attachment.
    static func make(from image: UIImage, name: String) -> Attachment? {
        let scaled = downscaled(image, maxDimension: maxDimension)
        guard let data = scaled.jpegData(compressionQuality: jpegQuality), !data.isEmpty else { return nil }
        guard data.count <= maxBytes else { return nil }
        return Attachment(name: name.isEmpty ? defaultName : name, mimeType: "image/jpeg", data: data)
    }

    /// Prepare image bytes (e.g. from `PhotosPickerItem.loadTransferable`).
    /// Returns nil if the bytes aren't a decodable image.
    static func make(fromImageData raw: Data, name: String) -> Attachment? {
        guard let image = UIImage(data: raw) else { return nil }
        // Re-encode through `make(from:)` when oversized or large; otherwise keep
        // the original bytes (preserves PNG transparency, avoids needless recompress)
        // — but ONLY for formats we can positively identify as agent-safe. Anything
        // unrecognized (HEIC/TIFF/…) is re-encoded to JPEG so we never ship bytes
        // under a mislabeled mime type.
        if raw.count > maxBytes || max(image.size.width, image.size.height) > maxDimension {
            return make(from: image, name: name)
        }
        guard let mime = raw.imageMimeType else {
            return make(from: image, name: name)
        }
        return Attachment(name: name.isEmpty ? defaultName : name, mimeType: mime, data: raw)
    }

    /// Prepare an image file chosen via `.fileImporter` (security-scoped URL).
    static func make(fromFile url: URL) -> Attachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let name = url.lastPathComponent
        // Files are filtered to images by the picker, but guard anyway.
        guard UIImage(data: raw) != nil else { return nil }
        return make(fromImageData: raw, name: name)
    }

    private static let defaultName = "image"

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

private extension Data {
    /// Sniff a common image mime type from the file's magic bytes. Operates on a
    /// zero-based byte copy so it's safe regardless of the `Data`'s start index.
    var imageMimeType: String? {
        let bytes = Array(prefix(12))
        guard let first = bytes.first else { return nil }
        switch first {
        case 0x89: return "image/png"
        case 0xFF: return "image/jpeg"
        case 0x47: return "image/gif"
        case 0x52: // "RIFF…WEBP"
            return bytes.count >= 12 && bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) ? "image/webp" : nil
        default: return nil
        }
    }
}
