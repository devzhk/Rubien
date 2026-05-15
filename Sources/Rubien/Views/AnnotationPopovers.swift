import SwiftUI

// MARK: - Selection popover (shown while user has unsaved text selection)

struct AnnotationSelectionPopover: View {
    @Binding var currentColorHex: String
    @Binding var noteMarkdown: String
    let onHighlight: () -> Void
    let onUnderline: () -> Void
    let onPickColor: (String) -> Void
    let onCopy: () -> Void
    let onSaveNote: (String) -> Void
    let onDismiss: () -> Void

    @State private var editorContentHeight: CGFloat = 36
    private let bgColor: Color = Color(nsColor: NSColor(white: 0.97, alpha: 1))

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                toolbarButton(icon: "highlighter", label: String(localized: "Highlight", bundle: .module)) {
                    onHighlight()
                }

                toolbarButton(icon: "underline", label: String(localized: "Underline", bundle: .module)) {
                    onUnderline()
                }

                toolbarButton(icon: "doc.on.doc", label: String(localized: "Copy", bundle: .module)) {
                    onCopy()
                }

                separator

                ForEach(AnnotationColor.palette) { color in
                    let isSelected = currentColorHex == color.id
                    Button {
                        currentColorHex = color.id
                        onPickColor(color.id)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor.withAlphaComponent(1.0)))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.white : Color.black.opacity(0.20),
                                        lineWidth: isSelected ? 2 : 0.5
                                    )
                            )
                            .scaleEffect(isSelected ? 1.12 : 1.0)
                            .frame(width: 22, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(color.name)
                    .animation(.easeOut(duration: 0.12), value: isSelected)
                }

                separator

                toolbarButton(icon: "trash", label: String(localized: "Clear selection", bundle: .module)) {
                    onDismiss()
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)

            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                RichNoteEditorView(
                    markdown: $noteMarkdown,
                    placeholder: String(localized: "Add a note…", bundle: .module),
                    autoFocus: false,
                    onContentHeightChanged: { height in
                        editorContentHeight = height
                    }
                )
                .frame(height: min(max(editorContentHeight, 36), 180))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 8)
                .padding(.top, 6)

                HStack(spacing: 8) {
                    Spacer()
                    Button(String(localized: "common.cancel", bundle: .module)) {
                        onDismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))

                    Button(String(localized: "common.save", bundle: .module)) {
                        let md = noteMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !md.isEmpty else { return }
                        onSaveNote(md)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(noteMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? Color.accentColor.opacity(0.50)
                                  : Color.accentColor)
                    )
                    .buttonStyle(.plain)
                    .disabled(noteMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 340)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .environment(\.colorScheme, .light)
        .onExitCommand { onDismiss() }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.black.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.80))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotionToolbarButtonStyle())
        .help(label)
    }
}

// MARK: - Existing-annotation popover (shown when user clicks a saved highlight)

struct ExistingAnnotationPopover: View {
    let annotationId: AnyHashable
    let currentColor: String
    let initialNoteText: String?
    let onPickColor: (String) -> Void
    let onDelete: () -> Void
    let onNoteAutosave: (String) -> Void
    let onDismiss: () -> Void

    @State private var isEditingNote = false
    @State private var editingMarkdown = ""
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var editorContentHeight: CGFloat = 36

    private let bgColor: Color = Color(nsColor: NSColor(white: 0.97, alpha: 1))

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(AnnotationColor.palette) { color in
                    let isSelected = currentColor == color.id
                    Button {
                        onPickColor(color.id)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor.withAlphaComponent(1.0)))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.white : Color.black.opacity(0.20),
                                        lineWidth: isSelected ? 2 : 0.5
                                    )
                            )
                            .scaleEffect(isSelected ? 1.12 : 1.0)
                            .frame(width: 22, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(color.name)
                    .animation(.easeOut(duration: 0.12), value: isSelected)
                }

                separator

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.80))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotionToolbarButtonStyle())
                .help(String(localized: "Delete annotation", bundle: .module))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)

            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 8)

            if isEditingNote {
                RichNoteEditorView(
                    markdown: $editingMarkdown,
                    placeholder: String(localized: "Add a note…", bundle: .module),
                    autoFocus: true,
                    onContentHeightChanged: { height in
                        editorContentHeight = height
                    }
                )
                .frame(height: min(max(editorContentHeight, 36), 160))
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            } else {
                Button {
                    editingMarkdown = ""
                    isEditingNote = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                            .font(.system(size: 10))
                        Text("Add a note…", bundle: .module)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 340)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .environment(\.colorScheme, .light)
        .onExitCommand { onDismiss() }
        .onAppear {
            let noteText = initialNoteText ?? ""
            editingMarkdown = noteText
            isEditingNote = !noteText.isEmpty
        }
        .onChange(of: annotationId) { _, _ in
            let noteText = initialNoteText ?? ""
            editingMarkdown = noteText
            isEditingNote = !noteText.isEmpty
        }
        .onChange(of: editingMarkdown) { _, newValue in
            autoSaveTask?.cancel()
            autoSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                onNoteAutosave(trimmed)
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.black.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }
}

// MARK: - Shared button style (was duplicated as NotionToolbarButtonStyle in PDFReaderView
// and WebNotionToolbarButtonStyle in WebReaderView; now lives here and is used by both popovers).

struct NotionToolbarButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.black.opacity(0.10)
                          : (isHovered ? Color.black.opacity(0.06) : Color.clear))
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
