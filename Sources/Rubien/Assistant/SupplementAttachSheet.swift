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
        VStack(alignment: .leading, spacing: 14) {
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
        .frame(width: 500)
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
                    .font(.subheadline)
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
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.searchResults) { target in
                        Button {
                            model.selectSearchResult(target)
                        } label: {
                            Text(target.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
                Text("Downloading…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try again") { model.retry() }
                    .disabled(!model.canPerformPrimary)
            }
        case .choosing, .finished:
            EmptyView()
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.resultMessage ?? "", systemImage: "checkmark.circle.fill")
                .font(.body.weight(.medium))
            if let message = model.openErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            if case .finished = model.phase {
                Button("Open") {
                    Task { await model.openAttachment() }
                }
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") {
                    if model.isWorking {
                        model.cancelAttach()
                    } else {
                        onDismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button(model.primaryButtonTitle) {
                    if case .continueToNewReference(let url) = model.performPrimary() {
                        onContinueToNewReference(url)
                    }
                }
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
#endif
