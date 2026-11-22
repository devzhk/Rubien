#if os(macOS)
import Foundation
import RubienCore

/// State for the "Add ‹card›" chooser sheet: attach the card's file to a
/// suggested or searched reference, or continue to today's Add Reference flow.
/// Pure apart from its injected attach/search/open closures.
@MainActor
final class SupplementAttachChoiceModel: ObservableObject {
    typealias AttachAction = @MainActor (_ url: String, _ referenceId: Int64, _ displayName: String) async throws
        -> AssistantSupplementAttacher.Outcome
    typealias SearchAction = @MainActor (_ query: String) async -> [ChatReference]
    typealias OpenAction = @MainActor (_ outcome: AssistantSupplementAttacher.Outcome) async throws -> Void

    enum Choice: Equatable {
        case attach(referenceId: Int64)
        case newReference
    }

    enum PrimaryAction: Equatable {
        case attach
        /// Close the sheet and hand the URL to the unchanged add-source route.
        case continueToNewReference(String)
    }

    enum Phase: Equatable {
        case choosing
        case downloading
        case finished(AssistantSupplementAttacher.Outcome)
        case failed(String)
    }

    /// A reference chosen through "Attach to another reference…".
    struct SearchedTarget: Equatable, Identifiable {
        let referenceId: Int64
        let title: String
        var id: Int64 { referenceId }
    }

    let request: ChatPaperAddRequest
    let cardTitle: String
    /// "host · kind", e.g. "openaccess.thecvf.com · PDF".
    let subtitle: String
    let suggestions: [ChatPaperAttachTarget.Suggestion]

    @Published var choice: Choice {
        didSet { if case .failed = phase, choice != oldValue { phase = .choosing } }
    }
    @Published var attachmentName: String
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var searchedTarget: SearchedTarget?
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [SearchedTarget] = []
    @Published private(set) var openErrorMessage: String?

    private let attachAction: AttachAction
    private let searchAction: SearchAction
    private let openAction: OpenAction
    private var attachTask: Task<Void, Never>?
    private var attempt = 0

    init(
        request: ChatPaperAddRequest,
        resolution: ChatPaperAttachTarget.Resolution,
        attach: @escaping AttachAction,
        search: @escaping SearchAction,
        open: @escaping OpenAction
    ) {
        self.request = request
        let title = request.title.isEmpty
            ? (URL(string: request.url)?.lastPathComponent ?? request.url)
            : request.title
        self.cardTitle = title
        self.subtitle = Self.subtitle(for: request.url)
        self.suggestions = resolution.suggestions
        self.choice = resolution.preselected.map { .attach(referenceId: $0.referenceId) } ?? .newReference
        self.attachmentName = String(title.prefix(255))
        self.attachAction = attach
        self.searchAction = search
        self.openAction = open
    }

    // MARK: Derived state

    var primaryAction: PrimaryAction {
        switch choice {
        case .attach: return .attach
        case .newReference: return .continueToNewReference(request.url)
        }
    }

    var primaryButtonTitle: String {
        primaryAction == .attach ? "Attach" : "Continue…"
    }

    var isAttachSelected: Bool { primaryAction == .attach }

    var isWorking: Bool { phase == .downloading }

