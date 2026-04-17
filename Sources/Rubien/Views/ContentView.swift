import SwiftUI
import Combine
import RubienCore

enum SidebarItem: Hashable {
    case allReferences
    case tag(Int64)
    case titleKeyword(String)
    case view(Int64)
}

struct SearchQuery {
    var keyword: String = ""
    var author: String = ""
    var yearFrom: Int?
    var yearTo: Int?
    var journal: String = ""
    var type: ReferenceType?

    static func parse(_ text: String) -> SearchQuery {
        var q = SearchQuery()
        var keywords: [String] = []
        for part in text.components(separatedBy: " ") {
            if part.hasPrefix("author:") {
                q.author = String(part.dropFirst("author:".count))
            } else if part.hasPrefix("year:") {
                let val = String(part.dropFirst("year:".count))
                if val.contains("-") {
                    let comps = val.split(separator: "-", maxSplits: 1)
                    if val.hasPrefix("-") {
                        q.yearTo = Int(comps.last ?? "")
                    } else if comps.count == 2 {
                        q.yearFrom = Int(comps[0])
                        q.yearTo = Int(comps[1])
                    } else {
                        q.yearFrom = Int(comps[0])
                    }
                } else {
                    q.yearFrom = Int(val)
                    q.yearTo = q.yearFrom
                }
            } else if part.hasPrefix("journal:") {
                q.journal = String(part.dropFirst("journal:".count))
            } else if part.hasPrefix("type:") {
                let val = String(part.dropFirst("type:".count))
                q.type = ReferenceType.allCases.first { $0.rawValue == val }
            } else if !part.isEmpty {
                keywords.append(part)
            }
        }
        q.keyword = keywords.joined(separator: " ")
        return q
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    /// The current page of references returned by the database-level query.
    @Published var references: [Reference] = []
    @Published var pendingMetadataIntakes: [MetadataIntake] = []
    @Published var tags: [Tag] = []
    @Published var selectedSidebar: SidebarItem = .allReferences {
        didSet {
            rebuildReferenceObserver()
            syncColumnConfigFromView()
        }
    }
    /// Raw search text typed by the user; debounced before hitting the DB.
    @Published var searchText = "" {
        didSet { scheduleSearchDebounce() }
    }
    @Published var isImporting = false
    @Published var importProgress: String?
    @Published var errorMessage: String?
    /// All reference titles for smart keyword extraction (unaffected by filters).
    @Published private(set) var allReferenceTitles: [String] = []
    /// Tag map for table view: referenceId → [Tag]
    @Published var referenceTagMap: [Int64: [Tag]] = [:]
    @Published var propertyDefs: [PropertyDefinition] = []
    @Published var customPropertyValueMap: [Int64: [Int64: String]] = [:]
    /// Column configuration for the table view (persisted via @AppStorage in ContentView)
    @Published var tableSorts: [ViewSort] = [.defaultSort]
    @Published var viewFilters: [ViewFilter] = []
    /// All saved database views
    @Published var databaseViews: [DatabaseView] = []

    // MARK: - Private state
    let db: AppDatabase
    private var cancellables = Set<AnyCancellable>()
    /// Cancellable for the active reference ValueObservation subscription.
    private var referenceObserverCancellable: AnyCancellable?
    /// Timer-based debounce task for search input.
    private var searchDebounceTask: Task<Void, Never>?
    /// The filter currently applied to the database query.
    private var activeFilter = ReferenceFilter()

    init(db: AppDatabase = .shared) {
        self.db = db
        setupObservation()
    }

    // MARK: - Observation setup

    private func setupObservation() {
        db.observeTags()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.errorMessage = "Tags refresh failed: \(error.localizedDescription)"
                    }
                },
                receiveValue: { [weak self] tags in
                    self?.tags = tags
                }
            )
            .store(in: &cancellables)

        db.observePendingMetadataIntakes()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.errorMessage = "Pending metadata refresh failed: \(error.localizedDescription)"
                    }
                },
                receiveValue: { [weak self] items in
                    self?.pendingMetadataIntakes = items
                }
            )
            .store(in: &cancellables)

        db.observeDatabaseViews()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] views in
                    self?.databaseViews = views
                    self?.selectDefaultViewIfNeeded()
                }
            )
            .store(in: &cancellables)

        db.observeReferenceTagMappings()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] map in
                    self?.referenceTagMap = map
                }
            )
            .store(in: &cancellables)

        db.observePropertyDefinitions()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] defs in
                    self?.propertyDefs = defs
                }
            )
            .store(in: &cancellables)

        db.observeAllPropertyValues()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] map in
                    self?.customPropertyValueMap = map
                }
            )
            .store(in: &cancellables)

        // Observe all reference titles for smart keyword extraction.
        db.observeReferences()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] refs in
                    self?.allReferenceTitles = refs.map(\.title)
                }
            )
            .store(in: &cancellables)

        // Start the initial reference observation with no filter.
        rebuildReferenceObserver()
    }

    /// (Re-)subscribe to the database with the current scope + filter.
    /// Called whenever the sidebar selection or the debounced filter changes.
    private func rebuildReferenceObserver() {
        referenceObserverCancellable?.cancel()

        let scope = currentReferenceScope
        var filter = activeFilter

        if case .titleKeyword(let word) = selectedSidebar {
            filter.keyword = word
            filter.titleOnly = true
        }

        referenceObserverCancellable = db
            .observeReferences(scope: scope, filter: filter, limit: 0)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.errorMessage = "References refresh failed: \(error.localizedDescription)"
                    }
                },
                receiveValue: { [weak self] refs in
                    self?.references = refs
                }
            )
    }

    var currentReferenceScope: ReferenceScope {
        let scope: ReferenceScope
        switch selectedSidebar {
        case .allReferences, .titleKeyword:
            scope = .all
        case .tag(let id):          scope = .tag(id)
        case .view(let viewId):
            if let dbView = databaseViews.first(where: { $0.id == viewId }) {
                switch dbView.parsedScope {
                case .all: scope = .all
                case .tag(let id): scope = .tag(id)
                }
            } else {
                scope = .all
            }
        }
        return scope
    }


    /// Debounce raw search text by 250 ms before rebuilding the DB observer.
    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
            guard !Task.isCancelled else { return }
            let parsed = SearchQuery.parse(self.searchText)
            var filter = ReferenceFilter()
            filter.keyword      = parsed.keyword
            filter.author       = parsed.author
            filter.yearFrom     = parsed.yearFrom
            filter.yearTo       = parsed.yearTo
            filter.journal      = parsed.journal
            filter.referenceType = parsed.type
            self.activeFilter = filter
            self.rebuildReferenceObserver()
        }
    }

    /// Convenience accessor — references are already filtered by the DB query.
    var filteredReferences: [Reference] { references }

    /// Top title keywords extracted from all reference titles.
    var titleKeywords: [(word: String, count: Int)] {
        let stopWords: Set<String> = [
            // English
            "the", "and", "for", "with", "from", "that", "this", "are", "was",
            "were", "been", "being", "have", "has", "had", "not", "but", "its",
            "can", "may", "will", "should", "could", "would", "into", "than",
            "also", "where", "when", "how", "what", "which", "who", "whom",
            "why", "all", "any", "each", "every", "both", "few", "more",
            "most", "other", "some", "such", "only", "own", "same", "then",
            "too", "very", "just", "about", "above", "after", "again",
            "below", "between", "during", "further", "here", "once", "there",
            "these", "those", "through", "under", "until", "while",
            "over", "out", "off", "down", "before", "our", "your", "his",
            "her", "their", "its", "does", "did", "doing",
            "using", "based", "via", "new", "one", "two", "study", "analysis",
            "case", "approach", "method", "model", "data", "results", "review",
            "research", "paper", "effect", "effects", "use",
            // Chinese
            "的", "了", "在", "是", "我", "有", "和", "就", "不", "人",
            "都", "一", "一个", "上", "也", "很", "到", "说", "要", "去",
            "你", "会", "着", "没有", "看", "好", "自己", "这", "他", "她",
            "对", "中", "与", "及", "或", "等", "基于", "研究", "分析",
        ]

        var freq: [String: Int] = [:]
        for title in allReferenceTitles {
            let lower = title.lowercased()
            let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 && !stopWords.contains($0) }
            for word in Set(words) {
                freq[word, default: 0] += 1
            }
        }

        return freq
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(15)
            .map { (word: $0.key, count: $0.value) }
    }

    func deleteReferences(_ refs: [Reference]) {
        let ids = refs.compactMap(\.id)
        do {
            let pdfPaths = try db.deleteReferencesReturningPDFPaths(ids: ids)
            for path in pdfPaths {
                PDFService.deletePDF(at: path)
            }
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func saveReference(_ ref: inout Reference) {
        ref.dateModified = Date()
        do {
            try db.saveReference(&ref)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func setTags(forReference refId: Int64, tagIds: [Int64]) {
        do {
            try db.setTags(forReference: refId, tagIds: tagIds)
        } catch {
            errorMessage = "Set tags failed: \(error.localizedDescription)"
        }
    }

    func createTagAndAssign(name: String, toReference refId: Int64) {
        do {
            let usedColors = Set(tags.map(\.color))
            let available = Tag.colorPalette.filter { !usedColors.contains($0) }
            let color = available.first ?? Tag.colorPalette.randomElement() ?? Tag.colorPalette[0]
            var tag = Tag(name: name, color: color)
            try db.saveTag(&tag)
            if let tagId = tag.id {
                let existingTagIds = (referenceTagMap[refId] ?? []).compactMap(\.id)
                try db.setTags(forReference: refId, tagIds: existingTagIds + [tagId])
            }
        } catch {
            errorMessage = "Create tag failed: \(error.localizedDescription)"
        }
    }

    func saveManualReference(_ ref: inout Reference, reviewedBy: String = "manual-entry") {
        if ref.id == nil && !ref.verificationStatus.isLibraryReady {
            ref = MetadataVerifier.manuallyVerified(ref, reviewedBy: reviewedBy)
        }
        saveReference(&ref)
    }

    func batchImportReferences(_ refs: [Reference]) {
        do {
            _ = try db.batchImportReferences(refs)
        } catch {
            errorMessage = "Batch import failed: \(error.localizedDescription)"
        }
    }

    func persistMetadataResolution(
        _ result: MetadataResolutionResult,
        options: MetadataPersistenceOptions
    ) -> MetadataPersistenceResult? {
        do {
            return try db.persistMetadataResolution(result, options: options)
        } catch {
            errorMessage = "Metadata persistence failed: \(error.localizedDescription)"
            return nil
        }
    }

    func confirmPendingMetadataIntake(_ intake: MetadataIntake, reviewedBy: String = "manual-queue") -> Reference? {
        do {
            return try db.confirmMetadataIntake(intake, reviewedBy: reviewedBy)
        } catch {
            errorMessage = "Manual verification failed: \(error.localizedDescription)"
            return nil
        }
    }

    func deletePendingMetadataIntake(_ intake: MetadataIntake) {
        guard let id = intake.id else { return }
        do {
            try db.deleteMetadataIntake(id: id)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func saveTag(_ tag: inout Tag) {
        do {
            try db.saveTag(&tag)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func deleteTag(id: Int64) {
        do {
            try db.deleteTag(id: id)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func saveDatabaseView(_ view: inout DatabaseView) {
        do {
            try db.saveDatabaseView(&view)
        } catch {
            errorMessage = "Save view failed: \(error.localizedDescription)"
        }
    }

    func deleteDatabaseView(id: Int64) {
        do {
            try db.deleteDatabaseView(id: id)
            if case .view(let selectedId) = selectedSidebar, selectedId == id {
                selectedSidebar = .allReferences
            }
        } catch {
            errorMessage = "Delete view failed: \(error.localizedDescription)"
        }
    }

    func createDatabaseView(name: String, scope: ViewScope = .all) {
        let maxOrder = databaseViews.map(\.displayOrder).max() ?? 0
        var view = DatabaseView(
            name: name,
            scope: scope,
            isDefault: false,
            displayOrder: maxOrder + 1
        )
        saveDatabaseView(&view)
        if let id = view.id {
            selectedSidebar = .view(id)
        }
    }

    func renameDatabaseView(id: Int64, name: String) {
        guard var view = databaseViews.first(where: { $0.id == id }) else { return }
        view.name = name
        saveDatabaseView(&view)
    }

    private func syncColumnConfigFromView() {
        guard case .view(let id) = selectedSidebar,
              let dbView = databaseViews.first(where: { $0.id == id }) else {
            tableSorts = [.defaultSort]
            viewFilters = []
            return
        }
        tableSorts = dbView.parsedSorts
        viewFilters = dbView.parsedFilters
    }

    func selectDefaultViewIfNeeded() {
        if case .allReferences = selectedSidebar,
           let defaultView = databaseViews.first(where: \.isDefault),
           let id = defaultView.id {
            selectedSidebar = .view(id)
        }
    }

    func importBibTeX(from url: URL) {
        isImporting = true
        importProgress = String(localized: "Reading file…", bundle: .module)

        Task.detached { [weak self] in
            guard let self else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                await MainActor.run {
                    self.importProgress = String(localized: "Parsing BibTeX…", bundle: .module)
                }

                let refs = BibTeXImporter.parse(content)
                await MainActor.run {
                    let fmt = String(localized: "Importing %d entries…", bundle: .module)
                    self.importProgress = String(format: fmt, refs.count)
                }

                let count = try self.db.batchImportReferences(refs)
                await MainActor.run {
                    let fmt = String(localized: "Imported %d entries", bundle: .module)
                    self.importProgress = String(format: fmt, count)
                    self.isImporting = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.importProgress = nil
                    }
                }
            } catch {
                await MainActor.run {
                    let fmt = String(localized: "content.import.error.generic", bundle: .module)
                    self.importProgress = String(format: fmt, error.localizedDescription)
                    self.isImporting = false
                }
            }
        }
    }

    func importRIS(from url: URL) {
        isImporting = true
        importProgress = String(localized: "Reading file…", bundle: .module)

        Task.detached { [weak self] in
            guard let self else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                await MainActor.run {
                    self.importProgress = String(localized: "Parsing RIS…", bundle: .module)
                }

                let refs = RISImporter.parse(content)
                await MainActor.run {
                    let fmt = String(localized: "Importing %d entries…", bundle: .module)
                    self.importProgress = String(format: fmt, refs.count)
                }

                let count = try self.db.batchImportReferences(refs)
                await MainActor.run {
                    let fmt = String(localized: "Imported %d entries", bundle: .module)
                    self.importProgress = String(format: fmt, count)
                    self.isImporting = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.importProgress = nil
                    }
                }
            } catch {
                await MainActor.run {
                    let fmt = String(localized: "content.import.error.generic", bundle: .module)
                    self.importProgress = String(format: fmt, error.localizedDescription)
                    self.isImporting = false
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @AppStorage("hasPromptedCLIInstallation") private var hasPromptedCLIInstallation = false
    @State private var showCLIInstallPrompt = false
    @State private var cliInstallResult: CLIInstallResult?
    @State private var showSearch = false
    @State private var showAddReference = false
    @State private var addReferenceInitialType: ReferenceType = .journalArticle
    @State private var showWebImport = false
    @State private var showAddByIdentifier = false
    @State private var showBatchImport = false
    @State private var showPendingMetadataQueue = false
    @State private var pendingQueueNotice: PendingQueueNotice?
    @State private var cslImportMessage: String?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedId: Int64?
    @State private var columnConfigs: [ColumnConfig] = {
        guard let data = UserDefaults.standard.data(forKey: RubienPreferences.columnConfigsKey),
              let decoded = try? JSONDecoder().decode([ColumnConfig].self, from: data) else {
            return ColumnConfig.defaultColumns
        }
        return decoded
    }()

    private struct PendingQueueNotice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var metadataResolver: MetadataResolver {
        MetadataResolver()
    }

    private var selectedReference: Reference? {
        guard let selectedId else { return nil }
        return viewModel.filteredReferences.first { $0.id == selectedId }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                databaseViews: viewModel.databaseViews,
                titleKeywords: viewModel.titleKeywords,
                selection: $viewModel.selectedSidebar,
                referenceCount: viewModel.references.count,
                onCreateView: { name in viewModel.createDatabaseView(name: name) },
                onDeleteView: { viewModel.deleteDatabaseView(id: $0) },
                onRenameView: { id, name in viewModel.renameDatabaseView(id: id, name: name) }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            ReferenceTableView(
                references: viewModel.filteredReferences,
                tagMap: viewModel.referenceTagMap,
                allTags: viewModel.tags,
                selectedId: selectedId,
                onSelect: { selectedId = $0 },
                onDelete: { deleteReferences($0) },
                onRefreshMetadata: { refs in refreshMetadata(for: refs) },
                onUpdateReference: { updated in
                    var ref = updated
                    viewModel.saveReference(&ref)
                },
                onUpdateTags: { refId, tagIds in viewModel.setTags(forReference: refId, tagIds: tagIds) },
                onCreateTag: { refId, name in viewModel.createTagAndAssign(name: name, toReference: refId) },
                onDeleteTag: { tagId in viewModel.deleteTag(id: tagId) },
                onCreateOption: { propId, optionValue in
                    guard var prop = viewModel.propertyDefs.first(where: { $0.id == propId }) else { return }
                    let usedColors = Set(prop.options.map(\.color))
                    let available = SelectOption.colorPalette.filter { !usedColors.contains($0) }
                    let color = available.first ?? SelectOption.colorPalette.randomElement() ?? "#007AFF"
                    var options = prop.options
                    options.append(SelectOption(value: optionValue, color: color))
                    prop.options = options
                    try? viewModel.db.savePropertyDefinition(&prop)
                },
                isRefreshingMetadata: viewModel.isImporting,
                onDoubleClick: { refId in
                    openReader(for: refId)
                },
                columnConfigs: $columnConfigs,
                sorts: $viewModel.tableSorts,
                filters: $viewModel.viewFilters,
                propertyDefs: Binding(
                    get: { viewModel.propertyDefs },
                    set: { viewModel.propertyDefs = $0 }
                ),
                db: viewModel.db,
                customPropertyValueMap: viewModel.customPropertyValueMap
            )
            .navigationSplitViewColumnWidth(min: 400, ideal: 600, max: .infinity)
        } detail: {
            Group {
            if let ref = selectedReference {
                ReferenceDetailView(
                    reference: ref,
                    allTags: viewModel.tags,
                    liveTags: viewModel.referenceTagMap[ref.id ?? -1] ?? [],
                    db: viewModel.db,
                    onSave: { updated in
                        var r = updated
                        viewModel.saveReference(&r)
                    },
                    onDelete: {
                        deleteReferences([ref])
                    },
                    onOpenPDFReader: { r in
                        ReaderWindowManager.shared.openPDFReader(for: r)
                    },
                    onOpenWebReader: { r in
                        ReaderWindowManager.shared.openWebReader(for: r)
                    },
                    onUpdateTags: { refId, tagIds in viewModel.setTags(forReference: refId, tagIds: tagIds) },
                    onCreateTag: { refId, name in viewModel.createTagAndAssign(name: name, toReference: refId) },
                    onDeleteTag: { tagId in viewModel.deleteTag(id: tagId) },
                    propertyDefs: Binding(
                        get: { viewModel.propertyDefs },
                        set: { viewModel.propertyDefs = $0 }
                    )
                )
            } else if selectedId != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a reference", bundle: .module)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(String(format: String(localized: "%d references", bundle: .module), viewModel.references.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 350, max: 350)
        }
        .toolbar(content: {
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                Button {
                    showSearch = true
                } label: {
                    Label(String(localized: "common.search", bundle: .module), systemImage: "magnifyingglass")
                }
                .help(String(localized: "Search references", bundle: .module))
                .keyboardShortcut("f", modifiers: .command)

                ControlGroup {
                    Button(action: {
                        addReferenceInitialType = .journalArticle
                        showAddReference = true
                    }) {
                        Label(String(localized: "New entry", bundle: .module), systemImage: "square.and.pencil")
                    }
                    .help(String(localized: "Create a blank reference and fill in its fields", bundle: .module))

                    Button(action: {
                        showWebImport = true
                    }) {
                        Label(String(localized: "Web clip", bundle: .module), systemImage: "globe")
                    }
                    .help(String(localized: "Paste a URL and let Rubien clip the title, abstract, and article body", bundle: .module))
                }

                ControlGroup {
                    Button(action: { showPendingMetadataQueue = true }) {
                        HStack(spacing: 6) {
                            Label(String(localized: "content.toolbar.pendingQueue", bundle: .module), systemImage: "clock.badge.exclamationmark")
                            if !viewModel.pendingMetadataIntakes.isEmpty {
                                Text("\(viewModel.pendingMetadataIntakes.count)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .help(String(localized: "Open the pending metadata queue to review candidates or confirm manually", bundle: .module))
                    .disabled(viewModel.pendingMetadataIntakes.isEmpty)

                    Button(action: { showAddByIdentifier = true }) {
                        Label(String(localized: "content.toolbar.addByIdentifier", bundle: .module), systemImage: "text.magnifyingglass")
                    }
                    .help(String(localized: "Paste a DOI, arXiv ID, PMID, or ISBN and fetch metadata automatically", bundle: .module))

                    Button(action: { importPDFWithMetadata() }) {
                        Label(String(localized: "content.toolbar.importPDF", bundle: .module), systemImage: "doc.badge.plus")
                    }
                    .help(String(localized: "Import a PDF and auto-fill its metadata when possible", bundle: .module))

                    Menu {
                        Button(String(localized: "content.toolbar.batchImport", bundle: .module) + "…") { showBatchImport = true }
                        Divider()
                        Button(String(localized: "content.toolbar.importBibTeX", bundle: .module)) { importBibTeX() }
                        Button(String(localized: "content.toolbar.importRIS", bundle: .module)) { importRIS() }
                        Divider()
                        Button(String(localized: "Import citation styles (.csl)…", bundle: .module)) { importCitationStyles() }
                    } label: {
                        Label(String(localized: "More import options", bundle: .module), systemImage: "tray.and.arrow.down")
                    }
                    .help(String(localized: "More import options", bundle: .module))
                    .disabled(viewModel.isImporting)
                }
                }
                .labelStyle(.titleAndIcon)
            }

        })
        .sheet(isPresented: $showAddReference) {
            AddReferenceView(
                allTags: viewModel.tags,
                onSave: { ref in
                    var r = ref
                    viewModel.saveManualReference(&r)
                },
                onCreateTag: { tag in
                    var t = tag
                    viewModel.saveTag(&t)
                },
                initialReferenceType: addReferenceInitialType
            )
        }
        .sheet(isPresented: $showWebImport) {
            WebImportView(
                onSave: { ref in
                    var r = ref
                    viewModel.saveManualReference(&r, reviewedBy: "web-import")
                }
            )
        }
        .sheet(isPresented: $showBatchImport) {
            BatchImportView(
                resolver: metadataResolver,
                onImport: { refs in
                viewModel.batchImportReferences(refs)
                },
                onQueueResult: { result, input in
                    queueResolutionResult(
                        result,
                        options: MetadataPersistenceOptions(
                            sourceKind: .batchIdentifier,
                            originalInput: input
                        ),
                        successMessage: String(localized: "Queued for review", bundle: .module)
                    )
                }
            )
        }
        .overlay {
            if showSearch {
                SearchOverlay(
                    db: viewModel.db,
                    scope: viewModel.currentReferenceScope,
                    isPresented: $showSearch,
                    onSelect: { ref in
                        selectedId = ref.id
                    },
                    onDeleteMultiple: { refs in
                        deleteReferences(refs)
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            if let progress = viewModel.importProgress {
                FloatingProgressToast(
                    message: progress,
                    isSpinning: viewModel.isImporting
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: progress)
            }
        }
        .sheet(isPresented: $showAddByIdentifier) {
            AddByIdentifierView(
                resolver: metadataResolver,
                onSave: { ref in
                    var r = ref
                    viewModel.saveReference(&r)
                },
                onQueueResult: { result, input in
                    queueResolutionResult(
                        result,
                        options: MetadataPersistenceOptions(
                            sourceKind: .manualEntry,
                            originalInput: input
                        ),
                        successMessage: String(localized: "Queued for review", bundle: .module)
                    )
                }
            )
        }
        .sheet(isPresented: $showPendingMetadataQueue) {
            PendingMetadataQueueView(
                intakes: viewModel.pendingMetadataIntakes,
                resolver: metadataResolver,
                onPersistResult: { result, intake in
                    queueResolutionResult(
                        result,
                        options: MetadataPersistenceOptions(
                            sourceKind: intake.sourceKind,
                            originalInput: intake.originalInput,
                            preferredPDFPath: intake.pdfPath,
                            linkedReferenceId: intake.linkedReferenceId,
                            existingIntakeId: intake.id
                        ),
                        successMessage: nil
                    )
                },
                onConfirmManual: { intake in
                    if let reference = viewModel.confirmPendingMetadataIntake(intake) {
                        selectedId = reference.id
                    }
                },
                onDelete: { intake in
                    viewModel.deletePendingMetadataIntake(intake)
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let msg = cslImportMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice = pendingQueueNotice {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "tray.full.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.title)
                                .font(.headline)
                            Text(notice.message)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button {
                            pendingQueueNotice = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(String(localized: "Open pending queue", bundle: .module)) {
                            pendingQueueNotice = nil
                            showPendingMetadataQueue = true
                        }
                        .buttonStyle(SLPrimaryButtonStyle())

                        Button(String(localized: "Later", bundle: .module)) {
                            pendingQueueNotice = nil
                        }
                        .buttonStyle(SLSecondaryButtonStyle())
                    }
                }
                .padding(14)
                .frame(maxWidth: 360, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .padding(.trailing, 20)
                .padding(.bottom, 20)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: cslImportMessage)
        .animation(.easeInOut(duration: 0.2), value: pendingQueueNotice)
        .onChange(of: viewModel.references) { _, newRefs in
            guard let selectedId else { return }
            if !newRefs.contains(where: { $0.id == selectedId }) {
                self.selectedId = nil
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
            guard let id = note.userInfo?[RubienClipImportedKeys.id] as? Int64 else { return }
            selectedId = id
            columnVisibility = .all
        }
        .alert(String(localized: "Operation failed", bundle: .module), isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(String(localized: "common.ok", bundle: .module)) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: columnConfigs) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: RubienPreferences.columnConfigsKey)
            }
        }
        .onAppear {
            // Skip the install prompt when running via `swift run` from .build/ —
            // /usr/local/bin isn't writable in that context and the prompt can't succeed.
            if !hasPromptedCLIInstallation
                && !CLIInstaller.isInstalled
                && !CLIInstaller.isRunningFromDevBuild {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showCLIInstallPrompt = true
                }
            }
        }
        .alert(
            String(localized: "content.cli.installPrompt.title", bundle: .module),
            isPresented: $showCLIInstallPrompt
        ) {
            Button(String(localized: "content.cli.installPrompt.install", bundle: .module)) {
                hasPromptedCLIInstallation = true
                do {
                    try CLIInstaller.install()
                    cliInstallResult = .success
                } catch {
                    cliInstallResult = .failure(error.localizedDescription)
                }
            }
            Button(String(localized: "content.cli.installPrompt.later", bundle: .module), role: .cancel) {
                hasPromptedCLIInstallation = true
            }
        } message: {
            Text("content.cli.installPrompt.message", bundle: .module)
        }
        .alert(
            cliInstallResult?.isSuccess == true
                ? String(localized: "Install succeeded", bundle: .module)
                : String(localized: "Install failed", bundle: .module),
            isPresented: Binding(
                get: { cliInstallResult != nil },
                set: { if !$0 { cliInstallResult = nil } }
            )
        ) {
            Button(String(localized: "common.ok", bundle: .module)) { cliInstallResult = nil }
        } message: {
            Text(cliInstallResult?.message ?? "")
        }
    }

    private func importBibTeX() {
        guard let url = OpenPanelPicker.pickBibTeXFile() else { return }
        viewModel.importBibTeX(from: url)
    }

    private func importRIS() {
        guard let url = OpenPanelPicker.pickRISFile() else { return }
        viewModel.importRIS(from: url)
    }

    private func importPDFWithMetadata() {
        guard let url = OpenPanelPicker.pickPDFFile() else { return }
        viewModel.isImporting = true
        viewModel.importProgress = String(localized: "content.import.progress.importingPDF", bundle: .module)

        Task { @MainActor in
            do {
                let prepared = try PDFService.prepareImportedPDF(from: url)
                let fallbackReference = prepared.reference
                _ = MetadataResolutionSeed.fromImportedPDF(url: url, extracted: prepared.extracted)

                if let doi = prepared.extracted.doi, !doi.isEmpty {
                    let fmt = String(localized: "content.import.progress.fetchingMetadata", bundle: .module)
                    viewModel.importProgress = String(format: fmt, doi)
                }

                let resolution = await metadataResolver.resolveImportedPDF(url: url, extracted: prepared.extracted)

                switch resolution {
                case .verified(let envelope):
                    var reference = envelope.reference
                    reference.pdfPath = fallbackReference.pdfPath
                    let fmt = String(localized: "Imported: %@", bundle: .module)
                    finishPDFImport(with: reference, message: String(format: fmt, reference.title))

                case .candidate, .blocked, .seedOnly, .rejected:
                    let queued = queueResolutionResult(
                        resolution,
                        options: MetadataPersistenceOptions(
                            sourceKind: .importedPDF,
                            preferredPDFPath: fallbackReference.pdfPath
                        ),
                        successMessage: String(localized: "Couldn't auto-verify — added to the pending queue", bundle: .module)
                    )
                    if queued == nil, let pdfPath = fallbackReference.pdfPath {
                        PDFService.deletePDF(at: pdfPath)
                    }
                }
            } catch {
                viewModel.isImporting = false
                viewModel.importProgress = nil
                let fmt = String(localized: "PDF import failed: %@", bundle: .module)
                viewModel.errorMessage = String(format: fmt, error.localizedDescription)
            }
        }
    }

    private func finishPDFImport(with reference: Reference, message: String?) {
        var mutable = reference
        viewModel.saveReference(&mutable)
        selectedId = mutable.id
        viewModel.isImporting = false
        viewModel.importProgress = message

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if !viewModel.isImporting {
                viewModel.importProgress = nil
            }
        }
    }

    private func refreshMetadata(for references: [Reference]) {
        let candidates = references.compactMap { reference -> Reference? in
            guard reference.id != nil else { return nil }
            return reference
        }
        guard !candidates.isEmpty else { return }

        if candidates.count == 1, let reference = candidates.first {
            refreshSingleReferenceMetadata(reference)
        } else {
            refreshBatchMetadata(for: candidates)
        }
    }

    private func refreshSingleReferenceMetadata(_ reference: Reference) {
        viewModel.isImporting = true
        viewModel.importProgress = String(localized: "Refreshing metadata…", bundle: .module)

        Task { @MainActor in
            let result = await metadataResolver.refreshReference(reference, allowCandidateSelection: true)
            switch result {
            case .refreshed(let refreshed):
                let fmt = String(localized: "Refreshed: %@", bundle: .module)
                saveRefreshedReference(refreshed, message: String(format: fmt, refreshed.title))

            case .pending(let pendingResult):
                _ = queueResolutionResult(
                    pendingResult,
                    options: MetadataPersistenceOptions(
                        sourceKind: .refresh,
                        originalInput: reference.doi ?? reference.pmid ?? reference.isbn ?? reference.title,
                        linkedReferenceId: reference.id
                    ),
                    successMessage: String(localized: "Queued for review", bundle: .module)
                )

            case .skipped(let reason):
                viewModel.isImporting = false
                viewModel.importProgress = reason
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if !viewModel.isImporting {
                        viewModel.importProgress = nil
                    }
                }

            case .failed(let message):
                viewModel.isImporting = false
                viewModel.importProgress = nil
                viewModel.errorMessage = message
            }
        }
    }

    private func refreshBatchMetadata(for references: [Reference]) {
        viewModel.isImporting = true
        let fmt = String(localized: "Preparing to refresh %d references…", bundle: .module)
        viewModel.importProgress = String(format: fmt, references.count)

        Task { @MainActor in
            var refreshedCount = 0
            var skippedCount = 0
            var failedMessages: [String] = []
            let total = references.count
            let maxConcurrency = 3

            // Process in concurrent batches to improve performance while
            // limiting parallelism to avoid API rate-limiting.
            for batchStart in stride(from: 0, to: total, by: maxConcurrency) {
                let batchEnd = min(batchStart + maxConcurrency, total)
                let batch = Array(references[batchStart..<batchEnd])

                let progressFmt = String(localized: "Refreshing %d–%d of %d…", bundle: .module)
                viewModel.importProgress = String(format: progressFmt, batchStart + 1, batchEnd, total)

                let batchResults: [(Reference, ReferenceMetadataRefreshResult)] = await withTaskGroup(
                    of: (Reference, ReferenceMetadataRefreshResult).self,
                    returning: [(Reference, ReferenceMetadataRefreshResult)].self
                ) { group in
                    for reference in batch {
                        group.addTask {
                            let result = await metadataResolver.refreshReference(reference, allowCandidateSelection: false)
                            return (reference, result)
                        }
                    }
                    var results: [(Reference, ReferenceMetadataRefreshResult)] = []
                    for await pair in group {
                        results.append(pair)
                    }
                    return results
                }

                for (reference, result) in batchResults {
                    switch result {
                    case .refreshed(let refreshed):
                        saveRefreshedReference(refreshed, message: nil, finishRefreshing: false, clearProgress: false)
                        refreshedCount += 1
                    case .pending(let pendingResult):
                        _ = queueResolutionResult(
                            pendingResult,
                            options: MetadataPersistenceOptions(
                                sourceKind: .refresh,
                                originalInput: reference.doi ?? reference.pmid ?? reference.isbn ?? reference.title,
                                linkedReferenceId: reference.id
                            ),
                            successMessage: nil
                        )
                        skippedCount += 1
                    case .skipped:
                        skippedCount += 1
                    case .failed(let message):
                        failedMessages.append("\(reference.title): \(message)")
                    }
                }
            }

            viewModel.isImporting = false
            let summaryFmt = String(localized: "Batch refresh complete: %d updated, %d skipped, %d failed", bundle: .module)
            viewModel.importProgress = String(format: summaryFmt, refreshedCount, skippedCount, failedMessages.count)

            if !failedMessages.isEmpty {
                viewModel.errorMessage = failedMessages.prefix(5).joined(separator: "\n")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !viewModel.isImporting {
                    viewModel.importProgress = nil
                }
            }
        }
    }

    private func saveRefreshedReference(
        _ reference: Reference,
        message: String?,
        finishRefreshing: Bool = true,
        clearProgress: Bool = true
    ) {
        var mutable = reference
        viewModel.saveReference(&mutable)
        viewModel.isImporting = !finishRefreshing ? viewModel.isImporting : false
        viewModel.importProgress = message

        guard clearProgress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if !viewModel.isImporting {
                viewModel.importProgress = nil
            }
        }
    }

    @discardableResult
    private func queueResolutionResult(
        _ result: MetadataResolutionResult,
        options: MetadataPersistenceOptions,
        successMessage: String?
    ) -> MetadataPersistenceResult? {
        let persisted = viewModel.persistMetadataResolution(result, options: options)
        switch persisted {
        case .verified(let reference):
            selectedId = reference.id
            viewModel.isImporting = false
            let verifiedFmt = String(localized: "Verified: %@", bundle: .module)
            viewModel.importProgress = successMessage ?? String(format: verifiedFmt, reference.title)
            pendingQueueNotice = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if !viewModel.isImporting {
                    viewModel.importProgress = nil
                }
            }
        case .intake(let intake):
            viewModel.isImporting = false
            viewModel.importProgress = nil
            showPendingQueueNotice(for: intake, message: successMessage)
        case .none:
            viewModel.isImporting = false
            viewModel.importProgress = nil
        }

        return persisted
    }

    private func showPendingQueueNotice(for intake: MetadataIntake, message: String?) {
        let title = String(localized: "This metadata needs your review", bundle: .module)
        let lead: String
        if intake.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lead = String(localized: "The entry", bundle: .module)
        } else {
            lead = "“\(intake.title)”"
        }
        let detail = message?.rubien_nilIfBlank
            ?? intake.statusMessage?.rubien_nilIfBlank
            ?? String(localized: "is waiting in the pending queue.", bundle: .module)

        let bodyFmt = String(localized: "%@ %@ Open the queue to continue.", bundle: .module)
        let notice = PendingQueueNotice(
            title: title,
            message: String(format: bodyFmt, lead, detail)
        )
        pendingQueueNotice = notice

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if pendingQueueNotice?.id == notice.id {
                pendingQueueNotice = nil
            }
        }
    }

    private func importCitationStyles() {
        let urls = OpenPanelPicker.pickCitationStyleFiles()
        guard !urls.isEmpty else { return }

        var imported: [String] = []
        for url in urls {
            if let title = try? CSLManager.shared.importCSL(from: url) {
                imported.append(title)
            }
        }

        guard !imported.isEmpty else { return }

        let fmt = String(localized: "Imported: %@", bundle: .module)
        cslImportMessage = String(format: fmt, imported.joined(separator: ", "))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            cslImportMessage = nil
        }
    }

    private func deleteReferences(_ references: [Reference]) {
        let ids = references.compactMap(\.id)
        if let selectedId, ids.contains(selectedId) {
            self.selectedId = nil
        }
        viewModel.deleteReferences(references)
    }

    private func openReader(for referenceID: Int64) {
        guard let reference = try? viewModel.db.fetchReferences(ids: [referenceID]).first else { return }
        if reference.pdfPath != nil {
            ReaderWindowManager.shared.openPDFReader(for: reference)
        } else if reference.canOpenWebReader {
            ReaderWindowManager.shared.openWebReader(for: reference)
        }
    }
}

private struct FloatingProgressToast: View {
    let message: String
    let isSpinning: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isSpinning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.85)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            }

            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        }
        .padding(.top, 10)
        .allowsHitTesting(false)
    }
}

// MARK: - CLI Install Result

private enum CLIInstallResult {
    case success
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success:
            let fmt = String(localized: "content.cli.install.success", bundle: .module)
            return String(format: fmt, CLIInstaller.installURL.path)
        case .failure(let reason):
            let fmt = String(localized: "content.cli.install.failure", bundle: .module)
            return String(format: fmt, reason)
        }
    }
}
