#if os(macOS)
import SwiftUI
import RubienCore

/// One presentation of the chooser sheet; the model lives as long as the sheet.
struct SupplementAttachPresentation: Identifiable {
    let id = UUID()
    let model: SupplementAttachChoiceModel
}

/// "Add ‹card title›": attach an Assistant card's PDF/Markdown file to a
/// library reference, or continue to the unchanged Add Reference flow.
struct SupplementAttachSheet: View {
    @ObservedObject var model: SupplementAttachChoiceModel
    /// Closes the sheet and calls the existing add-source route with the URL.
    let onContinueToNewReference: (String) -> Void
    let onDismiss: () -> Void

    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Matches AddReferenceSourceSheet, which "Continue…" opens next:
        // 16 pt rhythm, 20 pt padding, 520 pt width, SL button styles.
        VStack(alignment: .leading, spacing: 16) {
            header
            if case .finished = model.phase {
                result
            } else {
                choices
                if model.isAttachSelected {
                    nameField
                }
                status
            }
            buttons
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .onChange(of: model.searchQuery) { _, _ in scheduleSearch() }
        .onDisappear {
            searchTask?.cancel()
            model.cancelAttach()
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Add “\(model.cardTitle)”")
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !model.subtitle.isEmpty {
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.suggestions) { suggestion in
                radioRow(isSelected: model.choice == .attach(referenceId: suggestion.referenceId)) {
                    model.choice = .attach(referenceId: suggestion.referenceId)
                } label: {
                    attachLabel(title: suggestion.title, caption: suggestion.reason.label)
                }
            }
            anotherReferenceRow
            radioRow(isSelected: model.choice == .newReference) {
                model.choice = .newReference
            } label: {
                Text("Add as a new reference")
            }
        }
        .disabled(model.isWorking)
    }

    private var anotherReferenceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            radioRow(isSelected: model.isSearchedTargetSelected) {
                if let target = model.searchedTarget {
                    model.selectSearchResult(target)
                } else {
                    searchFocused = true
                }
            } label: {
                if let target = model.searchedTarget {
                    attachLabel(title: target.title, caption: "Chosen from the library")
                } else {
                    Text("Attach to another reference…")
                }
            }
            TextField("Search library…", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.leading, 24)
            if !model.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.searchResults) { target in
                        SearchResultRow(title: target.title) {
                            model.selectSearchResult(target)
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Attachment name")
                TextField("Attachment name", text: $model.attachmentName)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            if let message = model.nameValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .disabled(model.isWorking)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Try again") { model.retry() }
                    .buttonStyle(SLSecondaryButtonStyle())
                    .disabled(!model.canPerformPrimary)
            }
        case .choosing, .finished:
            EmptyView()
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(model.resultMessage ?? "")
                    .font(.body.weight(.medium))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let message = model.openErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            if case .finished = model.phase {
                Button("Open") {
                    Task { await model.openAttachment() }
                }
                .buttonStyle(SLSecondaryButtonStyle())
                Button("Done") { onDismiss() }
                    .buttonStyle(SLPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") {
                    if model.isWorking {
                        model.cancelAttach()
                    } else {
                        onDismiss()
                    }
                }
                .buttonStyle(SLSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button(model.primaryButtonTitle) {
                    if case .continueToNewReference(let url) = model.performPrimary() {
                        onContinueToNewReference(url)
                    }
                }
                .buttonStyle(SLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canPerformPrimary)
            }
        }
    }

    // MARK: Pieces

    private func radioRow<Label: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                label()
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func attachLabel(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Attach to")
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(2)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await model.runSearch()
        }
    }
}

/// One library search result: a full-width row with the app's light hover fill.
private struct SearchResultRow: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
    }
}
#endif
