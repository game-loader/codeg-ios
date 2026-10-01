import Foundation
import XCTest
@testable import Codeg

final class AttachmentUploadTests: XCTestCase {
    func testCopyPreservesMetadataAndLastQueueOwnerControlsLifetime() throws {
        let sourceDirectory = try AttachmentFileIO.makeDirectory(prefix: "AttachmentTest-")
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("数据 #?.xlsx")
        let contents = Data("spreadsheet fixture".utf8)
        try contents.write(to: source)

        var staged: StagedAttachmentFile? = try StagedAttachmentFile.copy(from: source)
        let url = try XCTUnwrap(staged?.url)
        let directory = url.deletingLastPathComponent()
        var queue = [try XCTUnwrap(staged)]
        weak var weakFile = staged
        XCTAssertNotEqual(url, source)
        XCTAssertEqual(queue[0].name, "数据 #?.xlsx")
        XCTAssertEqual(queue[0].mimeType, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertEqual(queue[0].size, Int64(contents.count))
        XCTAssertEqual(try Data(contentsOf: url), contents)
        try FileManager.default.removeItem(at: source)
        staged = nil
        XCTAssertNotNil(weakFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        queue.removeAll()
        XCTAssertNil(weakFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDirectory.path))
    }

    func testIdentityIsOnlyTheUUID() throws {
        let first = try makeStaged()
        let sameIdentity = try makeStaged(id: first.id, name: "different.pdf")
        let differentIdentity = try makeStaged()
        XCTAssertEqual(first, sameIdentity)
        XCTAssertEqual(Set([first, sameIdentity]).count, 1)
        XCTAssertNotEqual(first, differentIdentity)
        XCTAssertEqual(Set([first, differentIdentity]).count, 2)
    }

    func testCopyRejectsDirectoriesEmptyMissingAndNonFileURLs() throws {
        let directory = try AttachmentFileIO.makeDirectory(prefix: "AttachmentTest-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.xlsx")
        try Data().write(to: empty)
        XCTAssertThrowsError(try StagedAttachmentFile.copy(from: directory))
        XCTAssertThrowsError(try StagedAttachmentFile.copy(from: empty))
        XCTAssertThrowsError(try StagedAttachmentFile.copy(from: directory.appendingPathComponent("missing.xlsx")))
        XCTAssertThrowsError(try StagedAttachmentFile.copy(from: URL(string: "https://example.invalid/file")!))
    }

    func testCopyRejectsUnreadableFiles() throws {
        let directory = try AttachmentFileIO.makeDirectory(prefix: "AttachmentTest-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("unreadable.xlsx")
        try Data([1]).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
        guard !FileManager.default.isReadableFile(atPath: source.path) else {
            throw XCTSkip("The test host can read files regardless of permission bits")
        }
        XCTAssertThrowsError(try StagedAttachmentFile.copy(from: source))
    }

    func testMultipartSessionComesFirstAndUnicodeHeadersAreSafe() throws {
        let file = try makeStaged(name: "数据\"\r\nX-Evil: yes\\report.xlsx",
                                  mimeType: "application/vnd.ms-excel\r\nX-Evil: yes")
        let payload = try AttachmentMultipartFile(file: file, sessionID: "session-数据", boundary: "test-boundary")
        let url = payload.url
        defer { payload.remove() }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text,
            "--test-boundary\r\nContent-Disposition: form-data; name=\"session_id\"\r\n\r\nsession-数据\r\n"
            + "--test-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"数据%22%0D%0AX-Evil: yes%5Creport.xlsx\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\nfile-content\r\n--test-boundary--\r\n")
        XCTAssertFalse(text.contains("\r\nX-Evil:"))
        XCTAssertEqual(payload.size, Int64(text.utf8.count))
        payload.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testMultipartWithoutSessionAndDeinitCleanup() throws {
        let file = try makeStaged()
        var payload: AttachmentMultipartFile? = try AttachmentMultipartFile(file: file, sessionID: nil,
                                                                          boundary: "test-boundary")
        let url = try XCTUnwrap(payload?.url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("session_id"))
        XCTAssertTrue(text.hasPrefix("--test-boundary\r\nContent-Disposition: form-data; name=\"file\";"))
        XCTAssertTrue(text.contains("filename=\"report.xlsx\"\r\nContent-Type: application/vnd.ms-excel\r\n"))
        payload = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testMultipartStreams120MiBSparseStagedFile() throws {
        let size: Int64 = 120 * 1024 * 1024
        let directory = try AttachmentFileIO.makeDirectory(prefix: "AttachmentTest-")
        let source = directory.appendingPathComponent("large.xlsx")
        let writer = try AttachmentFileIO.writer(at: source)
        do {
            try writer.truncate(atOffset: UInt64(size))
            try writer.write(contentsOf: Data("BEGIN".utf8))
            try writer.seek(toOffset: UInt64(size - 3))
            try writer.write(contentsOf: Data("END".utf8))
            try writer.close()
        } catch {
            try? writer.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let file = StagedAttachmentFile(url: source, name: "large.xlsx", mimeType: "application/vnd.ms-excel",
                                        size: size, ownerDirectory: directory)
        let payload = try AttachmentMultipartFile(file: file, sessionID: nil, boundary: "large-boundary")
        defer { payload.remove() }
        XCTAssertGreaterThan(payload.size, size)
        XCTAssertLessThan(payload.size - size, 1024)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: payload.url.path)[.size] as? NSNumber)?.int64Value,
                       payload.size)

        let reader = try FileHandle(forReadingFrom: payload.url)
        defer { try? reader.close() }
        let head = try XCTUnwrap(reader.read(upToCount: 1024))
        let separator = try XCTUnwrap(head.range(of: Data("\r\n\r\n".utf8)))
        let bodyOffset = UInt64(separator.upperBound)
        try reader.seek(toOffset: bodyOffset)
        XCTAssertEqual(try reader.read(upToCount: 5), Data("BEGIN".utf8))
        try reader.seek(toOffset: bodyOffset + UInt64(size / 2))
        XCTAssertEqual(try reader.read(upToCount: 16), Data(repeating: 0, count: 16))
        try reader.seek(toOffset: bodyOffset + UInt64(size - 3))
        XCTAssertEqual(try reader.read(upToCount: 3), Data("END".utf8))
        XCTAssertEqual(try reader.readToEnd(), Data("\r\n--large-boundary--\r\n".utf8))
    }

    func testFailedMultipartConstructionCleansItsDirectory() throws {
        let file = try makeStaged()
        let before = try multipartDirectories()
        try FileManager.default.removeItem(at: file.url)
        XCTAssertThrowsError(try AttachmentMultipartFile(file: file, sessionID: nil))
        XCTAssertEqual(try multipartDirectories(), before)
        XCTAssertThrowsError(try AttachmentMultipartFile(file: file, sessionID: nil, boundary: "unsafe\r\nheader"))
        XCTAssertEqual(try multipartDirectories(), before)
    }

    func testResponseDecodesCamelCaseSnakeCaseAndOptionalMIME() throws {
        for field in [#","mimeType":"application/vnd.ms-excel""#,
                      #","mime_type":"application/vnd.ms-excel""#, "", #","mimeType":null"#] {
            let json = "{\"path\":\"/uploads/report.xlsx\",\"name\":\"report.xlsx\",\"size\":125829120\(field)}"
            let uploaded = try CodegJSON.decoder.decode(UploadedAttachment.self, from: Data(json.utf8))
            XCTAssertEqual(uploaded.path, "/uploads/report.xlsx")
            XCTAssertEqual(uploaded.name, "report.xlsx")
            XCTAssertEqual(uploaded.size, 125_829_120)
            XCTAssertEqual(uploaded.mimeType, field.contains("application") ? "application/vnd.ms-excel" : nil)
        }
    }

    func testResponseRejectsInvalidMetadata() throws {
        for path in ["", "report.xlsx", "C:report.xlsx", "\\report.xlsx", "\\\\server", "https://server/file", "/bad\nfile"] {
            let data = try JSONSerialization.data(withJSONObject: ["path": path, "name": "file", "size": 1])
            XCTAssertThrowsError(try CodegJSON.decoder.decode(UploadedAttachment.self, from: data))
        }
        for size in [0, -1] {
            let json = "{\"path\":\"/uploads/file\",\"name\":\"file\",\"size\":\(size)}"
            XCTAssertThrowsError(try CodegJSON.decoder.decode(UploadedAttachment.self, from: Data(json.utf8)))
        }
        for json in ["", "null", "{}", #"{"path":"/file","name":"","size":1}"#] {
            XCTAssertThrowsError(try CodegJSON.decoder.decode(UploadedAttachment.self, from: Data(json.utf8)))
        }
    }

    func testFileURIsEncodePOSIXDriveAndUNCPathsWithoutFragmentsOrQueries() throws {
        let suffix = "%E6%95%B0%E6%8D%AE%20%23%3F%25.xlsx"
        let cases: [(String, String)] = [
            ("/uploads/数据 #?%.xlsx", "file:///uploads/" + suffix),
            ("C:\\uploads\\数据 #?%.xlsx", "file:///C:/uploads/" + suffix),
            ("D:/uploads/数据 #?%.xlsx", "file:///D:/uploads/" + suffix),
            ("\\\\server\\share\\数据 #?%.xlsx", "file://server/share/" + suffix),
            ("//server/share/数据 #?%.xlsx", "file://server/share/" + suffix),
            ("/uploads/literal\\name.xlsx", "file:///uploads/literal%5Cname.xlsx")
        ]
        for (path, expected) in cases {
            let uploaded = UploadedAttachment(path: path, name: "file.xlsx", size: 1, mimeType: nil)
            XCTAssertEqual(uploaded.fileURI, expected)
            let url = try XCTUnwrap(URLComponents(string: uploaded.fileURI))
            XCTAssertEqual(url.scheme, "file")
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
        }
    }

    func testUploadUsesInjectedSessionAndCleansPayloadOnSuccess() async throws {
        let fixture = UploadFixture(status: 200, body: Self.validResponse)
        let harness = UploadHarness(fixture: fixture)
        defer { harness.close() }
        let file = try makeStaged()
        let progress = UploadProgressRecorder()
        let uploaded = try await harness.client.uploadAttachment(file: file, sessionID: "session-123") {
            progress.append($0)
        }
        XCTAssertEqual(uploaded.path, "/uploads/report.xlsx")
        XCTAssertEqual(uploaded.mimeType, "application/vnd.ms-excel")
        XCTAssertEqual(fixture.requestCount, 1)
        let payload = try XCTUnwrap(fixture.payloadURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(progress.values.first, 0)
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertEqual(progress.values, progress.values.sorted())
        XCTAssertEqual(harness.session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(harness.session.configuration.timeoutIntervalForResource, 120)
        let configuration = CodegClient.attachmentUploadConfiguration(from: harness.session)
        XCTAssertGreaterThanOrEqual(configuration.timeoutIntervalForRequest, 120)
        XCTAssertGreaterThanOrEqual(configuration.timeoutIntervalForResource, 900)
        XCTAssertTrue(configuration.protocolClasses?.contains { $0 == UploadFixtureProtocol.self } == true)
    }

    func testHTTPFailuresPreserveStructuredErrorsAndCleanPayloadWithoutRetry() async throws {
        for status in [401, 413, 422, 503, 307] {
            let fixture = UploadFixture(status: status,
                body: #"{"code":"fixture_code","message":"fixture message","detail":"fixture detail"}"#)
            let harness = UploadHarness(fixture: fixture)
            defer { harness.close() }
            let file = try makeStaged()
            let progress = UploadProgressRecorder()
            do {
                _ = try await harness.client.uploadAttachment(file: file, sessionID: nil) { progress.append($0) }
                XCTFail("Expected HTTP \(status) to fail")
            } catch let error as APIError {
                if status == 401 {
                    guard case .unauthorized = error else { XCTFail("Expected unauthorized"); continue }
                } else {
                    guard case .server(let returnedStatus, let code, let message, let detail) = error else {
                        XCTFail("Expected a server error"); continue
                    }
                    XCTAssertEqual(returnedStatus, status)
                    XCTAssertEqual(code, "fixture_code")
                    if status == 413 {
                        XCTAssertEqual(message, "File exceeds the server upload limit.")
                        XCTAssertNil(detail)
                    } else if status == 307 {
                        XCTAssertEqual(message, "Attachment upload redirects are not allowed.")
                    } else {
                        XCTAssertEqual(message, "fixture message")
                        XCTAssertEqual(detail, "fixture detail")
                    }
                }
            }
            XCTAssertEqual(fixture.requestCount, 1)
            let payload = try XCTUnwrap(fixture.payloadURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.deletingLastPathComponent().path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
            XCTAssertFalse(progress.values.contains(1))
        }
    }

    func testMalformedAcknowledgementAndTransportFailureCleanPayload() async throws {
        for failure in [false, true] {
            let fixture = UploadFixture(status: 200, body: "{}", failTransport: failure)
            let harness = UploadHarness(fixture: fixture)
            defer { harness.close() }
            let file = try makeStaged()
            do {
                _ = try await harness.client.uploadAttachment(file: file, sessionID: nil) { _ in }
                XCTFail("Expected failure")
            } catch let error as APIError {
                if failure {
                    guard case .transport = error else { XCTFail("Expected transport error"); continue }
                } else {
                    guard case .decoding = error else { XCTFail("Expected decoding error"); continue }
                }
            }
            XCTAssertEqual(fixture.requestCount, 1)
            let payload = try XCTUnwrap(fixture.payloadURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.deletingLastPathComponent().path))
        }
    }

    func testInFlightCancellationPropagatesAndCleansPayload() async throws {
        let started = expectation(description: "upload reached the transport")
        let stopped = expectation(description: "underlying upload was cancelled")
        let fixture = UploadFixture(status: 200, body: "", stalls: true, started: started, stopped: stopped)
        let harness = UploadHarness(fixture: fixture)
        defer { harness.close() }
        let file = try makeStaged()
        let task = Task { try await harness.client.uploadAttachment(file: file, sessionID: nil) { _ in } }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(fixture.requestCount, 1)
        let payload = try XCTUnwrap(fixture.payloadURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testCancelledPreparationDoesNotCreatePayload() async throws {
        let file = try makeStaged()
        let before = try multipartDirectories()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try StagedAttachmentFile.copy(from: file.url)
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let multipartTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try AttachmentMultipartFile(file: file, sessionID: nil)
        }
        do { try await multipartTask.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try multipartDirectories(), before)
    }

    func testDelegateProgressIsBoundedAndRedirectsAreRejected() throws {
        let progress = UploadProgressRecorder()
        let delegate = AttachmentUploadDelegate { progress.append($0) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://original.invalid/api/upload_attachment")!
        let task = session.uploadTask(with: URLRequest(url: original), from: Data())
        delegate.report(0)
        delegate.urlSession(session, task: task, didSendBodyData: 50, totalBytesSent: 50, totalBytesExpectedToSend: 100)
        delegate.urlSession(session, task: task, didSendBodyData: 0, totalBytesSent: 20, totalBytesExpectedToSend: 100)
        delegate.urlSession(session, task: task, didSendBodyData: 0, totalBytesSent: 100, totalBytesExpectedToSend: -1)
        delegate.urlSession(session, task: task, didSendBodyData: 100, totalBytesSent: 150, totalBytesExpectedToSend: 100)
        delegate.report(.nan)
        delegate.report(1)
        XCTAssertEqual(progress.values, [0, 0.5, 0.99, 1])
        for url in [original, URL(string: "https://other.invalid/upload")!] {
            let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!
            var called = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: url)) { request in
                called = true
                XCTAssertNil(request)
            }
            XCTAssertTrue(called)
        }
    }

    func testConcurrentProgressDeliveryRemainsMonotonic() {
        let progress = UploadProgressRecorder()
        let delegate = AttachmentUploadDelegate { progress.append($0) }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            delegate.report(Double(index) / 200)
        }
        delegate.report(1)
        XCTAssertEqual(progress.values, progress.values.sorted())
        XCTAssertEqual(progress.values.last, 1)
    }

    private static let validResponse = #"{"path":"/uploads/report.xlsx","name":"report.xlsx","size":12,"mimeType":"application/vnd.ms-excel"}"#

    private func makeStaged(id: UUID = UUID(), name: String = "report.xlsx",
                            mimeType: String = "application/vnd.ms-excel") throws -> StagedAttachmentFile {
        let directory = try AttachmentFileIO.makeDirectory(prefix: "AttachmentTest-")
        let url = directory.appendingPathComponent("fixture.xlsx")
        let contents = Data("file-content".utf8)
        do { try contents.write(to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return StagedAttachmentFile(id: id, url: url, name: name, mimeType: mimeType,
                                    size: Int64(contents.count), ownerDirectory: directory)
    }

    private func multipartDirectories() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("CodegMultipart-") })
    }
}

private final class UploadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Per-host fixtures avoid an unguarded mutable URLProtocol handler across tests.
private final class UploadFixture: @unchecked Sendable {
    let status: Int
    let body: Data
    let stalls: Bool
    let failTransport: Bool
    let started: XCTestExpectation?
    let stopped: XCTestExpectation?
    private let lock = NSLock()
    private var count = 0
    private var payload: URL?

    init(status: Int, body: String, stalls: Bool = false, failTransport: Bool = false,
         started: XCTestExpectation? = nil, stopped: XCTestExpectation? = nil) {
        self.status = status
        self.body = Data(body.utf8)
        self.stalls = stalls
        self.failTransport = failTransport
        self.started = started
        self.stopped = stopped
    }

    func record(_ payload: URL) { lock.lock(); defer { lock.unlock() }; count += 1; self.payload = payload }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var payloadURL: URL? { lock.lock(); defer { lock.unlock() }; return payload }
}

private final class UploadFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: UploadFixture] = [:]
    func set(_ fixture: UploadFixture, host: String) { lock.lock(); defer { lock.unlock() }; fixtures[host] = fixture }
    func get(_ host: String) -> UploadFixture? { lock.lock(); defer { lock.unlock() }; return fixtures[host] }
    func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; fixtures.removeValue(forKey: host) }
}