    var nameValidationMessage: String? {
        guard isAttachSelected else { return nil }
        do {
            _ = try ReferenceAttachmentStore.validatedDisplayName(attachmentName)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var canPerformPrimary: Bool {
        guard !isWorking else { return false }
        if case .finished = phase { return false }
        return nameValidationMessage == nil
    }

    /// The selected reference's title, from suggestions or a search pick.
    func title(forReference id: Int64) -> String? {
        suggestions.first { $0.referenceId == id }?.title
            ?? (searchedTarget?.referenceId == id ? searchedTarget?.title : nil)
    }

    var isSearchedTargetSelected: Bool {
        guard let searchedTarget else { return false }
        return choice == .attach(referenceId: searchedTarget.referenceId)
            && !suggestions.contains { $0.referenceId == searchedTarget.referenceId }
    }

    /// "Attached to ‹short title›" / "Already attached".
    var resultMessage: String? {
        guard case .finished(let outcome) = phase else { return nil }
        if outcome.wasDuplicate { return "Already attached" }
        let short = ChatPaperAttachTarget.shortTitle(outcome.parentTitle) ?? outcome.parentTitle
        return "Attached to \(short)"
    }

    // MARK: Actions

    /// Starts the attach for an attach selection; for "Add as a new reference"
    /// returns the URL the caller hands to the existing add-source route.
    @discardableResult
    func performPrimary() -> PrimaryAction {
        let action = primaryAction
        if action == .attach { startAttach() }
        return action
    }

    func retry() { startAttach() }

    /// Stops a running download; the temporary directory is removed by the
    /// attacher's `defer` (or by the materializer when the download itself is
    /// cancelled). The sheet returns to its choices.
    func cancelAttach() {
        guard isWorking else { return }
        attempt += 1
        attachTask?.cancel()
        attachTask = nil
        phase = .choosing
    }

    func selectSearchResult(_ target: SearchedTarget) {
        if !suggestions.contains(where: { $0.referenceId == target.referenceId }) {
            searchedTarget = target
        }
        choice = .attach(referenceId: target.referenceId)
        searchResults = []
    }

    func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        let results = await searchAction(query)
        guard !Task.isCancelled,
              query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        searchResults = results.map { SearchedTarget(referenceId: $0.id, title: $0.title) }
    }

    func openAttachment() async {
        guard case .finished(let outcome) = phase else { return }
        do {
            openErrorMessage = nil
            try await openAction(outcome)
        } catch {
            openErrorMessage = error.localizedDescription
        }
    }

    /// Awaits the current attach task (tests).
    func waitForAttach() async {
        await attachTask?.value
    }

    private func startAttach() {
        guard case .attach(let referenceId) = choice, canPerformPrimary else { return }
        guard let name = try? ReferenceAttachmentStore.validatedDisplayName(attachmentName) else { return }
        attachTask?.cancel()
        attempt += 1
        let current = attempt
        phase = .downloading
        openErrorMessage = nil
        let url = request.url
        let attachAction = attachAction
        attachTask = Task { [weak self] in
            let next: Phase
            do {
                let outcome = try await attachAction(url, referenceId, name)
                next = .finished(outcome)
            } catch is CancellationError {
                return
            } catch {
                next = .failed(Self.message(for: error))
            }
            guard let self, self.attempt == current, !Task.isCancelled else { return }
            self.phase = next
            self.attachTask = nil
        }
    }

    static func message(for error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return "The download was cancelled."
        }
        return error.localizedDescription
    }

    static func subtitle(for rawURL: String) -> String {
        guard let url = URL(string: rawURL) else { return "" }
        let host = url.host?.lowercased() ?? ""
        let kind: String
        switch url.pathExtension.lowercased() {
        case "pdf": kind = "PDF"
        case "md", "markdown": kind = "Markdown"
        default: kind = "File"
        }
        return host.isEmpty ? kind : "\(host) · \(kind)"
    }
}
extension SupplementAttachChoiceModel {
    /// Production wiring: attach through the session's library database, search
    /// with the composer's `@` mention query, and open in an attachment reader.
    static func live(
        request: ChatPaperAddRequest,
        resolution: ChatPaperAttachTarget.Resolution,
        database: AppDatabase,
        session: ChatSessionController
    ) -> SupplementAttachChoiceModel {
        let attacher = AssistantSupplementAttacher(dependencies: .live(database: database))
        return SupplementAttachChoiceModel(
            request: request,
            resolution: resolution,
            attach: { url, referenceId, name in
                try await attacher.attach(url: url, to: referenceId, displayName: name)
            },
            search: { [weak session] query in
                await session?.searchMentionableReferences(query) ?? []
            },
            open: { outcome in
                let store = ReferenceAttachmentStore.assistantAttachmentStore(database: database)
                let document = try await AttachmentReaderDocument.open(
                    syncId: outcome.attachmentSyncId, store: store)
                let parentID = outcome.parentReferenceId
                let parent = try await Task.detached(priority: .userInitiated) {
                    try database.fetchReferences(ids: [parentID]).first
                }.value
                guard let parent else { throw ReferenceAttachmentError.missingReference }
                try ReaderWindowManager.shared.openAttachment(document, parent: parent)
            })
    }
}
#endif
