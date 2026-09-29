import Foundation
import CoreGraphics
import PDFKit

@main
struct PDFPreviewChecks {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func expect(_ expected: PDFPreviewError, _ action: () throws -> Void) {
        do {
            try action()
            fatalError("Expected \(expected)")
        } catch let error as PDFPreviewError {
            check(error == expected, "Incorrect PDF error: \(error)")
        } catch {
            fatalError("Unexpected error: \(error)")
        }
    }

    static func fixture() -> Data {
        let bytes = NSMutableData()
        let consumer = CGDataConsumer(data: bytes)!
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }

    static func main() async throws {
        check(try PDFServerPath.relative("/repo/docs/论文.pdf", to: "/repo") == "docs/论文.pdf",
              "Nested PDFs stay relative to the project root")
        check(PDFServerPath.directory("/paper.pdf") == "/", "POSIX root is preserved")
        check(PDFServerPath.directory(#"C:\paper.pdf"#) == "C:/", "Windows drive root is absolute")
        check(try PDFServerPath.relative(#"C:\repo\docs\paper.pdf"#, to: "C:/repo") == "docs/paper.pdf",
              "Windows server paths produce relative requests on iOS")
        let unc = #"\\server\share\papers\report.PDF"#
        check(PDFServerPath.name(unc) == "report.PDF" && PDFServerPath.directory(unc) == "//server/share/papers",
              "UNC prefixes survive Academic link routing")
        check(try PDFServerPath.relative(unc, to: #"\\server\share"#) == "papers/report.PDF", "UNC relative path")
        check(PDFServerPath.name(#"/repo/back\slash.pdf"#) == #"back\slash.pdf"#, "Preserve POSIX backslashes")
        for path in ["/other/paper.pdf", "/repo-other/paper.pdf", "/repo/../private.pdf", "/repo//paper.pdf"] {
            expect(.invalidPath) { _ = try PDFServerPath.relative(path, to: "/repo") }
        }
        check(PDFPreviewFile.matches("/project/报告.PdF"), "Case-insensitive PDF routing")
        for path in ["image.png", "note.md", "report.pdf.txt", "/folder.pdf/image.jpg"] {
            check(!PDFPreviewFile.matches(path), "Do not route images or text to PDFKit")
        }
        let data = fixture()
        var file: PDFPreviewFile? = try PDFPreviewFile(base64: data.base64EncodedString(), name: "../报告.PDF")
        let url = file!.url
        check(url.lastPathComponent == "报告.PDF", "Export retains only the original basename")
        check(try Data(contentsOf: url) == data, "Share exports the original PDF bytes")
        check(try file!.openDocument().pageCount == 2, "Valid PDFKit document has both pages")
        let other = try PDFPreviewFile(base64: data.base64EncodedString(), name: "../报告.PDF")
        check(other.url != url, "Same-name documents must use separate local files")
        var sharing = file
        file = nil
        check(sharing?.url == url && FileManager.default.fileExists(atPath: url.path),
              "Export owner keeps the file alive after closing the reader")
        sharing = nil
        check(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
              "Release removes only the owned temporary directory")
        check(FileManager.default.fileExists(atPath: other.url.path), "Other viewers remain intact")

        expect(.invalidData) { _ = try PDFPreviewFile(base64: "", name: "empty.pdf") }
        expect(.invalidData) { _ = try PDFPreviewFile(base64: "not base64!", name: "invalid.pdf") }
        expect(.invalidData) {
            let invalid = try PDFPreviewFile(base64: Data("not a PDF".utf8).base64EncodedString(), name: "fake.pdf")
            _ = try invalid.openDocument()
        }
        expect(.invalidData) {
            let broken = try PDFPreviewFile(base64: Data("%PDF-1.7\ntruncated".utf8).base64EncodedString(), name: "broken.pdf")
            _ = try broken.openDocument()
        }
        // +1 byte shares the same encoded length as the 20 MB boundary; this
        // exercises the decoded-size check independently of the encoded cap.
        expect(.tooLarge) {
            _ = try PDFPreviewFile(base64: Data(repeating: 65, count: PDFPreviewFile.maxBytes + 1)
                .base64EncodedString(), name: "too-large.pdf")
        }
        expect(.tooLarge) {
            _ = try PDFPreviewFile(base64: String(repeating: "A", count: ((PDFPreviewFile.maxBytes + 2) / 3) * 4 + 4),
                                   name: "too-large-encoded.pdf")
        }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try PDFPreviewFile(base64: data.base64EncodedString(), name: "canceled.pdf")
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        check(await canceled.value, "Leaving the screen cancels preparation")

        // A password-protected PDF is a readable download, not corrupt data.
        // The iOS reader shows a specific locked state and retains Share.
        let encryptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: encryptedURL) }
        let source = PDFDocument(data: data)!
        check(source.write(to: encryptedURL, withOptions: [
            .userPasswordOption: "test-reader", .ownerPasswordOption: "test-owner"
        ]), "Create password-protected fixture")
        let encrypted = try Data(contentsOf: encryptedURL)
        let locked = try PDFPreviewFile(base64: encrypted.base64EncodedString(), name: "locked.pdf")
        check(try locked.openDocument().isLocked, "Detect locked PDF instead of rendering a blank page")
        check(try Data(contentsOf: locked.url) == encrypted, "Encrypted export is lossless")
        print("PDF parsing, limits, cancellation, original-byte export and cleanup checks passed")
    }
}
