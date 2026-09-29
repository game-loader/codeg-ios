import Foundation
import PDFKit

enum PDFPreviewError: Error, Equatable {
    case tooLarge
    case invalidData
    case invalidPath
}

/// Server paths must use the server's separators, not iOS's path semantics.
/// Normalize only absolute Windows paths; backslashes in POSIX names are literal.
enum PDFServerPath {
    private static func normalized(_ path: String) -> String {
        let drivePath = path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
        if drivePath || path.hasPrefix("\\\\") {
            return path.replacingOccurrences(of: "\\", with: "/")
        }
        return path
    }

    static func name(_ path: String) -> String {
        let path = normalized(path)
        guard let separator = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: separator)...])
    }

    static func directory(_ path: String) -> String {
        let path = normalized(path)
        guard let separator = path.lastIndex(of: "/") else { return "." }
        let parent = String(path[..<separator])
        if parent.isEmpty { return "/" }
        if parent.range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil {
            return parent + "/"
        }
        return parent
    }

    static func relative(_ path: String, to root: String) throws -> String {
        let path = normalized(path)
        let root = normalized(root)
        guard !root.isEmpty else { throw PDFPreviewError.invalidPath }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { throw PDFPreviewError.invalidPath }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else { throw PDFPreviewError.invalidPath }
        return relative
    }
}

/// Owns one bounded, local copy of a server PDF. Reading and sharing retain the
/// same file; releasing its last owner removes only its unique temp directory.
/// All stored properties are immutable, so preparation can run off the UI actor.
final class PDFPreviewFile: Identifiable, Sendable {
    static let maxBytes = 20_000_000
    let url: URL
    private let directory: URL
    var id: URL { url }

    static func matches(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }

    init(base64: String, name: String) throws {
        guard base64.utf8.count <= ((Self.maxBytes + 2) / 3) * 4 else {
            throw PDFPreviewError.tooLarge
        }
        guard let data = Data(base64Encoded: base64), !data.isEmpty else {
            throw PDFPreviewError.invalidData
        }
        guard data.count <= Self.maxBytes else { throw PDFPreviewError.tooLarge }
        try Task.checkCancellation()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodegPDF-" + UUID().uuidString, isDirectory: true)
        let basename = (name as NSString).lastPathComponent
        let filename = Self.matches(basename) ? basename : "Document.pdf"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.url = url
    }

    /// PDFKit parses the file once on the caller's actor; the document is never
    /// passed between actors. Locked PDFs can still be exported to another app.
    func openDocument() throws -> PDFDocument {
        guard let document = PDFDocument(url: url),
              document.isLocked || document.pageCount > 0 else {
            throw PDFPreviewError.invalidData
        }
        return document
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
