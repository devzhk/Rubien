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
    @State private var search = ""
    @State private var localIds: Set<Int64> = []
    @FocusState private var isSearchFocused: Bool

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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search or create tag…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
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
                        let assigned = isAssigned(tag)
                        HStack(spacing: 0) {
                            Button {
                                if let id = tag.id {
                                    if localIds.contains(id) { localIds.remove(id) } else { localIds.insert(id) }
                                    flushCommit()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: assigned ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(assigned ? Color.accentColor : .secondary)
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

                            Button {
                                if let id = tag.id {
                                    // Commit the per-reference removal first
                                    // (defensive — both orderings converge via
                                    // the FK cascade-delete on referenceTag,
                                    // but writing without the about-to-delete
                                    // tag id avoids a brief inconsistent
                                    // intermediate state).
                                    localIds.remove(id)
                                    flushCommit()
                                    onDeleteTag(id)
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete tag")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
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
            }
            .frame(maxHeight: 200)
        }
        .frame(width: 220)
        .onAppear {
            localIds = Set(assignedTags.compactMap(\.id))
            DispatchQueue.main.async { isSearchFocused = true }
        }
        // No `onDisappear { onCommit(...) }` — every mutation path above already
        // fires `flushCommit()`. Deferring to disappear would wait for
        // NSPopover's ~500–800ms dismiss animation before the cell update,
        // which is the lag pattern this refactor eliminates.
    }
}
