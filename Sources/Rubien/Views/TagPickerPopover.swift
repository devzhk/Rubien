#if os(macOS)
import SwiftUI
import RubienCore

struct TagPickerPopover: View {
    let assignedTags: [Tag]
    let allTags: [Tag]
    let onCommit: ([Int64]) -> Void
    /// Creates a new tag and returns its id. The popover adds the id to its
    /// local selection and immediately fires `onCommit` so the cell behind the
    /// popover reflects the new state without waiting for the NSPopover dismiss
    /// animation. The `Int64?` return is required so the popover can include
    /// the newly-created id in that immediate commit.
    let onCreateTag: (String) -> Int64?
    let onDeleteTag: (Int64) -> Void
    /// Probe (mirrors SelectOptionPicker.deleteUnlessInUse): returns the in-use
    /// reference count when the tag is still assigned (→ inline confirm), or nil
    /// when it was deleted outright because unused, or could not be probed
    /// (fail-closed no-op). Always wired — required, not optional — so a tag
    /// delete can never skip the gate.
    let deleteTagUnlessInUse: (Int64) -> Int?
    @State private var search = ""
    @State private var localIds: Set<Int64> = []
    /// Set while an in-use tag awaits delete confirmation; renders the inline
    /// confirm prompt in place of the tag list.
    @State private var confirming: (id: Int64, name: String, count: Int)?
    /// Measured natural height of the tag list — floors the scroll area at
    /// min(content, 200) once measured so the popover restores its height after
    /// the (shorter) confirm view swaps back. Same fix as SelectOptionPicker.
    @State private var listContentHeight: CGFloat = 0

    private var filteredTags: [Tag] {
        if search.isEmpty { return allTags }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func isAssigned(_ tag: Tag) -> Bool {
        guard let id = tag.id else { return false }
        return localIds.contains(id)
    }

    /// Fire `onCommit` synchronously after a local mutation so the table cell
    /// updates while the popover is still open. Deferring to `onDisappear`
    /// waits for NSPopover's ~500–800ms dismiss animation before the cell
    /// reflects the change.
    private func flushCommit() {
        onCommit(Array(localIds))
    }

    private func handleCreate(_ name: String) {
        if let newId = onCreateTag(name) {
            localIds.insert(newId)
            flushCommit()
        }
        search = ""
    }

    var body: some View {
        Group {
            if let pending = confirming {
                confirmView(pending)
            } else {
                pickerBody
            }
        }
        .frame(width: 220)
        .onAppear {
            localIds = Set(assignedTags.compactMap(\.id))
        }
        .activatePopoverHover()
    }

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search or create tag…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        let trimmed = search.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !allTags.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                            handleCreate(trimmed)
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredTags) { tag in
                        TagPickerRow(
                            tag: tag,
                            isAssigned: isAssigned(tag),
                            onToggle: {
                                guard let id = tag.id else { return }
                                if localIds.contains(id) { localIds.remove(id) } else { localIds.insert(id) }
                                flushCommit()
                            },
                            onDelete: { requestDelete(tag) }
                        )
                    }

                    if !search.isEmpty && !allTags.contains(where: { $0.name.lowercased() == search.trimmingCharacters(in: .whitespaces).lowercased() }) {
                        Button {
                            let trimmed = search.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                handleCreate(trimmed)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.accentColor)
                                Text("Create \"\(search.trimmingCharacters(in: .whitespaces))\"")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listContentHeight = height
                }
            }
            .frame(
                minHeight: listContentHeight > 0 ? min(listContentHeight, 200) : nil,
                maxHeight: 200
            )
        }
        // No `onDisappear { onCommit(...) }` — every mutation path above already
        // fires `flushCommit()`. Deferring to disappear would wait for
        // NSPopover's ~500–800ms dismiss animation before the cell update,
        // which is the lag pattern this refactor eliminates.
    }

    /// Trash tapped on `tag`. Probe for usage: an in-use tag surfaces the inline
    /// confirm; an unused tag is deleted outright by the probe (nothing more to
    /// do — mirrors SelectOptionPicker.requestDelete).
    private func requestDelete(_ tag: Tag) {
        guard let id = tag.id else { return }
        if let count = deleteTagUnlessInUse(id) {
            confirming = (id, tag.name, count)
        }
    }

    // NOTE: this confirm view and the measured-min-height fix above deliberately
    // mirror SelectOptionPicker (InlinePropertyRow.swift). Two call sites don't
    // justify a shared abstraction yet; if a third in-use-confirm picker appears,
    // extract a shared InUseConfirmView + min-height modifier at that point.
    @ViewBuilder
    private func confirmView(_ pending: (id: Int64, name: String, count: Int)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete the tag \u{201C}\(pending.name)\u{201D}?")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("This removes it from \(pending.count) reference\(pending.count == 1 ? "" : "s").")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirming = nil }
                    .buttonStyle(.bordered)
                Button("Delete") {
                    // Mirror the original trash ordering: drop the per-reference
                    // pivot first (defensive), then the global delete.
                    localIds.remove(pending.id)
                    flushCommit()
                    onDeleteTag(pending.id)
                    confirming = nil
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(12)
    }
}

// MARK: - Single tag row inside the picker
//
// Extracted so each row owns its hover state and shows the trash affordance only on
// pointer-over — matching `SelectOptionPickerRow` (the Status / select-option picker).
private struct TagPickerRow: View {
    let tag: Tag
    let isAssigned: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isAssigned ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isAssigned ? Color.accentColor : .secondary)
                    Text(tag.name)
                        .font(.system(size: 12))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .chipBackground(Color(hex: tag.color))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete tag")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .onHover { isHovering = $0 }
    }
}
#endif
