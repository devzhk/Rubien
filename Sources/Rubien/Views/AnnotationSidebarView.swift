import SwiftUI
import RubienCore

struct AnnotationSidebarView: View {
    @ObservedObject var viewModel: PDFReaderViewModel
    @State private var filterType: AnnotationType?
    @State private var editingAnnotation: PDFAnnotationRecord?
    @State private var editNoteText = ""
    @State private var filteredAnnotations: [PDFAnnotationRecord] = []

    private var sidebarBackground: Color {
        Color(nsColor: NSColor(name: nil) { trait in
            trait.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.15, alpha: 1.0)
                : NSColor(calibratedWhite: 0.90, alpha: 1.0)
        })
    }

    private var panelBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var panelStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.55)
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            if filteredAnnotations.isEmpty {
                emptyState
            } else {
                annotationList
            }
        }
        .background(sidebarBackground)
        .sheet(item: $editingAnnotation) { annotation in
            editNoteSheet(annotation: annotation)
        }
        .onAppear {
            updateFilteredAnnotations()
        }
        .onChange(of: viewModel.annotations) { _, _ in
            updateFilteredAnnotations()
        }
        .onChange(of: filterType) { _, _ in
            updateFilteredAnnotations()
        }
    }

    private func updateFilteredAnnotations() {
        if let filterType {
            filteredAnnotations = viewModel.annotations.filter { $0.type == filterType }
        } else {
            filteredAnnotations = viewModel.annotations
        }
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Annotations", bundle: .module)
                    .font(.headline)

                Text("\(filteredAnnotations.count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))

                Spacer()
            }

            DraggableSegmentedControl(selection: $filterType, items: [
                (String(localized: "All", bundle: .module), nil),
                (String(localized: "Highlight", bundle: .module), .highlight),
                (String(localized: "Underline", bundle: .module), .underline),
                (String(localized: "Note", bundle: .module), .note),
            ])
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 36)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelBackground)
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: "highlighter")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(panelStroke, lineWidth: 0.5)
                )

            VStack(spacing: 6) {
                Text("No annotations yet", bundle: .module)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Select text in the document, then add a highlight, underline, or note from the floating toolbar.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
    }

    // MARK: - Annotation List

    private var annotationList: some View {
        ScrollViewReader { proxy in
            OverlayScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredAnnotations) { annotation in
                        AnnotationCard(
                            annotation: annotation,
                            isSelected: viewModel.selectedAnnotationId == annotation.id,
                            onTap: {
                                viewModel.navigateTo(annotation)
                            },
                            onEdit: {
                                editNoteText = annotation.noteText ?? ""
                                editingAnnotation = annotation
                            },
                            onDelete: {
                                withAnimation { viewModel.deleteAnnotation(annotation) }
                            }
                        )
                        .id(annotation.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.selectedAnnotationId) { _, newId in
                if let newId {
                    withAnimation { proxy.scrollTo(newId, anchor: .center) }
                }
            }
        }
    }

    // MARK: - Edit Note Sheet

    private func editNoteSheet(annotation: PDFAnnotationRecord) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Edit note", bundle: .module)
                    .font(.headline)
                Spacer()
                Button(String(localized: "common.cancel", bundle: .module)) { editingAnnotation = nil }
                    .keyboardShortcut(.cancelAction)
            }

            if let text = annotation.selectedText, !text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected text", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.callout)
                        .lineLimit(3)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Note", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RichNoteEditorView(markdown: $editNoteText)
                    .frame(minHeight: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
            }

            HStack {
                Spacer()
                Button(String(localized: "common.save", bundle: .module)) {
                    viewModel.updateAnnotationNote(annotation, noteText: editNoteText)
                    editingAnnotation = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 320)
    }
}

// MARK: - Annotation Card

struct AnnotationCard: View {
    let annotation: PDFAnnotationRecord
    let isSelected: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var cardBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardStroke: Color {
        isSelected ? Color.accentColor.opacity(0.30) : Color(nsColor: .separatorColor).opacity(0.45)
    }

    private var cardShadow: Color {
        Color.black.opacity(isSelected ? 0.10 : 0.04)
    }

    private var excerptBackground: Color {
        Color.primary.opacity(isSelected ? 0.055 : 0.030)
    }

    private var noteBackground: Color {
        Color.primary.opacity(isSelected ? 0.045 : 0.022)
    }

    private var normalizedNotePreview: String? {
        guard let note = annotation.noteText, !note.isEmpty else { return nil }
        return note
            .replacingOccurrences(of: #"(?m)^#{1,6} "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^```[^\n]*"#, with: "", options: .regularExpression)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(Color(hex: annotation.color).opacity(0.85))
                    .frame(width: 8, height: 8)

                Text(annotation.type.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Text("P\(annotation.pageIndex + 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text("·")
                    .foregroundStyle(.quaternary)

                Text(annotation.dateCreated.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if let text = annotation.selectedText, !text.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(hex: annotation.color).opacity(0.75))
                        .frame(width: 3)

                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(excerptBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let previewNote = normalizedNotePreview {
                VStack(alignment: .leading, spacing: 4) {
                    if let attributed = try? AttributedString(markdown: previewNote, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(previewNote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(noteBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if isHovered || isSelected {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        cardActionButton(icon: "pencil", tint: .secondary, action: onEdit)
                            .help(String(localized: "Edit note", bundle: .module))
                        cardActionButton(icon: "trash", tint: .red, action: onDelete)
                            .help(String(localized: "Delete annotation", bundle: .module))
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: isSelected ? 1 : 0.5)
        )
        .shadow(color: cardShadow, radius: isSelected ? 10 : 5, y: isSelected ? 4 : 2)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onTap() }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private func cardActionButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }
}
