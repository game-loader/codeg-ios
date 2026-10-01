import Foundation
import XCTest
@testable import Codeg

@MainActor
final class SessionFileAttachmentTests: XCTestCase {
    func testLargePickedImageRemainsAnInlineImageInsteadOfAFileLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.png")
        let pixel = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        try pixel.write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: UInt64(AttachmentPrep.maxBytes + 1024))
        try writer.close()
        let attachment = try AttachmentPrep.makeFile(from: source)
        XCTAssertTrue(attachment.isImage)
        XCTAssertTrue(attachment.isReady)
        XCTAssertNil(attachment.file)
        XCTAssertLessThan(attachment.byteCount, AttachmentPrep.maxTotalBytes)
        guard let block = attachment.promptInputBlock, case .image = block else {
            XCTFail("Picked images must retain native image content"); return
        }
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
        if !predicate() { throw URLError(.timedOut) }
    }

    private func file(name: String = "records.xlsx", size: UInt64 = 128) throws -> Attachment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: size)
        try handle.close()
        return Attachment(file: try StagedAttachmentFile.copy(from: source))
    }

    func testLargeExcelUploadsBeforeSendingAndPromptContainsOnlyServerReference() async throws {
        let uploader = FileUploadStub()
        let h = try RecoveryHarness(attachmentUploader: uploader)
        defer { uploader.finishAll(); h.close() }
        await h.model.load()
        let attachment = try file(name: "records [final].xlsx", size: 120 * 1024 * 1024)
        h.model.addAttachments([attachment])
        try await eventually { uploader.count == 1 }
        XCTAssertEqual(attachment.byteCount, 120 * 1024 * 1024)
        XCTAssertTrue(attachment.data.isEmpty)
        XCTAssertTrue(h.model.canAttachMore)
        h.model.draft = "Analyze this spreadsheet"
        h.model.send()
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        XCTAssertEqual(h.model.draft, "Analyze this spreadsheet")
        XCTAssertTrue(h.model.queuedMessages.isEmpty)
        XCTAssertNil(attachment.promptInputBlock)

        uploader.progress(0.5, at: 0)
        try await eventually { h.model.attachments.first?.uploadProgress == 0.5 }
        let result = uploader.succeed(at: 0)
        try await eventually { h.model.attachments.first?.isReady == true }
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 && !h.model.isSubmittingPrompt }
        let body = try XCTUnwrap(h.server.bodies("acp_prompt").first)
        let blocks = try XCTUnwrap(body["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1]["type"] as? String, "resource_link")
        XCTAssertEqual(blocks[1]["uri"] as? String, result.fileURI)
        XCTAssertEqual(blocks[1]["name"] as? String, result.name)
        XCTAssertEqual(blocks[1]["mime_type"] as? String, attachment.mimeType)
        XCTAssertNil(blocks[1]["data"])
        XCTAssertNil(blocks[1]["blob"])
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: body).count, 2048)
        XCTAssertEqual(uploader.count, 1)
        XCTAssertTrue(h.model.attachments.isEmpty)
        XCTAssertEqual(h.server.unexpectedRequests, [])
    }

    func testUploadLimitFailureKeepsDraftAndExplicitRetryCanSendFileOnlyMessage() async throws {
        let uploader = FileUploadStub()
        let h = try RecoveryHarness(attachmentUploader: uploader)
        defer { uploader.finishAll(); h.close() }
        await h.model.load()
        let attachment = try file()
        h.model.addAttachments([attachment])
        try await eventually { uploader.count == 1 }
        uploader.fail(APIError.server(status: 413, code: nil, message: "too large", detail: nil), at: 0)
        try await eventually { h.model.attachments.first?.uploadFailure != nil }
        XCTAssertEqual(h.model.attachments.first?.uploadFailure, String(localized: "File exceeds the server upload limit."))
        XCTAssertNil(h.model.attachments.first?.uploadProgress)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.file!.url.path))
        h.model.send()
        XCTAssertEqual(h.server.count("acp_prompt"), 0)
        XCTAssertEqual(h.model.attachments.count, 1)
        h.model.retryAttachment(attachment.id)
        h.model.retryAttachment(attachment.id)
        try await eventually { uploader.count == 2 }
        uploader.succeed(at: 1)
        try await eventually { h.model.attachments.first?.isReady == true }
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 1 }
        let blocks = h.server.bodies("acp_prompt").first?["blocks"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertEqual(blocks?.first?["type"] as? String, "resource_link")
    }

    func testRemovingFileIgnoresLateUploadResultsAndProgress() async throws {
        let uploader = FileUploadStub()
        let h = try RecoveryHarness(attachmentUploader: uploader)
        defer { uploader.finishAll(); h.close() }
        await h.model.load()
        let old = try file()
        h.model.addAttachments([old])
        try await eventually { uploader.count == 1 }
        h.model.removeAttachment(old.id)
        let replacement = try file()
        h.model.addAttachments([replacement])
        try await eventually { uploader.count == 2 }
        uploader.succeed(at: 0)
        uploader.progress(1, at: 0)
        uploader.progress(0.3, at: 1)
        try await eventually { h.model.attachments.first?.uploadProgress == 0.3 }
        XCTAssertEqual(h.model.attachments.map(\.id), [replacement.id])
        XCTAssertFalse(h.model.attachments[0].isReady)
        XCTAssertNil(h.model.attachments[0].uploaded)
    }

    func testViewTeardownInterruptsUploadAndRetainsLocalFileForRetry() async throws {
        let uploader = FileUploadStub()
        let h = try RecoveryHarness(attachmentUploader: uploader)
        defer { uploader.finishAll(); h.close() }
        await h.model.load()
        let attachment = try file()
        h.model.addAttachments([attachment])
        try await eventually { uploader.count == 1 }
        h.model.teardown()
        XCTAssertNil(h.model.attachments.first?.uploadProgress)
        XCTAssertEqual(h.model.attachments.first?.uploadFailure, String(localized: "Upload interrupted. Retry when ready."))
        uploader.succeed(at: 0)
        await h.model.resume()
        h.model.retryAttachment(attachment.id)
        try await eventually { uploader.count == 2 }
        XCTAssertNil(h.model.attachments.first?.uploaded)
        uploader.succeed(at: 1)
        try await eventually { h.model.attachments.first?.isReady == true }
    }

    func testUploadedFileSurvivesPromptRejectionWithoutBeingUploadedAgain() async throws {
        let uploader = FileUploadStub()
        let h = try RecoveryHarness(attachmentUploader: uploader)
        defer { uploader.finishAll(); h.close() }
        await h.model.load()
        let attachment = try file()
        h.model.addAttachments([attachment])
        try await eventually { uploader.count == 1 }
        let result = uploader.succeed(at: 0)
        try await eventually { h.model.attachments.first?.isReady == true }
        let gate = h.server.holdNextPrompt(httpStatus: 500)
        defer { gate.release() }
        h.model.draft = "Read the file"
        h.model.send()
        try await eventually { gate.hasRequest }
        gate.release()
        try await eventually { !h.model.isSubmittingPrompt }
        XCTAssertEqual(h.model.draft, "Read the file")
        XCTAssertEqual(h.model.attachments.first?.uploaded, result)
        XCTAssertTrue(h.model.attachments.first?.isReady == true)
        h.model.send()
        try await eventually { h.server.count("acp_prompt") == 2 }
        XCTAssertEqual(uploader.count, 1)
    }

    func testUploadedDocumentQueuesAndSteersWithoutChangingNewComposerDraft() async throws {
        let uploader = FileUploadStub()
        let h = try RecoveryHarness(agentType: .codex, attachmentUploader: uploader)
        defer { uploader.finishAll(); h.close() }
        h.server.setConnected(true)
        h.server.setFeedbackEnabled(true)
        h.server.setConnectionSnapshot(["native_steering_available": true])
        h.nextSnapshot = try RecoveryFixtures.snapshot(text: "Working", nativeSteeringAvailable: true)
        await h.model.load()
        try await eventually { h.model.isInFlight && h.model.usesToolBoundaryDelivery }
        let attachment = try file(name: "notes.pdf")
        h.model.addAttachments([attachment])
        try await eventually { uploader.count == 1 }
        uploader.succeed(at: 0)
        try await eventually { h.model.attachments.first?.isReady == true }
        h.model.draft = "Also read this PDF"
        h.model.send()
        XCTAssertEqual(h.model.queuedMessages.count, 1)
        XCTAssertTrue(h.model.queuedMessages[0].attachments[0].isReady)
        h.model.draft = "Next draft"
        try XCTUnwrap(h.streams.last).emit(RecoveryFixtures.event("tool_call_update", fields: [
            "tool_call_id": "file-boundary", "title": "Read", "kind": "read", "status": "completed"
        ], seq: 200))
        try await eventually { h.server.count("submit_session_feedback") == 1 && h.model.queuedMessages.isEmpty }
        let blocks = h.server.bodies("submit_session_feedback").first?["blocks"] as? [[String: Any]]
        XCTAssertEqual(blocks?.last?["type"] as? String, "resource_link")
        XCTAssertNil(blocks?.last?["data"])
        let receipt = try XCTUnwrap(h.server.bodies("submit_session_feedback").first?["text"] as? String)
        XCTAssertTrue(receipt.contains("[notes.pdf](file:///tmp/uploads/notes.pdf)"))
        XCTAssertEqual(h.model.feedbackNotes.first?.text, receipt)
        XCTAssertEqual(h.model.draft, "Next draft")
        XCTAssertEqual(uploader.count, 1)
    }
}