private struct UploadHarness: Sendable {
    let client: CodegClient
    let session: URLSession
    let host: String

    init(fixture: UploadFixture) {
        let host = UUID().uuidString.lowercased() + ".attachments.invalid"
        UploadFixtureProtocol.registry.set(fixture, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.protocolClasses = [UploadFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        self.host = host
        self.session = session
        self.client = CodegClient(baseURL: URL(string: "https://" + host)!, token: "fixture", session: session)
    }

    func close() { session.invalidateAndCancel(); UploadFixtureProtocol.registry.remove(host) }
}

private final class UploadFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let registry = UploadFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".attachments.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        if let host = request.url?.host { Self.registry.get(host)?.stopped?.fulfill() }
    }

    override func startLoading() {
        do {
            guard let host = request.url?.host, let fixture = Self.registry.get(host),
                  request.url?.path == "/api/upload_attachment", request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
                  request.timeoutInterval >= 120,
                  let type = request.value(forHTTPHeaderField: "Content-Type"),
                  type.hasPrefix("multipart/form-data; boundary="),
                  let length = request.value(forHTTPHeaderField: "Content-Length"), Int64(length) ?? 0 > 0 else {
                throw URLError(.badServerResponse)
            }
            let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
            let payload = try findPayload(boundary: boundary)
            fixture.record(payload)
            fixture.started?.fulfill()
            if fixture.stalls { return }
            if fixture.failTransport { throw URLError(.networkConnectionLost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func findPayload(boundary: String) throws -> URL {
        let prefix = Data(("--" + boundary + "\r\n").utf8)
        let directories = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                                                                       includingPropertiesForKeys: nil)
        for directory in directories where directory.lastPathComponent.hasPrefix("CodegMultipart-") {
            let url = directory.appendingPathComponent("payload.multipart")
            guard let reader = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? reader.close() }
            if try reader.read(upToCount: prefix.count) == prefix { return url }
        }
        throw URLError(.fileDoesNotExist)
    }
}
