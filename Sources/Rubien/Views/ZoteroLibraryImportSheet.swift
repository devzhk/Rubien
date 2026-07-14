#if os(macOS)
import AppKit
import SwiftUI
import RubienCore
import RubienPDFKit

struct ZoteroLibraryImportRequest {
    let scope: ZoteroLibraryScope
    let collections: [ZoteroLibraryCollection]
    let includeSubcollections: Bool
    let includeAnnotations: Bool
    let propertyTarget: ZoteroImportPropertyTarget
}

enum ZoteroLibraryImportPresentation {
    static func scope(
        entireLibrary: Bool,
        selectedKeys: Set<String>
    ) -> ZoteroLibraryScope? {
        if entireLibrary { return .entireLibrary }
        return selectedKeys.isEmpty ? nil : .collections(selectedKeys)
    }

    static func attachmentSummary(for item: ZoteroLibraryItemSummary) -> String {
        switch item.pdfFilenames.count {
        case 0:
            return "Zotero reference"
        case 1:
            return item.pdfFilenames[0]
        default:
            return "\(item.pdfFilenames.count) PDFs: \(item.pdfFilenames.joined(separator: ", "))"
        }
    }

    static func stampSuggestion(
        entireLibrary: Bool,
        selectedKeys: Set<String>,
        collections: [ZoteroLibraryCollection]
    ) -> String {
        guard !entireLibrary,
              selectedKeys.count == 1,
              let key = selectedKeys.first,
              let collection = collections.first(where: { $0.key == key })
        else { return "Zotero" }
        return collection.name
    }

    static func selectionSummary(
        entireLibrary: Bool,
        selectedKeys: Set<String>,
        collections: [ZoteroLibraryCollection],
        includeSubcollections: Bool
    ) -> String {
        if entireLibrary { return "All references in My Library" }
        guard !selectedKeys.isEmpty else { return "Select one or more collections" }
        let effectiveKeys = includeSubcollections
            ? ZoteroLibraryCollectionTree.expandingDescendants(
                of: selectedKeys,
                in: collections
            )
            : selectedKeys
        let noun = effectiveKeys.count == 1 ? "collection" : "collections"
        return "\(effectiveKeys.count) \(noun) will be scanned"
    }
}

/// Connects to Zotero desktop, then lets the user choose an import scope before
/// handing preparation back to ContentView. This sheet never mutates Rubien or
/// Zotero; confirmation still flows through the shared review/commit pipeline.
struct ZoteroLibraryImportSheet: View {
    private enum LoadState {
        case loading
        case loaded([ZoteroLibraryCollection])
        case failed(ZoteroLocalAPIError)
        case failedMessage(String)
    }

    private enum CollectionItemsLoadState {
        case loading
        case loaded([ZoteroLibraryItemSummary])
        case failed(String)
    }

    let db: AppDatabase
    let client: ZoteroLocalAPIClient
    let onConfirm: (ZoteroLibraryImportRequest) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var loadState: LoadState = .loading
    @State private var loadGeneration = 0
    @State private var collectionFilter = ""
    @State private var expandedCollectionKeys: Set<String> = []
    @State private var collectionItemsByKey: [String: CollectionItemsLoadState] = [:]
    @State private var nextCollectionItemsLoadGeneration = 0
    @State private var collectionItemsLoadGenerationByKey: [String: Int] = [:]
    @State private var collectionItemTasks: [String: Task<Void, Never>] = [:]
    @State private var entireLibrary = false
    @State private var selectedCollectionKeys: Set<String> = []
    @State private var includeSubcollections = true
    @State private var includeAnnotations = true
    @State private var allProperties: [PropertyDefinition] = []
    @State private var selectedPropertyId: Int64?
    @State private var stampValue = "Zotero"
    @State private var lastSuggestedStamp = "Zotero"
    @State private var validationError: String?

