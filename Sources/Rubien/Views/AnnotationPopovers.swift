#if os(macOS)
import SwiftUI

/// Horizontal placement helper for the two annotation popovers below
/// (`AnnotationSelectionPopover` and `ExistingAnnotationPopover`). Centers
/// the popover on `center`, but clamps inside
/// `[edgePadding, containerWidth - popoverWidth - edgePadding]` so the
/// popover never extends past the surrounding reader container — which
/// would otherwise be partially covered by the container's
/// `RoundedRectangle.stroke` border drawn over its contents. The
/// `popoverWidth` default matches both popovers' `.frame(width: 340)`
/// below; bump it if those frames ever change.
func clampedPopoverX(
    center: CGFloat,
    containerWidth: CGFloat,
    popoverWidth: CGFloat = 340,
    edgePadding: CGFloat = 8
) -> CGFloat {
    let desired = center - popoverWidth / 2
    let minX = edgePadding
    let maxX = max(minX, containerWidth - popoverWidth - edgePadding)
    return min(max(desired, minX), maxX)
}

// MARK: - Selection popover (shown while user has unsaved text selection)

struct AnnotationSelectionPopover: View {
    @Binding var currentColorHex: String
    @Binding var noteMarkdown: String
    let onHighlight: () -> Void
    let onUnderline: () -> Void
    let onPickColor: (String) -> Void
    let onSaveNote: (String) -> Void
    let onDismiss: () -> Void
    /// Optional "Ask assistant" action (Selection→Ask, §5.4): stages the selected
    /// text into the chat sidebar and opens it. `nil` (the default) hides the
    /// button — the PDF reader call site wires it in Phase 3.
    var onAsk: (() -> Void)? = nil

    @State private var editorContentHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                toolbarButton(icon: "highlighter", label: String(localized: "Highlight", bundle: .module)) {
                    onHighlight()
                }

                toolbarButton(icon: "underline", label: String(localized: "Underline", bundle: .module)) {
                    onUnderline()
                }

                if let onAsk {
                    // The Assistant's one glyph everywhere (reader toolbar, sidebar
                    // header, Settings tab) — the quick-start hint tells users to
                    // look for "the chat button", so this must be it.
                    toolbarButton(icon: "bubble.left.and.text.bubble.right",
                                  label: String(localized: "Ask assistant", bundle: .module)) {
                        onAsk()
                    }
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
                    transparentBackground: true,
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
        .modifier(AnnotationPopoverGlassSurface())
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
                    transparentBackground: true,
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
        .modifier(AnnotationPopoverGlassSurface())
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

// MARK: - Shared glass surface for the annotation popovers
//
// Uses real Liquid Glass on macOS 26+, with an `.ultraThinMaterial` fallback below. Both
// popovers force `.environment(\.colorScheme, .light)` (their separators, color
// swatches, and the light-themed note editor are all tuned for a light backing),
// so this renders the light glass variant. The note editor opts into a transparent
// body here (`transparentBackground: true`), so the whole popover — toolbar, editor,
// and footer — reads as one translucent sheet; its light-theme dark text stays
// legible over the light glass.
private struct AnnotationPopoverGlassSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }
}
#endif
