import Foundation

struct UploadedAttachment: Decodable, Hashable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let mimeType: String?

    /// Encode the server's path, independent of the client's POSIX filesystem.
    /// Percent signs, fragments, queries, spaces and Unicode are always escaped.
    var fileURI: String {
        let windows = Self.isDrivePath(path) || path.hasPrefix("\\\\")
        let normalized = windows ? path.replacingOccurrences(of: "\\", with: "/") : path
        if normalized.hasPrefix("//") {
            let parts = normalized.dropFirst(2).split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return "" }
            return "file://" + Self.percentEncode(String(parts[0]), slashes: false)
                + "/" + Self.percentEncode(String(parts[1]))
        }
        return "file://" + (Self.isDrivePath(normalized) ? "/" : "") + Self.percentEncode(normalized)
    }

    private static func isDrivePath(_ path: String) -> Bool {
        path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        if isDrivePath(path) { return true }
        if path.hasPrefix("\\\\") || path.hasPrefix("//") {
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            return normalized.dropFirst(2).split(separator: "/").count >= 3
        }
        return path.hasPrefix("/") && path.count > 1
    }

    private static func percentEncode(_ value: String, slashes: Bool = true) -> String {
        value.utf8.map { byte -> String in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: return String(UnicodeScalar(byte))
            case 47, 58:
                return slashes ? String(UnicodeScalar(byte)) : String(format: "%%%02X", Int(byte))
            default: return String(format: "%%%02X", Int(byte))
            }
        }.joined()
    }
}

extension UploadedAttachment {
    // An extension preserves the memberwise initializer for queue/test fixtures.
    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case path, name, size, mimeType }
        let values = try decoder.container(keyedBy: Keys.self)
        path = try values.decode(String.self, forKey: .path)
        name = try values.decode(String.self, forKey: .name)
        size = try values.decode(Int64.self, forKey: .size)
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType)
        guard Self.isAbsolutePath(path), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              size > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "upload_attachment returned invalid file metadata"))
        }
    }
}

protocol AttachmentUploadAPI: Sendable {
    func uploadAttachment(file: StagedAttachmentFile, sessionID: String?,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedAttachment
}

extension CodegClient: AttachmentUploadAPI {
    func uploadAttachment(file: StagedAttachmentFile, sessionID: String?,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedAttachment {
        try Task.checkCancellation()
        let payload = try AttachmentMultipartFile(file: file, sessionID: sessionID)
        defer {
            payload.remove()
            withExtendedLifetime(file) {}
        }

        // URLSession.configuration returns a copy: retain injected protocols,
        // TLS/proxy settings, etc. without changing the client's shared session.
        let configuration = Self.attachmentUploadConfiguration(from: session)
        let delegate = AttachmentUploadDelegate(progress: progress)
        let uploadSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { uploadSession.invalidateAndCancel() }

        var request = URLRequest(url: baseURL.appendingPathComponent("api").appendingPathComponent("upload_attachment"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutIntervalForRequest
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(payload.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(payload.size), forHTTPHeaderField: "Content-Length")
        delegate.report(0)

        let data: Data
        let response: URLResponse
        do {
            // One attempt, with a disk-backed body. The async API cancels the
            // underlying task when its calling Swift task is cancelled.
            (data, response) = try await uploadSession.upload(for: request, fromFile: payload.url, delegate: delegate)
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("Malformed response") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let parsed = try? CodegJSON.decoder.decode(ServerError.self, from: data)
            let message: String
            if http.statusCode == 413 {
                message = "File exceeds the server upload limit."
            } else if (300..<400).contains(http.statusCode) {
                message = "Attachment upload redirects are not allowed."
            } else {
                message = parsed?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }
            throw APIError.server(status: http.statusCode, code: parsed?.code, message: message,
                                  detail: http.statusCode == 413 ? nil : parsed?.detail)
        }
        let uploaded: UploadedAttachment
        do { uploaded = try CodegJSON.decoder.decode(UploadedAttachment.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
        try Task.checkCancellation()
        delegate.report(1)
        return uploaded
    }

    static func attachmentUploadConfiguration(from session: URLSession) -> URLSessionConfiguration {
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = max(configuration.timeoutIntervalForRequest, 120)
        configuration.timeoutIntervalForResource = max(configuration.timeoutIntervalForResource, 3_600)
        return configuration
    }
}

/// A separate temp owner for the multipart envelope. Cleanup is explicit in the
/// upload's defer and on constructor failure; deinit is an additional fallback.
final class AttachmentMultipartFile {
    let url: URL
    let boundary: String
    let size: Int64
    private let directory: URL

    init(file: StagedAttachmentFile, sessionID: String?,
         boundary: String = "CodegAttachment-" + UUID().uuidString) throws {
        guard !boundary.isEmpty, boundary.utf8.count <= 70,
              boundary.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 }) else {
            throw AttachmentFileError.unreadableFile
        }
        try Task.checkCancellation()
        let directory = try AttachmentFileIO.makeDirectory(prefix: "CodegMultipart-")
        let url = directory.appendingPathComponent("payload.multipart", isDirectory: false)
        let size: Int64
        do {
            let writer = try AttachmentFileIO.writer(at: url)
            defer { try? writer.close() }
            var header = ""
            if let sessionID {
                header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"session_id\"\r\n\r\n\(sessionID)\r\n"
            }
            header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(Self.filename(file.name))\"\r\n"
            header += "Content-Type: \(Self.safeMIMEType(file.mimeType))\r\n\r\n"
            let headerBytes = Data(header.utf8)
            try writer.write(contentsOf: headerBytes)
            let copied = try AttachmentFileIO.copyContents(from: file.url, to: writer)
            guard copied > 0, copied == file.size else { throw AttachmentFileError.changedFile }
            let footer = Data("\r\n--\(boundary)--\r\n".utf8)
            try writer.write(contentsOf: footer)
            try writer.close()
            try Task.checkCancellation()
            size = Int64(headerBytes.count) + copied + Int64(footer.count)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.boundary = boundary
        self.directory = directory
        self.url = url
        self.size = size
    }

    private static func filename(_ name: String) -> String {
        // RFC 7578 percent escaping keeps UTF-8 and the filename extension while
        // preventing quoted-string termination and CR/LF header injection.
        name.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0...31, 34, 47, 92, 127: return String(format: "%%%02X", Int(scalar.value))
            default: return String(scalar)
            }
        }.joined()
    }

    private static func safeMIMEType(_ mime: String) -> String {
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        let tokens = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(tokens.contains) }) else {
            return "application/octet-stream"
        }
        return mime
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { remove() }
}

final class AttachmentUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSRecursiveLock()
    private var lastProgress: Double = -1

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
        super.init()
    }

    func report(_ value: Double) {
        guard value.isFinite else { return }
        let value = min(1, max(0, value))
        lock.lock()
        defer { lock.unlock() }
        guard value > lastProgress else { return }
        lastProgress = value
        // Serialize delivery too, so completion cannot overtake a delegate
        // callback. A recursive lock also permits a reentrant observer.
        progress(value)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        // Reserve 1 for a successfully decoded acknowledgement.
        report(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward credentials or resend the POST, even to the same origin.
        completionHandler(nil)
    }
}