    init(
        db: AppDatabase,
        client: ZoteroLocalAPIClient = ZoteroLocalAPIClient(),
        onConfirm: @escaping (ZoteroLibraryImportRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.db = db
        self.client = client
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var allowedProperties: [PropertyDefinition] {
        ZoteroImportPropertyPresentation.allowedProperties(from: allProperties)
    }

    private var loadedCollections: [ZoteroLibraryCollection]? {
        guard case .loaded(let collections) = loadState else { return nil }
        return collections
    }

    private var canImport: Bool {
        guard loadedCollections != nil,
              entireLibrary || !selectedCollectionKeys.isEmpty,
              selectedPropertyId != nil
        else { return false }
        return !stampValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)

            Divider()

            Group {
                switch loadState {
                case .loading:
                    loadingView
                case .loaded(let collections):
                    loadedView(collections: collections)
                case .failed(let error):
                    failureView(error: error)
                case .failedMessage(let message):
                    failureView(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(16)
        }
        .frame(minWidth: 620, minHeight: 650)
        .task(id: loadGeneration) {
            loadPropertiesIfNeeded()
            await loadCollections()
        }
        .onDisappear {
            cancelCollectionItemLoads()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from Zotero")
                    .font(.title2.bold())
                Text("Choose collections, expand them to preview papers, and set import options.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Looking for Zotero…")
                .font(.headline)
            Text("Rubien connects only to Zotero on this Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func loadedView(collections: [ZoteroLibraryCollection]) -> some View {
        let rows = ZoteroLibraryCollectionTree.rows(from: collections)
        let visibleRows = collectionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rows
            : rows.filter {
                $0.path.localizedCaseInsensitiveContains(collectionFilter)
            }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("Filter collections", text: $collectionFilter)
                    .textFieldStyle(.roundedBorder)
                Button("Select All") {
                    entireLibrary = true
                    selectedCollectionKeys = Set(collections.map(\.key))
                    refreshStampSuggestion(collections: collections)
                }
                .disabled(entireLibrary)
                .controlSize(.small)
                .buttonStyle(SLSecondaryButtonStyle())
                .help("Select every collection and include unfiled references")
                Button("None") {
                    entireLibrary = false
                    selectedCollectionKeys.removeAll()
                    refreshStampSuggestion(collections: collections)
                }
                .disabled(selectedCollectionKeys.isEmpty && !entireLibrary)
                .controlSize(.small)
                .buttonStyle(SLSecondaryButtonStyle())
            }

            GroupBox {
                if collections.isEmpty {
                    ContentUnavailableView(
                        "No Zotero Collections",
                        systemImage: "folder",
                        description: Text("Use Select All to import unfiled references.")
                    )
                } else if visibleRows.isEmpty {
                    ContentUnavailableView.search(text: collectionFilter)
                } else {
                    List {
                        ForEach(visibleRows) { row in
                            collectionRow(row, collections: collections)

                            if expandedCollectionKeys.contains(row.collection.key) {
                                collectionItemRows(for: row)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            } label: {
                Text("Collections")
            }
            .frame(minHeight: 210)

            HStack(spacing: 18) {
                Toggle("Include subcollections", isOn: $includeSubcollections)
                    .toggleStyle(HoverCheckboxToggleStyle())
                Toggle("Import PDF annotations", isOn: $includeAnnotations)
                    .toggleStyle(HoverCheckboxToggleStyle())
                Spacer()
                Text(
                    ZoteroLibraryImportPresentation.selectionSummary(
                        entireLibrary: entireLibrary,
                        selectedKeys: selectedCollectionKeys,
                        collections: collections,
                        includeSubcollections: includeSubcollections
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            ZoteroImportStampFields(
                properties: allowedProperties,
                selectedPropertyId: $selectedPropertyId,
                stampValue: $stampValue
            )

            if let validationError {
                HStack(spacing: 8) {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if selectedPropertyId == nil && allProperties.isEmpty {
                        Button("Try Again") {
                            self.validationError = nil
                            loadPropertiesIfNeeded()
                        }
                        .controlSize(.small)
                        .buttonStyle(SLSecondaryButtonStyle())
                    }
                }
            }
        }
        .padding(20)
    }

    private func collectionRow(
        _ row: ZoteroLibraryCollectionRow,
        collections: [ZoteroLibraryCollection]
    ) -> some View {
        HStack(spacing: 4) {
            if row.collection.itemCount > 0 {
                Button {
                    toggleCollectionExpansion(row.collection)
                } label: {
                    Image(
                        systemName: expandedCollectionKeys.contains(row.collection.key)
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.caption2.weight(.semibold))
                    .frame(width: 12, height: 12)
                }
                .buttonStyle(CompactHoverButtonStyle())
                .help(
                    expandedCollectionKeys.contains(row.collection.key)
                        ? "Collapse papers"
                        : "Preview papers"
                )
                .accessibilityLabel("Preview papers in \(row.collection.name)")
                .accessibilityValue(
                    expandedCollectionKeys.contains(row.collection.key)
                        ? "Expanded"
                        : "Collapsed"
                )
            } else {
                Color.clear
                    .frame(width: 22, height: 22)
            }

            Toggle(isOn: Binding(
                get: { selectedCollectionKeys.contains(row.collection.key) },
                set: { selected in
                    if selected {
                        selectedCollectionKeys.insert(row.collection.key)
                        entireLibrary = false
                    } else {
                        selectedCollectionKeys.remove(row.collection.key)
                        entireLibrary = false
                    }
                    refreshStampSuggestion(collections: collections)
                }
            )) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(row.collection.name)
                        .lineLimit(1)
                    Spacer()
                    Text("\(row.collection.itemCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("References directly in this collection")
                }
            }
            .toggleStyle(HoverCheckboxToggleStyle())
        }
        .padding(.leading, CGFloat(row.depth) * 18)
    }

    @ViewBuilder
    private func collectionItemRows(for row: ZoteroLibraryCollectionRow) -> some View {
        let collectionKey = row.collection.key
        let itemIndent = CGFloat(row.depth + 1) * 18 + 28

        switch collectionItemsByKey[collectionKey] {
        case .loading, .none:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading papers…")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.leading, itemIndent)

        case .loaded(let items) where items.isEmpty:
            Label("No papers directly in this collection", systemImage: "doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, itemIndent)

        case .loaded(let items):
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.pdfFilenames.isEmpty ? "doc.text" : "doc.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .lineLimit(1)
                        Text(ZoteroLibraryImportPresentation.attachmentSummary(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(ZoteroLibraryImportPresentation.attachmentSummary(for: item))
                    }
                }
                .padding(.leading, itemIndent)
                .id("\(collectionKey)/\(item.key)")
            }
            if row.collection.itemCount > items.count {
                Label(
                    "Showing the first \(items.count) of \(row.collection.itemCount) references",
                    systemImage: "ellipsis"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, itemIndent)
            }

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Try Again") {
                    loadCollectionItems(collectionKey: collectionKey)
                }
                .controlSize(.small)
                .buttonStyle(SLSecondaryButtonStyle())
            }
            .padding(.leading, itemIndent)
        }
    }

    private func failureView(error: ZoteroLocalAPIError) -> some View {
        let title: String
        let icon: String
        switch error {
        case .accessDisabled:
            title = "Allow Zotero Library Access"
            icon = "lock"
        case .notRunning:
            title = "Zotero Is Not Available"
            icon = "books.vertical"
        default:
            title = "Could Not Read Zotero"
            icon = "exclamationmark.triangle"
        }

        return failureContent(
            title: title,
            icon: icon,
            message: error.localizedDescription,
            showOpenZotero: error == .notRunning
        )
    }

    private func failureView(message: String) -> some View {
        failureContent(
            title: "Could Not Read Zotero",
            icon: "exclamationmark.triangle",
            message: message,
            showOpenZotero: false
        )
    }

    private func failureContent(
        title: String,
        icon: String,
        message: String,
        showOpenZotero: Bool
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            HStack {
                if showOpenZotero {
                    Button("Open Zotero") { openZotero() }
                        .buttonStyle(SLSecondaryButtonStyle())
                }
                Button("Try Again") { retry() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SLPrimaryButtonStyle())
            }
        }
        .padding(30)
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .focusEffectDisabled()
            .buttonStyle(SLSecondaryButtonStyle())

            Button("Continue") { confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
                .buttonStyle(SLPrimaryButtonStyle())
        }
    }

    @MainActor
    private func loadPropertiesIfNeeded() {
        guard allProperties.isEmpty else { return }
        do {
            let properties = try db.fetchAllPropertyDefinitions()
            allProperties = properties
            selectedPropertyId = ZoteroImportPropertyPresentation.defaultPropertyID(in: properties)
        } catch {
            validationError = "Failed to load properties: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadCollections() async {
        loadState = .loading
        expandedCollectionKeys.removeAll()
        collectionItemsByKey.removeAll()
        cancelCollectionItemLoads()
        do {
            loadState = .loaded(try await client.fetchCollections())
        } catch let error as ZoteroLocalAPIError {
            loadState = .failed(error)
        } catch is CancellationError {
            return
        } catch {
            loadState = .failedMessage(error.localizedDescription)
        }
    }

    private func toggleCollectionExpansion(_ collection: ZoteroLibraryCollection) {
        let key = collection.key
        if expandedCollectionKeys.remove(key) != nil {
            collectionItemTasks.removeValue(forKey: key)?.cancel()
            collectionItemsLoadGenerationByKey.removeValue(forKey: key)
            if case .loading? = collectionItemsByKey[key] {
                collectionItemsByKey.removeValue(forKey: key)
            }
            return
        }

        expandedCollectionKeys.insert(key)
        guard collectionItemsByKey[key] == nil else { return }
        loadCollectionItems(collectionKey: key)
    }

    private func loadCollectionItems(collectionKey: String) {
        collectionItemTasks.removeValue(forKey: collectionKey)?.cancel()
        nextCollectionItemsLoadGeneration &+= 1
        let generation = nextCollectionItemsLoadGeneration
        collectionItemsLoadGenerationByKey[collectionKey] = generation
        collectionItemsByKey[collectionKey] = .loading
        collectionItemTasks[collectionKey] = Task { @MainActor in
            defer {
                if collectionItemsLoadGenerationByKey[collectionKey] == generation {
                    collectionItemTasks.removeValue(forKey: collectionKey)
                }
            }
            do {
                let items = try await client.fetchCollectionItems(collectionKey: collectionKey)
                guard collectionItemsLoadGenerationByKey[collectionKey] == generation else {
                    return
                }
                collectionItemsByKey[collectionKey] = .loaded(items)
            } catch is CancellationError {
                return
            } catch {
                guard collectionItemsLoadGenerationByKey[collectionKey] == generation else {
                    return
                }
                collectionItemsByKey[collectionKey] = .failed(error.localizedDescription)
            }
        }
    }

    private func invalidateCollectionItemLoads() {
        nextCollectionItemsLoadGeneration &+= 1
        collectionItemsLoadGenerationByKey.removeAll()
    }

    private func cancelCollectionItemLoads() {
        for task in collectionItemTasks.values {
            task.cancel()
        }
        collectionItemTasks.removeAll()
        invalidateCollectionItemLoads()
    }

    private func retry() {
        validationError = nil
        loadGeneration &+= 1
    }

    private func refreshStampSuggestion(collections: [ZoteroLibraryCollection]) {
        let suggestion = ZoteroLibraryImportPresentation.stampSuggestion(
            entireLibrary: entireLibrary,
            selectedKeys: selectedCollectionKeys,
            collections: collections
        )
        if stampValue == lastSuggestedStamp {
            stampValue = suggestion
        }
        lastSuggestedStamp = suggestion
    }

    private func confirm() {
        validationError = nil
        guard let collections = loadedCollections else { return }
        guard let scope = ZoteroLibraryImportPresentation.scope(
            entireLibrary: entireLibrary,
            selectedKeys: selectedCollectionKeys
        ) else {
            validationError = "Select at least one collection."
            return
        }
        guard let propertyID = selectedPropertyId else {
            validationError = "Select a property."
            return
        }
        let value = stampValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            validationError = "Value cannot be empty."
            return
        }

        onConfirm(
            ZoteroLibraryImportRequest(
                scope: scope,
                collections: collections,
                includeSubcollections: includeSubcollections,
                includeAnnotations: includeAnnotations,
                propertyTarget: ZoteroImportPropertyTarget(
                    propertyId: propertyID,
                    value: value
                )
            )
        )
        dismiss()
    }

    private func openZotero() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "org.zotero.zotero"
        ) else {
            validationError = "Zotero is not installed in an application location macOS can find."
            return
        }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                Task { @MainActor in
                    validationError = "Could not open Zotero: \(error.localizedDescription)"
                }
            }
        }
    }
}
#endif
