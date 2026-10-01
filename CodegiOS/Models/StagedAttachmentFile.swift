import Foundation
import UniformTypeIdentifiers

enum AttachmentFileError: LocalizedError {
    case notARegularFile
    case emptyFile
    case unreadableFile
    case changedFile

    var errorDescription: String? {
        switch self {
        case .notARegularFile: return "Choose a file to attach. Folders cannot be attached."
        case .emptyFile: return "Empty files cannot be attached."
        case .unreadableFile: return "The selected file could not be read."
        case .changedFile: return "The attachment changed while it was being copied. Please attach it again."
        }
    }
}

/// Owns a local copy independently of the document provider. Queue entries can
/// share this reference; only releasing its last owner removes the staged file.
/// Immutable metadata and exclusive ownership of the directory permit Sendable.
final class StagedAttachmentFile: Hashable, Identifiable, @unchecked Sendable {
    let id: UUID
    let url: URL
    let name: String
    let mimeType: String
    let size: Int64
    private let ownerDirectory: URL

    /// Internal ownership-transfer initializer, also useful for sparse test files.
    /// The caller must transfer an exclusive temporary directory containing `url`.
    init(id: UUID = UUID(), url: URL, name: String, mimeType: String,
         size: Int64, ownerDirectory: URL) {
        self.id = id
        self.url = url
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.ownerDirectory = ownerDirectory
    }

    static func == (lhs: StagedAttachmentFile, rhs: StagedAttachmentFile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Synchronous disk work: callers should prepare large files off the UI actor.
    /// Coordination materializes file-provider/iCloud content before reading it;
    /// security-scoped access remains open throughout coordination and copying.
    static func copy(from source: URL) throws -> StagedAttachmentFile {
        try Task.checkCancellation()
        guard source.isFileURL else { throw AttachmentFileError.unreadableFile }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<StagedAttachmentFile, Error>?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges,
                               error: &coordinationError) { readableURL in
            result = Result { try copyCoordinated(from: readableURL, name: source.lastPathComponent) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw AttachmentFileError.unreadableFile }
        try Task.checkCancellation()
        return try result.get()
    }

    private static func copyCoordinated(from source: URL, name: String) throws -> StagedAttachmentFile {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true, values.isRegularFile == true else {
            throw AttachmentFileError.notARegularFile
        }
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw AttachmentFileError.unreadableFile
        }
        if values.fileSize == 0 { throw AttachmentFileError.emptyFile }

        let directory = try AttachmentFileIO.makeDirectory(prefix: "CodegAttachment-")
        do {
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            let writer = try AttachmentFileIO.writer(at: destination)
            defer { try? writer.close() }
            let size = try AttachmentFileIO.copyContents(from: source, to: writer)
            guard size > 0 else { throw AttachmentFileError.emptyFile }
            if let expectedSize = values.fileSize, Int64(expectedSize) != size {
                throw AttachmentFileError.changedFile
            }
            try writer.close()
            try Task.checkCancellation()
            return StagedAttachmentFile(url: destination, name: name,
                                        mimeType: mimeType(for: name), size: size,
                                        ownerDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        // Keep common Excel formats accurate even if a provider reports a generic type.
        switch ext {
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xls": return "application/vnd.ms-excel"
        case "xlsm": return "application/vnd.ms-excel.sheet.macroEnabled.12"
        case "xlsb": return "application/vnd.ms-excel.sheet.binary.macroEnabled.12"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    deinit { try? FileManager.default.removeItem(at: ownerDirectory) }
}

/// Shared bounded disk copying for staging and multipart construction. The
/// autorelease pool bounds Foundation's temporary objects as well as Data buffers.
enum AttachmentFileIO {
    static let chunkSize = 64 * 1024

    static func makeDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    static func writer(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }

    @discardableResult
    static func copyContents(from source: URL, to writer: FileHandle) throws -> Int64 {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        var size: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count: Int = try autoreleasepool {
                guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { return 0 }
                try writer.write(contentsOf: chunk)
                return chunk.count
            }
            if count == 0 { return size }
            size += Int64(count)
        }
    }
}
