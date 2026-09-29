import SwiftUI
import PDFKit
import UIKit

/// Reads a PDF through the same authenticated, workspace-confined endpoint as
/// image preview. Only the local copy is passed to PDFKit and the share sheet.
struct WorkspacePDFPreviewView: View {
    let client: CodegClient
    let rootPath: String
    let absPath: String

    @State private var file: PDFPreviewFile?
    @State private var document: PDFDocument?
    @State private var sharedFile: PDFPreviewFile?
    @State private var isLoading = true
    @State private var error: String?
    @State private var retry = 0
    @Environment(\.locale) private var locale

    private var name: String { PDFServerPath.name(absPath) }
    private struct LoadID: Hashable {
        let server: URL
        let root: String
        let path: String
        let retry: Int
    }

    var body: some View {
        ZStack {
            CodegBackground()
            if isLoading {
                LoadingView(label: "Loading \(name)…")
            } else if let error {
                InlineErrorView(message: error) { retry += 1 }
            } else if let document {
                if document.isLocked {
                    EmptyStateView(
                        icon: "lock.doc", title: "Password-protected PDF",
                        message: "Use Share to open this PDF in an app that supports passwords."
                    )
                } else {
                    NativePDFView(document: document, file: file)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let file, !isLoading {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sharedFile = file } label: {
                        Label("Share PDF", systemImage: "square.and.arrow.up")
                    }
                    .tint(Theme.accent)
                }
            }
        }
        .task(id: LoadID(server: client.baseURL, root: rootPath, path: absPath, retry: retry)) {
            await load()
        }
        .sheet(item: $sharedFile) { file in
            PDFShareSheet(file: file)
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        document = nil
        file = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let relative = try PDFServerPath.relative(absPath, to: rootPath)
            let encoded = try await client.readWorkspaceFileBase64(
                rootPath: rootPath, path: relative, maxBytes: PDFPreviewFile.maxBytes
            )
            try Task.checkCancellation()
            let filename = name
            let preparation = Task.detached(priority: .userInitiated) {
                try PDFPreviewFile(base64: encoded, name: filename)
            }
            let prepared = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            try Task.checkCancellation()
            let opened = try prepared.openDocument()
            document = opened
            file = prepared
        } catch {
            guard !Task.isCancelled else { return }
            if let issue = error as? PDFPreviewError {
                switch issue {
                case .tooLarge:
                    self.error = String(localized: "PDF is too large to preview (maximum 20 MB).", locale: locale)
                case .invalidData:
                    self.error = String(localized: "This PDF is damaged or could not be opened.", locale: locale)
                case .invalidPath:
                    self.error = String(localized: "The PDF path is not inside its folder.", locale: locale)
                }
            } else if let apiError = error as? APIError,
                      case let .server(_, code, message, _) = apiError,
                      code == "invalid_input", message == "File is too large to attach" {
                self.error = String(localized: "PDF is too large to preview (maximum 20 MB).", locale: locale)
            } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Keeping the document identity stable preserves scroll position and zoom
/// across SwiftUI updates, including presentation/dismissal of the share sheet.
private struct NativePDFView: UIViewRepresentable {
    let document: PDFDocument
    let file: PDFPreviewFile?

    final class Coordinator {
        var file: PDFPreviewFile?
        init(file: PDFPreviewFile?) { self.file = file }
    }

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = document
        view.autoScales = true
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        context.coordinator.file = file
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        view.document = nil
        coordinator.file = nil
    }
}

/// The controller retains the temp-file owner until its activity completes, so
/// an export cannot lose its source if the preview view is released first.
private struct PDFShareSheet: UIViewControllerRepresentable {
    let file: PDFPreviewFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { [file] _, _, _, _ in
            withExtendedLifetime(file) {}
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
