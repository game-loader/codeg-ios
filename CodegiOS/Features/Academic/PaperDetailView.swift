import SwiftUI

/// A paper: where its preparation stands (refreshed while a job runs), the
/// choices it may be waiting on (an arXiv match, a repository), the research
/// agent's analysis, and the conversations about it. "Start asking" opens a new
/// conversation bound to the paper — in its cloned repository when there is
/// one, otherwise paper only.
///
/// `onOpen` nil is the read-only form (a sheet from a conversation's paper
/// bar): no new conversations are started from there.
struct PaperDetailView: View {
    let client: CodegClient
    let paperID: String
    var onOpen: ((Route) -> Void)? = nil

    @State private var paper: AcademicPaper?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isWorking = false
    @State private var confirmPrepare = false
    @State private var showFullAbstract = false

    var body: some View {
        ZStack {
            CodegBackground()
            if let paper {
                content(paper)
            } else if let loadError {
                InlineErrorView(message: loadError) { Task { await refresh() } }
            } else {
                LoadingView(label: "Loading paper…")
            }
        }
        .navigationTitle("Paper")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .tint(Theme.accent)
                    .accessibilityLabel("Refresh")
            }
        }
        // While a job runs the paper changes step by step; the web follows the
        // server's change events, this polls.
        .task(id: paperID) {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(paper?.status.isBusy == true ? 3 : 20))
                guard !Task.isCancelled else { return }
                await refresh(quietly: true)
            }
        }
        .confirmationDialog(
            "Prepare this paper again?",
            isPresented: $confirmPrepare,
            titleVisibility: .visible
        ) {
            Button("Prepare Again") { Task { await prepare() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The research agent runs the preparation again on the server. This can take several minutes.")
        }
    }

    private func content(_ paper: AcademicPaper) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                header(paper)
                if let error = paper.error, !error.isEmpty {
                    NoticeCard(tone: paper.status == .metadataOnly ? .warning : .error, message: error)
                }
                if let actionError {
                    NoticeCard(tone: .error, message: actionError)
                }
                actions(paper)
                if paper.status == .needsMatch { arxivCandidates(paper) }
                if paper.status == .needsRepo { repositoryCandidates(paper) }
                if !paper.abstractText.isEmpty { abstract(paper) }
                if paper.repoUrl != nil || paper.repoPath != nil { repository(paper) }
                if let analysis = paper.analysis, !analysis.isEmpty { analysisSection(paper, analysis) }
                if !paper.conversations.isEmpty { conversations(paper) }
                files(paper)
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, Theme.Layout.screenTopInset)
            .padding(.bottom, Theme.Layout.screenBottomInset)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await refresh() }
    }

    // MARK: - Sections

    private func header(_ paper: AcademicPaper) -> some View {
        GlassCard(cornerRadius: Theme.Radius.lg, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                PaperStatusLabel(status: paper.status)
                Text(verbatim: paper.title.isEmpty ? paper.itemKey : paper.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !paper.authors.isEmpty {
                    Text(verbatim: paper.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let links = identifierLinks(paper)
                if !links.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(links, id: \.label) { link in
                            Link(destination: link.url) {
                                Label {
                                    Text(verbatim: link.label)
                                } icon: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                            }
                            .tint(Theme.accent)
                        }
                    }
                }
            }
        }
    }

    private struct IdentifierLink {
        let label: String
        let url: URL
    }

    private func identifierLinks(_ paper: AcademicPaper) -> [IdentifierLink] {
        var links: [IdentifierLink] = []
        if let arxiv = paper.arxivId, let url = URL(string: "https://arxiv.org/abs/\(arxiv)") {
            links.append(IdentifierLink(label: "arXiv:\(arxiv)", url: url))
        }
        if let doi = paper.doi, !doi.isEmpty,
           let url = URL(string: "https://doi.org/\(doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi)") {
            links.append(IdentifierLink(label: "DOI \(doi)", url: url))
        }
        return links
    }

    @ViewBuilder
    private func actions(_ paper: AcademicPaper) -> some View {
        let status = paper.status
        VStack(spacing: 10) {
            if onOpen != nil {
                PrimaryGlassButton(title: "Start Asking", systemImage: "bubble.left.and.text.bubble.right", isLoading: isWorking) {
                    Task { await startAsking(paper, withoutCode: paper.repoPath == nil) }
                }
                .disabled(isWorking || status.isBusy || status.needsChoice)
                // The web offers the paper-only chat next to a repository, and
                // while there is none yet.
                if paper.repoPath != nil || status.isBusy || status.needsChoice {
                    secondaryButton("Ask About the Paper Only", systemImage: "doc.text") {
                        Task { await startAsking(paper, withoutCode: true) }
                    }
                    .disabled(isWorking)
                }
            }
            if status.isBusy {
                secondaryButton("Cancel Preparation", systemImage: "stop.circle", role: .destructive) {
                    Task { await cancel() }
                }
                .disabled(isWorking)
            } else {
                secondaryButton("Prepare Again", systemImage: "arrow.triangle.2.circlepath") {
                    confirmPrepare = true
                }
                .disabled(isWorking)
            }
        }
    }

    private func secondaryButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .tint(role == .destructive ? Theme.danger : Theme.accent)
    }

    private func arxivCandidates(_ paper: AcademicPaper) -> some View {
        EditorSection(title: "Choose the arXiv Match", footer: "Zotero has no PDF for this paper. Pick the arXiv entry it is.") {
            ForEach(Array(paper.candidates.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 { InsetDivider(leading: SettingsRowMetrics.hInset) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: candidate.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: "\(AcademicFormat.authors(candidate.authors)) · \(candidate.id)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if !candidate.summary.isEmpty {
                        Text(verbatim: candidate.summary)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(4)
                    }
                    Button("Use This Paper") {
                        Task { await prepare(arxivId: candidate.id) }
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
                    .disabled(isWorking)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func repositoryCandidates(_ paper: AcademicPaper) -> some View {
        EditorSection(title: "Choose a Repository", footer: "More than one repository matched the paper’s evidence.") {
            ForEach(Array(paper.repoCandidates.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 { InsetDivider(leading: SettingsRowMetrics.hInset) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: candidate.url)
                        .font(.mono(12))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                    if !candidate.evidenceQuote.isEmpty {
                        Text(verbatim: "“\(candidate.evidenceQuote)”")
                            .font(.caption)
                            .italic()
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(5)
                    }
                    if let source = candidate.sourceUrl {
                        Text(verbatim: source)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Use This Repository") {
                        Task { await prepare(repoUrl: candidate.url) }
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
                    .disabled(isWorking)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func abstract(_ paper: AcademicPaper) -> some View {
        EditorSection(title: "Abstract") {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: paper.abstractText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(showFullAbstract ? nil : 6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    withAnimation(Theme.Motion.expand) { showFullAbstract.toggle() }
                } label: {
                    showFullAbstract ? Text("Show Less") : Text("Show More")
                }
                .font(.caption.weight(.semibold))
                .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func repository(_ paper: AcademicPaper) -> some View {
        EditorSection(
            title: "Code",
            footer: "Found from the paper’s own evidence. Check the repository’s license before reusing its code."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let url = paper.repoUrl {
                    if let link = URL(string: url) {
                        Link(destination: link) {
                            Label {
                                Text(verbatim: url).lineLimit(1).truncationMode(.middle)
                            } icon: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                            }
                            .font(.footnote.weight(.medium))
                        }
                        .tint(Theme.accent)
                    } else {
                        LabeledValue(label: "Repository", value: url, monospaced: true)
                    }
                }
                if let path = paper.repoPath {
                    LabeledValue(label: "Checkout", value: path, monospaced: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func analysisSection(_ paper: AcademicPaper, _ analysis: String) -> some View {
        EditorSection(title: "Analysis") {
            VStack(alignment: .leading, spacing: 12) {
                MarkdownContent(raw: analysis)
                if let id = paper.analysisConversationId, let onOpen {
                    Button {
                        onOpen(.conversation(id))
                    } label: {
                        Label("Open the Analysis Conversation", systemImage: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .tint(Theme.accent)
                }
            }
            .padding(16)
        }
    }

    private func conversations(_ paper: AcademicPaper) -> some View {
        EditorSection(title: "Conversations") {
            ForEach(Array(paper.conversations.reversed().enumerated()), id: \.element.id) { index, conversation in
                if index > 0 { SettingsRowDivider() }
                Button {
                    onOpen?(.conversation(conversation.id))
                } label: {
                    HStack(spacing: SettingsRowMetrics.iconGap) {
                        AgentIcon(agent: AgentType(rawValue: conversation.agentType) ?? .other(conversation.agentType))
                            .frame(width: SettingsRowMetrics.badgeSize, height: SettingsRowMetrics.badgeSize)
                        Group {
                            if let title = conversation.title, !title.isEmpty {
                                Text(verbatim: title)
                            } else {
                                Text("Untitled session")
                            }
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        Spacer(minLength: 8)
                        if onOpen != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, SettingsRowMetrics.hInset)
                    .padding(.vertical, SettingsRowMetrics.vInset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onOpen == nil)
            }
        }
    }

    @ViewBuilder
    private func files(_ paper: AcademicPaper) -> some View {
        if paper.pdfPath != nil || paper.textPath != nil {
            EditorSection(title: "Files on the Server") {
                VStack(alignment: .leading, spacing: 12) {
                    if let pdf = paper.pdfPath, !pdf.isEmpty {
                        // The attachment path comes from this server's paper
                        // metadata. Confine the read to its containing directory.
                        NavigationLink {
                            WorkspacePDFPreviewView(
                                client: client,
                                rootPath: PDFServerPath.directory(pdf),
                                absPath: pdf
                            )
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Open PDF", systemImage: "doc.richtext")
                                        .foregroundStyle(Theme.accent)
                                    Text(verbatim: pdf)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let text = paper.textPath { LabeledValue(label: "Text", value: text, monospaced: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    // MARK: - Actions

    private func refresh(quietly: Bool = false) async {
        do {
            paper = try await client.academicPaper(id: paperID)
            loadError = nil
        } catch {
            guard !Task.isCancelled, !quietly || paper == nil else { return }
            loadError = (error as? APIError)?.displayMessage ?? error.localizedDescription
        }
    }

    private func prepare(arxivId: String? = nil, repoUrl: String? = nil) async {
        await perform {
            let settings = try? await client.academicSettings()
            paper = try await client.academicPrepare(
                paperId: paperID,
                arxivId: arxivId,
                repoUrl: repoUrl,
                preferences: AcademicPreferences.forResearchAgent(settings?.agentType)
            )
        }
    }

    private func cancel() async {
        await perform {
            try await client.academicCancel(paperId: paperID)
            paper = try await client.academicPaper(id: paperID)
        }
    }

    /// A new conversation about the paper: `academic_open_target` names the
    /// agent and (with code) registers the repository as a folder; nothing is
    /// created server-side until the first message is sent.
    private func startAsking(_ paper: AcademicPaper, withoutCode: Bool) async {
        guard let onOpen else { return }
        await perform {
            let target = try await client.academicOpenTarget(paperId: paper.id, withoutCode: withoutCode)
            let agent = AgentType(rawValue: target.agentType) ?? .other(target.agentType)
            let draft = AcademicDraft(
                paperID: paper.id,
                paperTitle: paper.title,
                agent: agent,
                chatMode: target.folderId == nil
            )
            onOpen(.newSession(NewSessionRequest(preselectedFolderID: target.folderId, academic: draft)))
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        actionError = nil
        do {
            try await work()
        } catch {
            if !Task.isCancelled {
                actionError = (error as? APIError)?.displayMessage ?? error.localizedDescription
            }
        }
        isWorking = false
    }
}

/// The preparation state, with a spinner while a job runs.
struct PaperStatusLabel: View {
    let status: AcademicStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                IndicatorDot(color: color)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.surface, in: Capsule())
    }

    private var color: Color {
        switch status {
        case .ready: DiffPalette.addText
        case .needsMatch, .needsRepo, .noCode, .metadataOnly, .interrupted: Theme.warning
        case .failed: Theme.danger
        default: Theme.textTertiary
        }
    }

    private var title: LocalizedStringKey {
        switch status {
        case .queued: "Queued"
        case .resolving: "Finding the PDF"
        case .extracting: "Extracting text"
        case .analyzing: "Analyzing the paper"
        case .verifying: "Verifying repository evidence"
        case .cloning: "Cloning repository"
        case .needsMatch: "Choose an arXiv match"
        case .needsRepo: "Choose a repository"
        case .ready: "Ready with code"
        case .noCode: "Ready — no verified code"
        case .metadataOnly: "Metadata only"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted — prepare again to continue"
        default: LocalizedStringKey(status.rawValue)
        }
    }
}

/// "Paper: <title>" above a conversation bound to a paper; opens the paper.
struct PaperContextBar: View {
    let paper: BoundPaper
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ReferencePalette.commit)
                Text(verbatim: paper.title.isEmpty ? String(localized: "Paper") : paper.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Paper: \(paper.title)"))
    }
}