/// Explicit response barriers exercise removal/retry races without a network.
private final class FileUploadStub: AttachmentUploadAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(StagedAttachmentFile, @Sendable (Double) -> Void)] = []
    private var pending: [Int: CheckedContinuation<UploadedAttachment, Error>] = [:]
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    func uploadAttachment(file: StagedAttachmentFile, sessionID: String?,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedAttachment {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let index = requests.count
            requests.append((file, progress))
            pending[index] = continuation
            lock.unlock()
        }
    }
    func progress(_ value: Double, at index: Int) {
        lock.lock(); let callback = requests[index].1; lock.unlock()
        callback(value)
    }
    @discardableResult
    func succeed(at index: Int) -> UploadedAttachment {
        lock.lock()
        let file = requests[index].0
        let continuation = pending.removeValue(forKey: index)
        lock.unlock()
        let result = UploadedAttachment(path: "/tmp/uploads/\(file.name)", name: file.name,
                                        size: file.size, mimeType: file.mimeType)
        continuation?.resume(returning: result)
        return result
    }
    func fail(_ error: Error, at index: Int) {
        lock.lock(); let continuation = pending.removeValue(forKey: index); lock.unlock()
        continuation?.resume(throwing: error)
    }
    func finishAll() {
        lock.lock(); let remaining = Array(pending.values); pending.removeAll(); lock.unlock()
        for continuation in remaining { continuation.resume(throwing: CancellationError()) }
    }
}
