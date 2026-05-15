#if os(macOS)
import SwiftUI
import RubienCore

/// Pre-import sheet for "Import Zotero Folder…". Lets the user pick which property
/// to stamp with the folder name and edit the stamped value. On confirm, hands off
/// a `ZoteroImportPropertyTarget` to the caller.
struct ZoteroImportSheet: View {
    let folderURL: URL
    let db: AppDatabase
    let onConfirm: (ZoteroImportPropertyTarget) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var allProperties: [PropertyDefinition] = []
    @State private var selectedPropertyId: Int64?
    @State private var stampValue: String = ""
    @State private var errorText: String?

    private var allowedProperties: [PropertyDefinition] {
        allProperties.filter { prop in
            // Built-in "Tags" is always allowed. Other built-ins (Type, Status, Year, DOI, URL)
            // are excluded — writing the folder name into them would corrupt semantic fields.
            if prop.isDefault {
                return prop.defaultFieldKey == PropertyDefinition.tagsFieldKey
            }
            switch prop.type {
            case .string, .url, .singleSelect, .multiSelect: return true
            case .number, .date, .checkbox: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Zotero Folder")
                .font(.title2)
                .bold()

            Text(folderURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Stamp every imported reference with:")
                    .font(.subheadline)

                Picker("Property", selection: $selectedPropertyId) {
                    ForEach(allowedProperties) { prop in
                        Text("\(prop.name)  —  \(prop.type.label)")
                            .tag(prop.id as Int64?)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Value:")
                    .font(.subheadline)
                TextField("Value", text: $stampValue)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = errorText {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    guard let propId = selectedPropertyId else {
                        errorText = "Select a property."
                        return
                    }
                    let trimmed = stampValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        errorText = "Value cannot be empty."
                        return
                    }
                    onConfirm(ZoteroImportPropertyTarget(propertyId: propId, value: trimmed))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPropertyId == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
        .onAppear {
            loadProperties()
            stampValue = folderURL.lastPathComponent
        }
    }

    private func loadProperties() {
        do {
            let all = try db.fetchAllPropertyDefinitions()
            allProperties = all
            // Default selection: Tags
            selectedPropertyId = all.first(where: { $0.defaultFieldKey == PropertyDefinition.tagsFieldKey })?.id
                ?? allowedProperties.first?.id
        } catch {
            errorText = "Failed to load properties: \(error.localizedDescription)"
        }
    }
}
#endif
