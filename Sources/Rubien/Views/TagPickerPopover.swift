import SwiftUI
import RubienCore

struct TagPickerPopover: View {
    let assignedTags: [Tag]
    let allTags: [Tag]
    let onCommit: ([Int64]) -> Void
    let onCreateTag: (String) -> Void
    let onDeleteTag: (Int64) -> Void
    @Binding var newTagName: String
    @State private var search = ""
    @State private var localIds: Set<Int64> = []

    private var filteredTags: [Tag] {
        if search.isEmpty { return allTags }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func isAssigned(_ tag: Tag) -> Bool {
        guard let id = tag.id else { return false }
        return localIds.contains(id)
    }

    private func handleCreate(_ name: String) {
        onCommit(Array(localIds))
        onCreateTag(name)
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
                                    localIds.remove(id)
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
        }
        .onDisappear {
            onCommit(Array(localIds))
        }
    }
}
